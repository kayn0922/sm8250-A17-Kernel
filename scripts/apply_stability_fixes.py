#!/usr/bin/env python3
"""Idempotent stability fixes for ymdzq/kernel_xiaomi_sm8250_mod (4.19).

Invoked by .github/workflows/build-a17-kernel.yml AFTER apply_patches.sh.
Works on any of the elish / enuma / dagu defconfigs.

    python3 scripts/apply_stability_fixes.py --kernel-dir kernel \
        --devices elish,enuma
    python3 scripts/apply_stability_fixes.py --kernel-dir kernel \
        --devices elish,enuma --check      # CI verification, no writes

Fixes (all confirmed against the android16-aptusitu source tree):
  1. drivers/input/misc/xiaomi_keyboard/*  - xiaomi_keyboard_remove() frees
     mdata and destroys event_wq WITHOUT calling power_supply_unreg_notifier();
     kb_power_supply_event() only checked `mdata != NULL` (container_of never
     returns NULL) and then queued work on the freed wq. After
     "[xiaomi-keyboard] Reset Host" any power_supply event hits
     __queue_work() with a NULL pointer -> "Kernel panic - Fatal exception"
     (stack: __queue_work <- kb_power_supply_event <- power_supply_changed_work).
  2. arch/arm64/configs/<device>_defconfig - enable CONFIG_CGROUP_PIDS and
     CONFIG_CGROUP_DEVICE. Both are absent upstream; Android 17 init writes
     pids into memcg -> "init: failed write pid to memcg" storm.
  3. fs/pstore/ram.c - ramoops_memreserve() split the whole 4M reservation
     between console and pmsg and never set record_size, so the pstore backend
     registered but could never persist oops/panic logs (/sys/fs/pstore empty,
     "ramoops: record_size=0"). Reserve dump + ftrace records too.

Every hunk matches by structure, not line numbers. If a hunk cannot be
matched the script aborts instead of producing a half-patched kernel.
Re-running is safe: already-patched files are skipped.
"""

import argparse
import re
import sys
from pathlib import Path

KB_H = "drivers/input/misc/xiaomi_keyboard/xiaomi_keyboard.h"
KB_C = "drivers/input/misc/xiaomi_keyboard/xiaomi_keyboard.c"
RAM = "fs/pstore/ram.c"
DEFCONFIG = "arch/arm64/configs/{}_defconfig"

ROOT = Path(".")

SHARED_MARKERS = {
    KB_H: "notifier_active",
    KB_C: "notifier_active",
    RAM: "ramoops_data.record_size = size / 16;",
}
DEFCONFIG_MARKER = "CONFIG_CGROUP_PIDS=y"


def read(rel):
    p = ROOT / rel
    if not p.exists():
        raise SystemExit("MISSING FILE: %s (wrong --kernel-dir?)" % rel)
    return p.read_text(encoding="utf-8", errors="surrogateescape")


def write(rel, text):
    (ROOT / rel).write_text(text, encoding="utf-8", errors="surrogateescape")


def sub_once(text, pattern, repl, label, flags=0):
    new, n = re.subn(pattern, repl, text, count=1, flags=flags)
    if n != 1:
        raise SystemExit("PATCH HUNK FAILED: %s\n  regex: %s" % (label, pattern[:160]))
    return new


def fix_keyboard_header():
    t = read(KB_H)
    if SHARED_MARKERS[KB_H] in t:
        return "SKIP (already patched)"
    t = sub_once(
        t,
        r"(\tstruct notifier_block power_supply_notifier;)",
        r"\1\n\tbool notifier_active;",
        "add notifier_active field",
    )
    write(KB_H, t)
    return "OK"


def fix_keyboard_driver():
    t = read(KB_C)
    if SHARED_MARKERS[KB_C] in t:
        return "SKIP (already patched)"

    # (a) power_supply notifier: container_of() is never NULL, so the old
    #     `if (mdata != NULL)` guard did nothing. Guard the real pointer.
    new_power_cb = """static int kb_power_supply_event(struct notifier_block *nb, unsigned long event,
\t\t\t\t void *ptr)
{
\tstruct xiaomi_keyboard_data *mdata = container_of(
\t\tnb, struct xiaomi_keyboard_data, power_supply_notifier);
\tstruct workqueue_struct *wq;

\t/* notifier_active is cleared before xiaomi_keyboard_remove() frees mdata.
\t * container_of() never returns NULL and event_wq may already be destroyed,
\t * so the old `if (mdata != NULL)` guard allowed a NULL deref in
\t * __queue_work() after "[xiaomi-keyboard] Reset Host".
\t */
\tif (!READ_ONCE(mdata->notifier_active))
\t\treturn 0;
\twq = READ_ONCE(mdata->event_wq);
\tif (!wq)
\t\treturn 0;

\tqueue_work(wq, &mdata->power_supply_work);
\treturn 0;
}"""
    t = sub_once(
        t,
        r"static int kb_power_supply_event\(struct notifier_block \*nb,.*?\n\}",
        lambda m: new_power_cb,
        "rewrite kb_power_supply_event",
        flags=re.S,
    )

    # (b) drm notifier touches the same workqueue without any guard.
    t = sub_once(
        t,
        r"if \(evdata->data && mdata\) \{",
        "if (evdata->data && mdata && READ_ONCE(mdata->notifier_active) &&\n"
        "\t    READ_ONCE(mdata->event_wq)) {",
        "guard keyboard_drm_notifier_callback",
    )

    # (c) arm the notifier flag before registering EITHER notifier (the drm
    #     client is registered first, and its callback also uses event_wq).
    t = sub_once(
        t,
        r"(\tmdata->drm_notif\.notifier_call = keyboard_drm_notifier_callback;)",
        "\tWRITE_ONCE(mdata->notifier_active, true);\n\\1",
        "arm notifier_active before registration",
    )

    # (d) probe error path: unregister the drm client that was already
    #     registered, disarm, and NULL the destroyed workqueue.
    t = sub_once(
        t,
        r"err_register_power_supply_notif_failed:\nerr_register_drm_notif_failed:",
        "err_register_power_supply_notif_failed:\n"
        "\tWRITE_ONCE(mdata->notifier_active, false);\n"
        "\tmi_drm_unregister_client(&mdata->drm_notif);\n"
        "err_register_drm_notif_failed:",
        "probe error path cleanup",
    )

    t = sub_once(
        t,
        r"\tif \(mdata->event_wq\) \{\n\t\tdestroy_workqueue\(mdata->event_wq\);\n\t\}",
        "\tif (mdata->event_wq) {\n"
        "\t\tdestroy_workqueue(mdata->event_wq);\n"
        "\t\tWRITE_ONCE(mdata->event_wq, NULL);\n"
        "\t}",
        "NULL event_wq on probe failure",
    )

    # (e) remove path: the actual panic. The original code never called
    #     power_supply_unreg_notifier(), so the global notifier chain kept a
    #     pointer to freed mdata.
    t = sub_once(
        t,
        r"(static int xiaomi_keyboard_remove\(struct platform_device \*pdev\)\n\{"
        r"\n\tMI_KB_INFO\(\"enter\\n\"\);\n)"
        r"\tmi_drm_unregister_client\(&mdata->drm_notif\);\n"
        r"\tdestroy_workqueue\(mdata->event_wq\);",
        "\\1"
        "\tif (!mdata)\n"
        "\t\treturn 0;\n"
        "\t/* Stop new work first, then unregister BOTH notifiers before\n"
        "\t * freeing mdata. Missing power_supply_unreg_notifier() left a\n"
        "\t * dangling callback on the global power_supply chain. */\n"
        "\tWRITE_ONCE(mdata->notifier_active, false);\n"
        "\tpower_supply_unreg_notifier(&mdata->power_supply_notifier);\n"
        "\tmi_drm_unregister_client(&mdata->drm_notif);\n"
        "\tif (READ_ONCE(mdata->event_wq)) {\n"
        "\t\tflush_workqueue(mdata->event_wq);\n"
        "\t\tdestroy_workqueue(mdata->event_wq);\n"
        "\t\tWRITE_ONCE(mdata->event_wq, NULL);\n"
        "\t}",
        "rewrite xiaomi_keyboard_remove teardown",
    )

    # (f) drop the duplicated gpio_deconfig call in remove().
    t = sub_once(
        t,
        r"(\tdevm_pinctrl_put\(mdata->pinctrl\);\n)"
        r"\txiaomi_keyboard_gpio_deconfig\(mdata->pdata\);\n",
        r"\1",
        "remove duplicated gpio deconfig",
    )

    write(KB_C, t)
    return "OK"


def fix_defconfig(device):
    rel = DEFCONFIG.format(device)
    p = ROOT / rel
    if not p.exists():
        return "SKIP (defconfig absent)"
    t = read(rel)
    if DEFCONFIG_MARKER in t:
        return "SKIP (already patched)"
    t = sub_once(
        t,
        r"(CONFIG_CGROUP_BPF=y)",
        r"\1\nCONFIG_CGROUP_PIDS=y\nCONFIG_CGROUP_DEVICE=y",
        "enable cgroup pids/device controllers",
    )
    write(rel, t)
    return "OK"


def fix_ramoops():
    t = read(RAM)
    if SHARED_MARKERS[RAM] in t:
        return "SKIP (already patched)"
    t = sub_once(
        t,
        r"\tramoops_data\.console_size = size / 2;\n"
        r"\tramoops_data\.pmsg_size = size / 2;\n"
        r"\tramoops_data\.dump_oops = 1;",
        "\t/* The original split used the whole 4M for console+pmsg and left\n"
        "\t * record_size = 0, so pstore never persisted oops/panic logs.\n"
        "\t * Reserve dump records + ftrace, keep console and pmsg at 1M each. */\n"
        "\tramoops_data.record_size = size / 16;\n"
        "\tramoops_data.ftrace_size = size / 16;\n"
        "\tramoops_data.console_size = size / 4;\n"
        "\tramoops_data.pmsg_size = size / 4;\n"
        "\tramoops_data.dump_oops = 1;",
        "allocate ramoops dump records",
    )
    write(RAM, t)
    return "OK"


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--kernel-dir", default=".", help="kernel source root")
    ap.add_argument("--devices", default="elish,enuma,dagu",
                    help="comma separated codenames whose defconfigs get fixed")
    ap.add_argument("--check", action="store_true",
                    help="verify markers only, never write")
    args = ap.parse_args()

    global ROOT
    ROOT = Path(args.kernel_dir).resolve()
    if not ROOT.is_dir():
        raise SystemExit("kernel dir not found: %s" % ROOT)
    devices = [d.strip() for d in args.devices.split(",") if d.strip()]

    print("stability fixes: root=%s devices=%s mode=%s"
          % (ROOT, ",".join(devices), "check" if args.check else "apply"))

    if args.check:
        ok = True
        for rel, marker in SHARED_MARKERS.items():
            present = marker in read(rel)
            print("  [%s] %-55s %s" % ("OK" if present else "FAIL", rel, marker))
            ok &= present
        found = 0
        for d in devices:
            rel = DEFCONFIG.format(d)
            if not (ROOT / rel).exists():
                print("  [SKIP] %-55s (absent)" % rel)
                continue
            found += 1
            present = DEFCONFIG_MARKER in read(rel)
            print("  [%s] %-55s %s" % ("OK" if present else "FAIL", rel, DEFCONFIG_MARKER))
            ok &= present
        if not found:
            print("  [FAIL] no defconfig found for the requested devices")
            ok = False
        if not ok:
            raise SystemExit("verification failed - fixes are missing")
        print("all stability fixes verified")
        return

    results = [
        (KB_H, fix_keyboard_header()),
        (KB_C, fix_keyboard_driver()),
        (RAM, fix_ramoops()),
    ] + [(DEFCONFIG.format(d), fix_defconfig(d)) for d in devices]
    for rel, status in results:
        print("  %-55s %s" % (rel, status))
    print("done")


if __name__ == "__main__":
    main()
