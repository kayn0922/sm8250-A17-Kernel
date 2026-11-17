#!/bin/bash
# Idempotent kernel-side preparation before running ymdzq's build.sh.
# Usage: apply_patches.sh <kernel-dir> <device> <gps_dts_fix>
#
# What it does:
#   1. Force-enable the kernel features Android 16/17 framework needs
#      (already present upstream; this makes it explicit and reviewable).
#   2. Force-enable every GNSS transport option (Airoha GPS chip power +
#      QRTR / QMI / GLINK / DIAG) so the kernel side cannot be the GPS blocker.
#   3. Optional, EXPERIMENTAL: restore a minimal bcm4775 node in dagu's DTS.
#      Only use it after GPS_DIAGNOSIS.md shows the node is missing.
set -e

KDIR=${1:-kernel}
DEVICE=${2:-enuma}
GPS_FIX=${3:-none}

# Absolute paths (needed after we cd into $KDIR for the build.sh fix below)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILDER_DIR="$(dirname "$SCRIPT_DIR")"
KDIR_ABS="$(cd "$KDIR" && pwd)"

cd "$KDIR"
DEF="arch/arm64/configs/${DEVICE}_defconfig"
if [ ! -f "$DEF" ]; then
    echo "ERROR: no defconfig for device '$DEVICE' at $DEF"
    echo "Available:"; ls arch/arm64/configs/*_defconfig | head -20
    exit 1
fi

python3 - "$DEF" "$DEVICE" <<'PY'
import re, sys, os
path = sys.argv[1]
device = sys.argv[2]
want = {
    # Android 16/17 framework requirements
    'CONFIG_ANDROID': 'y',
    'CONFIG_ANDROID_BINDER_IPC': 'y',
    'CONFIG_ANDROID_BINDERFS': 'y',
    'CONFIG_ANDROID_VENDOR_HOOKS': 'y',
    'CONFIG_BPF_SYSCALL': 'y',
    'CONFIG_BPF_JIT': 'y',
    'CONFIG_CGROUP_BPF': 'y',
    'CONFIG_BPF_LSM': 'y',
    'CONFIG_SECCOMP': 'y',
    'CONFIG_PSI': 'y',
    # GNSS / modem transport + Airoha GPS chip power
    'CONFIG_AIROHA_GPS': 'y',
    'CONFIG_QRTR': 'y',
    'CONFIG_QRTR_SMD': 'y',
    'CONFIG_QRTR_MHI': 'y',
    'CONFIG_QCOM_QMI_HELPERS': 'y',
    'CONFIG_RPMSG_QCOM_GLINK_SMEM': 'y',
    'CONFIG_QCOM_GLINK': 'y',
    'CONFIG_DIAG_CHAR': 'y',
    # --- enuma (external SDX55M) modem GNSS: the v4 module powers the X55 up
    #     via baseband=mdm + mdm_helper and runs the QTI GNSS HAL over QMI_LOC.
    #     That path NEEDS the external-modem + MHI + CNSS2 stack compiled in.
    #     The upstream enuma_defconfig usually has these, but elish_defconfig
    #     (WiFi-only) does NOT - and the user's rig is enuma HW on an elish ROM,
    #     so force them so a fresh build can never lose the modem/GNSS transport.
    'CONFIG_ESOC': 'y',
    'CONFIG_ESOC_DEV': 'y',
    'CONFIG_ESOC_CLIENT': 'y',
    'CONFIG_ESOC_MDM_4X': 'y',
    'CONFIG_ESOC_MDM_DRV': 'y',
    'CONFIG_MHI_BUS': 'y',
    'CONFIG_MHI_QCOM': 'y',
    'CONFIG_MHI_NETDEV': 'y',
    'CONFIG_MSM_SUBSYSTEM_RESTART': 'y',
    'CONFIG_MSM_PIL': 'y',
    'CONFIG_MSM_PIL_SSR_GENERIC': 'y',
    # CNSS2 is the wlan/wifi driver framework; keep it on so the modem SSR
    # isolation patch (below) has a wlan subsystem to protect.
    'CONFIG_CNSS2': 'y',
    'CONFIG_CNSS2_QMI': 'y',
    # 方案 A: pstore so kernel panics survive a reboot and can be read from
    # /sys/fs/pstore. Needed to root-cause the unplug+deep-sleep reboot.
    # NOTE: in this 4.19 tree the ramoops *platform driver* is fs/pstore/ram.c
    # and is enabled by CONFIG_PSTORE_RAM - there is NO CONFIG_RAMOOPS symbol
    # (forcing it is silently dropped by olddefconfig, it is not an error).
    # Compression is turned OFF so the dumped dmesg/console is plain text.
    'CONFIG_PSTORE': 'y',
    'CONFIG_PSTORE_RAM': 'y',
    'CONFIG_PSTORE_CONSOLE': 'y',
    'CONFIG_PSTORE_PMSG': 'y',
    'CONFIG_PSTORE_DEFLATE_COMPRESS': 'n',
    # 方案 A 兜底: netconsole 实时把内核 printk 发到局域网 PC, 不依赖 ramoops
    # 持久内存 (本设备 ramoops 动态预留区在深睡后被 TZ 清空, 故加此路)。
    # CONFIG_NETCONSOLE_DYNAMIC 允许运行时经 configfs 设定目标 PC IP, 无需重编。
    'CONFIG_NETCONSOLE': 'y',
    'CONFIG_NETCONSOLE_DYNAMIC': 'y',
    # Unplug + deep-sleep reboot guard (方案 A safety net). Kept ON by default.
    # For the diagnostic/capture build pass USG_DISABLE=1 so the real crash can
    # happen and be recorded by ramoops (kona.dtsi ramoops node, below).
}
# --- Device-variant correctness -------------------------------------------
# The "GNSS / modem transport" block above exists for enuma (5G, external
# SDX55M). elish is the WiFi-only variant and its defconfig deliberately does
# NOT enable that stack. Forcing it into an elish build makes the Android
# framework bring up a 5G telephony path that is not present, which crash-loops
# com.android.phone (ClassNotFoundException: com.qti.extphone.ExtTelephonyManager)
# and ends in a framework-initiated reboot.
# For elish we merely STOP FORCING these options: the defconfig's own lines are
# left untouched (nothing is disabled), so the result is a genuine elish kernel.
if device != 'enuma':
    for k in (
        'CONFIG_AIROHA_GPS', 'CONFIG_QRTR', 'CONFIG_QRTR_SMD', 'CONFIG_QRTR_MHI',
        'CONFIG_QCOM_QMI_HELPERS', 'CONFIG_RPMSG_QCOM_GLINK_SMEM',
        'CONFIG_QCOM_GLINK', 'CONFIG_DIAG_CHAR',
        'CONFIG_ESOC', 'CONFIG_ESOC_DEV', 'CONFIG_ESOC_CLIENT',
        'CONFIG_ESOC_MDM_4X', 'CONFIG_ESOC_MDM_DRV',
        'CONFIG_MHI_BUS', 'CONFIG_MHI_QCOM', 'CONFIG_MHI_NETDEV',
        'CONFIG_MSM_SUBSYSTEM_RESTART', 'CONFIG_MSM_PIL',
        'CONFIG_MSM_PIL_SSR_GENERIC', 'CONFIG_CNSS2', 'CONFIG_CNSS2_QMI',
    ):
        want.pop(k, None)
    print('[patch] device=%s: elish/native defconfig, skipped enuma-only SDX55M modem options' % device)

# --- BISECT: turn OFF the external SDX55M modem stack ----------------------
# Live-device evidence (2026-11-15): ro.product.name=elish (WiFi-only ROM),
# yet the enuma kernel registers /sys/bus/esoc/devices/esoc0 and
# /dev/subsys_esoc0, while the framework complains it cannot find
# android.hardware.radio.modem.IRadioModem/slot1 in the VINTF manifest.
# Hypothesis: the external-modem SSR/subsystem resume path is what silently
# resets the SoC during unplug + deep sleep (the official elish kernel has no
# ESOC stack at all and never reboots).
# This build removes that stack but KEEPS the two things we actually need:
#   CONFIG_AIROHA_GPS      -> GPS chip driver (UART, not modem)
#   CONFIG_SERIAL_MSM_GENI -> keyboard GENI serial
# MHI_BUS / MHI_QCOM / CNSS2 / QRTR / PIL are deliberately LEFT ON: they also
# carry the QCA6390 WLAN (device shows /dev/mhi_0306_* pipes) and the other
# subsystems (adsp/cdsp/slpi); turning them off would kill WiFi, not just 5G.
if os.environ.get('USG_BISECT') == '1':
    for k in (
        'CONFIG_ESOC', 'CONFIG_ESOC_DEV', 'CONFIG_ESOC_CLIENT',
        'CONFIG_ESOC_MDM_4X', 'CONFIG_ESOC_MDM_DRV',
        'CONFIG_MHI_NETDEV',
    ):
        want[k] = 'n'
    want['CONFIG_AIROHA_GPS'] = 'y'
    want['CONFIG_SERIAL_MSM_GENI'] = 'y'
    print('[patch] BISECT: external SDX55M stack OFF (esoc*/MHI_NETDEV=n); AIROHA_GPS + SERIAL_MSM_GENI kept')

# --- SPIFIX: keep pm_test available so the fix can be verified on device ---
# PM_SLEEP_DEBUG only exposes /sys/power/pm_test; it does not change the
# suspend path itself, so the resulting kernel is still a valid daily driver.
if os.environ.get('USG_SPIFIX') == '1':
    want.update({
        'CONFIG_PM_DEBUG': 'y',
        'CONFIG_PM_SLEEP_DEBUG': 'y',
    })
    print('[patch] SPIFIX: PM_SLEEP_DEBUG on (pm_test available for verification)')

# 方案 A: drop the guard only on the diagnostic/capture build so the genuine
# unplug+deep-sleep failure can occur and be observed/captured.
# USG_CAPTURE=1 -> guard completely absent from the kernel (no config, no
# module wiring) AND extra diagnostic features turned on (see below).
# USG_DISABLE=1 -> guard config only, module still compiled but not force-enabled.
if os.environ.get('USG_CAPTURE') == '1':
    # Diagnostic/capture build. Turn on the tooling needed to actually SEE the
    # unplug+deep-sleep failure:
    #   - PM_SLEEP_DEBUG   : exposes /sys/power/pm_test so we can run each
    #                        suspend phase (freezer->devices->platform->core)
    #                        and localize which driver dies, waking immediately.
    #   - NETCONSOLE(_DYNAMIC): real-time printk over LAN as a ramoops backup.
    #   - DETECT_HUNG_TASK / SOFTLOCKUP_DETECTOR: force a panic+call-trace if
    #     the failure is a suspend/resume HANG (instead of a silent HW reset).
    #   - PANIC_ON_OOPS + PANIC_TIMEOUT=5: an oops becomes a panic that
    #     reboots after 5s so pstore/ramoops can be read back.
    # DEBUG_KERNEL is pulled in because HUNG_TASK/SOFTLOCKUP depend on it.
    want.update({
        'CONFIG_DEBUG_KERNEL': 'y',
        'CONFIG_PM_DEBUG': 'y',
        'CONFIG_PM_SLEEP_DEBUG': 'y',
        'CONFIG_NETCONSOLE': 'y',
        'CONFIG_NETCONSOLE_DYNAMIC': 'y',
        'CONFIG_DETECT_HUNG_TASK': 'y',
        'CONFIG_SOFTLOCKUP_DETECTOR': 'y',
        'CONFIG_PANIC_ON_OOPS': 'y',
        'CONFIG_PANIC_TIMEOUT': '5',
    })
elif os.environ.get('USG_DISABLE') != '1':
    want['CONFIG_UNPLUG_SUSPEND_GUARD'] = 'y'
with open(path, encoding='utf-8') as f:
    lines = f.read().splitlines()
keys = set(want)
out = []
for line in lines:
    m = re.match(r'^(?:# )?(CONFIG_[A-Z0-9_]+)(?:=(.*)| is not set)\s*$', line.strip())
    if m and m.group(1) in keys:
        continue
    out.append(line)
for k, v in want.items():
    out.append('%s=%s' % (k, v))
with open(path, 'w', encoding='utf-8') as f:
    f.write('\n'.join(out) + '\n')
print('[patch] %s: %d options forced on' % (path, len(want)))
PY

if [ "$GPS_FIX" = "dagu-minimal-node" ]; then
    if [ "$DEVICE" != "dagu" ]; then
        echo "[patch] gps_dts_fix applies only to dagu; skipping for '$DEVICE'"
    else
        python3 - <<'PY'
import re
p = 'arch/arm64/boot/dts/vendor/qcom/dagu-sm8250.dtsi'
s = open(p, encoding='utf-8').read()
pat = re.compile(r'/\*\s*bcm4775\s*\{.*?\};\*/', re.S)
node = '''bcm4775 {
		compatible = "bcm4775";
		gps-ldo = <&tlmm 46 GPIO_ACTIVE_LOW>;
	};'''
if pat.search(s):
    s = pat.sub(node, s, count=1)
    open(p, 'w', encoding='utf-8').write(s)
    print('[patch] dagu DTS: injected minimal bcm4775 node (GPIO 46 LDO only)')
elif 'compatible = "bcm4775"' in s:
    print('[patch] dagu DTS: bcm4775 node already present, nothing to do')
else:
    raise SystemExit('[patch] dagu DTS: expected commented bcm4775 block not found - aborting')
PY
    fi
fi

# ---------------------------------------------------------------------------
# enuma + elish-ROM kernel-side fix (GPS recovery WITHOUT breaking WiFi):
# The external SDX55M errfatals every ~13 s (no matching EFS/calibration).
# Stock SSR restarts esoc0 together with its "restart order" group, which
# includes the wlan subsystem -> wlan is pulled down (deauth / breaks WLAN<->modem
# coexistence) and 通信共享 (P2P GO) negotiation fails.  A PREVIOUS attempt
# suppressed esoc0 restart entirely, but that left the X55 unable to recover
# from faults -> its QMI transport died permanently -> GPS could never acquire
# satellites.  The correct fix (0001) DECOUPLES esoc0 from its restart order:
# esoc0 still restarts on its own (modem self-recovers, QMI_LOC/GNSS stay
# alive), but a modem restart no longer drags the wlan subsystem with it, so
# WiFi + 通信共享 keep working.  Runtime sysfs toggles (disable_restart_work,
# subsysN/restart_level) were verified read-only / ineffective, so a build-time
# patch is required.
# ---------------------------------------------------------------------------
SSR_PATCH="$BUILDER_DIR/patches/0001-soc-qcom-subsystem_restart-decouple-esoc0.patch"
# USG_KEEP_0001=1 lets a CLEAN-based build keep the proven GNSS/WiFi fix
# (spifix1). Without it the SDX55M errfatal drags wlan down and GPS degrades.
if [ "${USG_CLEAN:-0}" = "1" ] && [ "${USG_KEEP_0001:-0}" != "1" ]; then
    echo "[patch] CLEAN build: 0001 esoc0/SSR patch SKIPPED (stock subsystem_restart.c kept)"
elif [ -f "$SSR_PATCH" ]; then
    if git apply --check "$SSR_PATCH" 2>/dev/null; then
        git apply "$SSR_PATCH" && echo "[patch] applied $SSR_PATCH"
    else
        echo "[patch] $SSR_PATCH does not apply cleanly (hunk offsets?); trying patch -p1 --fuzz=3"
        if patch -p1 --fuzz=3 < "$SSR_PATCH" 2>/dev/null; then
            echo "[patch] applied $SSR_PATCH via patch -p1"
        else
            echo "[WARN] $SSR_PATCH NOT applied - locate the anchor manually:"
            echo "       grep -n 'restart_level = %s' drivers/soc/qcom/subsystem_restart.c"
            echo "       and insert the esoc0 skip block after that pr_info()."
        fi
    fi
else
    echo "[WARN] $SSR_PATCH missing - skipping SSR isolation (WiFi-share fix absent)"
fi

# SSR 补丁落地校验: 防止 git apply / patch 静默失败导致补丁没进内核
# (上一次就因此漏修 —— 0001 没编进去, esoc0 仍每 ~13s 重启)
if [ "${USG_CLEAN:-0}" = "1" ] && [ "${USG_KEEP_0001:-0}" != "1" ]; then
    echo "[patch] CLEAN build: 0001 intentionally absent (stock SSR code)"
elif grep -q "decoupled esoc0 from SSR restart order" drivers/soc/qcom/subsystem_restart.c 2>/dev/null; then
    echo "[patch] CONFIRMED: esoc0 decouple block present in subsystem_restart.c (GPS-recover + WiFi-stable fix ACTIVE)"
else
    echo "[FATAL] esoc0 decouple block NOT found in subsystem_restart.c - 0001 patch did NOT land!"
fi

# ---------------------------------------------------------------------------
# Unplug + deep-sleep reboot ROOT FIX (replaces the wakelock guard).
# The PM8150B bark watchdog is petted ONLY by wdog_bark_irq_handler(), but the
# bark IRQ is suppressed at the PMIC level whenever the USB input is suspended
# ("On USB suspend, WDOG IRQ stops triggering", smblib_handle_therm_regulation).
# So on unplug the dog is never petted during deep sleep and the PMIC hard-resets
# the device (~64s later). This patch disables the charger watchdog timer while
# the USB input is suspended and restores it on plugin/resume. Applied on every
# build EXCEPT the capture build, which must keep the bug alive to observe it.
# ---------------------------------------------------------------------------
WDOG_PATCH="$BUILDER_DIR/patches/0002-smb5-unplug-watchdog-fix.patch"
if [ "${USG_CAPTURE:-0}" = "1" ] || [ "${USG_CLEAN:-0}" = "1" ]; then
    echo "[patch] capture/clean build: 0002 charger-watchdog patch SKIPPED (stock smb5-lib.c kept)"
elif [ -f "$WDOG_PATCH" ]; then
    if git apply --check "$WDOG_PATCH" 2>/dev/null; then
        git apply "$WDOG_PATCH" && echo "[patch] applied $WDOG_PATCH"
    else
        echo "[patch] $WDOG_PATCH does not apply cleanly; trying patch -p1 --fuzz=3"
        if patch -p1 --fuzz=3 < "$WDOG_PATCH" 2>/dev/null; then
            echo "[patch] applied $WDOG_PATCH via patch -p1"
        else
            echo "[FATAL] $WDOG_PATCH NOT applied - unplug+sleep reboot root fix missing!"
        fi
    fi
else
    echo "[WARN] $WDOG_PATCH missing - skipping unplug+sleep watchdog fix"
fi

# 看门狗修复落地校验 (防止 git apply / patch 静默失败)
if [ "${USG_CAPTURE:-0}" != "1" ] && [ "${USG_CLEAN:-0}" != "1" ] && grep -q "deep-sleep watchdog fix (Xiaomi Pad 5 Pro" drivers/power/supply/qcom/smb5-lib.c 2>/dev/null; then
    echo "[patch] CONFIRMED: unplug+sleep watchdog fix present in smb5-lib.c (root fix ACTIVE)"
elif [ "${USG_CAPTURE:-0}" = "1" ] || [ "${USG_CLEAN:-0}" = "1" ]; then
    echo "[patch] capture/clean build: 0002 watchdog fix intentionally absent"
else
    echo "[FATAL] unplug+sleep watchdog fix NOT found in smb5-lib.c - 0002 patch did NOT land!"
fi

# ---------------------------------------------------------------------------
# cgroup v2 freezer race fix -- THE real unplug+deep-sleep reboot root cause.
# kernel/cgroup/freezer.c::cgroup_leave_frozen() relied on recalc_sigpending(),
# which races with vfork()/do_signal_stop(): a task can be left logically frozen
# while the cgroup spuriously reports "unfrozen"; that task never re-enters
# do_freezer_trap() and stays stuck forever, so the whole system hangs until the
# SoC hardware watchdog reboots it (~64s later, bootloader reports
# bootreason=reboot, no kernel panic dump -- exactly what was observed). Going to
# deep sleep freezes all tasks, so this race is hit on unplug+screen-off.
# Fix = upstream 7a05073b: mark the task JOBCTL_TRAP_FREEZE + TIF_SIGPENDING so
# it is guaranteed to pass through do_freezer_trap() before returning to
# userspace. Applied on EVERY build (stable and capture) -- this is the fix.
# (Reference: https://github.com/tntgdh-beep/elish-kernel-fix , same elish HW,
#  same 4.19.325-cip base; the buggy freezer.c was confirmed in our exact tree.)
# ---------------------------------------------------------------------------
CGROUP_PATCH="$BUILDER_DIR/patches/0003-cgroup-freezer-fix.patch"
if [ "${USG_CAPTURE:-0}" = "1" ] || [ "${USG_CLEAN:-0}" = "1" ]; then
    echo "[patch] capture/clean build: 0003 cgroup-freezer patch SKIPPED (stock freezer.c kept)"
elif [ -f "$CGROUP_PATCH" ]; then
    if git apply --check "$CGROUP_PATCH" 2>/dev/null; then
        git apply "$CGROUP_PATCH" && echo "[patch] applied $CGROUP_PATCH"
    else
        echo "[patch] $CGROUP_PATCH does not apply cleanly; trying patch -p1 --fuzz=3"
        if patch -p1 --fuzz=3 < "$CGROUP_PATCH" 2>/dev/null; then
            echo "[patch] applied $CGROUP_PATCH via patch -p1"
        else
            echo "[FATAL] $CGROUP_PATCH NOT applied - cgroup freezer root fix missing!"
        fi
    fi
else
    echo "[WARN] $CGROUP_PATCH missing - skipping cgroup freezer fix"
fi

# cgroup freezer 修复落地校验 (防止 git apply / patch 静默失败)
if [ "${USG_CAPTURE:-0}" != "1" ] && [ "${USG_CLEAN:-0}" != "1" ] && grep -q "set_thread_flag(TIF_SIGPENDING)" kernel/cgroup/freezer.c 2>/dev/null; then
    echo "[patch] CONFIRMED: cgroup freezer fix present in freezer.c (race fix ACTIVE)"
elif [ "${USG_CAPTURE:-0}" = "1" ] || [ "${USG_CLEAN:-0}" = "1" ]; then
    echo "[patch] capture/clean build: 0003 cgroup freezer fix intentionally absent"
else
    echo "[FATAL] cgroup freezer fix NOT found in freezer.c - 0003 patch did NOT land!"
fi

echo "=== verification ==="
grep -E '^CONFIG_(AIROHA_GPS|QRTR|QMI_HELPERS|ANDROID_BINDERFS|BPF_SYSCALL|ESOC|MHI_BUS|MHI_QCOM|CNSS2|MSM_SUBSYSTEM_RESTART)=' "$DEF"
echo "=== device DTS GPS node ==="
grep -rn 'compatible = "bcm4775"' arch/arm64/boot/dts/vendor/qcom/${DEVICE}-sm8250.dtsi || echo '(none - normal for enuma: modem GNSS)'

# ---------------------------------------------------------------------------
# Fix upstream build.sh: backport_patches.sh was DELETED upstream
# (commit 1a9295c547 "treewide: remove backport patches and backport steps")
# but the ymdzq kernel tree still downloads it from a dead ?raw=true URL, which
# now 404s and returns an HTML page that crashes `bash` -> build fails. The
# backport is REQUIRED for SUSFS/KernelSU to compile on 4.19, so we vendor the
# last-good version and point build.sh at the local copy instead of downloading.
# We also switch the remaining ?raw=true blob URL (susfs_inline_hook_patches.sh)
# to the stable raw.githubusercontent.com host to avoid the same flaky failure.
# ---------------------------------------------------------------------------
cp "$BUILDER_DIR/scripts/backport_patches.sh" "$KDIR_ABS/backport_patches.sh"
echo "[patch] vendored backport_patches.sh -> $KDIR_ABS/backport_patches.sh"

python3 - "$KDIR_ABS/build.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()

# 1) Replace the dead backport download (404 -> HTML -> bash crash) with a
#    local-file check. The vendored file is copied into the kernel dir above.
old_dl = (
    '    echo "[+] Downloading ${BACKPORT_SCRIPT}..."\n'
    '    if ! curl -LSs --connect-timeout 10 "${BACKPORT_SCRIPT_URL}" -o "${BACKPORT_SCRIPT}"; then\n'
    '        echo "[!] Failed to download ${BACKPORT_SCRIPT}"\n'
    '        exit 1\n'
    '    fi'
)
new_dl = (
    '    echo "[+] Using vendored ${BACKPORT_SCRIPT} (placed by builder)..."\n'
    '    if [ ! -f "${BACKPORT_SCRIPT}" ]; then\n'
    '        echo "[!] ${BACKPORT_SCRIPT} missing in kernel dir"\n'
    '        exit 1\n'
    '    fi'
)
if old_dl in s:
    s = s.replace(old_dl, new_dl, 1)
    print('[patch] build.sh: replaced dead backport download with local-file check')
else:
    print('[patch] build.sh: backport download block not found (upstream may have self-fixed) - skipping')

# 2) Stabilize the remaining ?raw=true blob URLs (JackA1ltman/NonGKI_Kernel_Build_2nd)
#    by converting blob/...?raw=true -> raw.githubusercontent.com/... (covers both the
#    susfs_inline and syscall hook scripts, plus the now-unused backport declaration).
BLOB = 'https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd/blob/mainline/Patches/'
RAW = 'https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/mainline/Patches/'
if BLOB in s:
    s = s.replace(BLOB, RAW)
    s = s.replace('?raw=true', '')
    print('[patch] build.sh: stabilized NonGKI_Kernel_Build_2nd raw URLs (raw.githubusercontent.com)')

# 3) Workaround: upstream SUSFS version mismatch. ymdzq's build.sh applies
#    JackA1ltman's susfs_inline_hook_patches.sh (v2.3.00), which inserts calls to
#    susfs_is_current_proc_no_su() into fs/open.c|stat.c|exec.c. But the SUSFS
#    kernel-side bundled by BakaSU/ReSukiSU is v2.0.0 and does NOT export that
#    symbol -> "implicit declaration" compile error (the previous failure).
#    Until the SUSFS side is aligned to the inline patch, disable SUSFS so build.sh
#    takes the stable syscall-hook path (syscall_hook_patches.sh, which only calls
#    the always-present ksu_handle_* helpers). SukiSU root still works; only the
#    SUSFS hide-root features are dropped. To restore SUSFS later: change this back
#    to 1 AND align the SUSFS kernel-side version with the 2.3.00 inline patch.
if 'SUSFS_ENABLE=1' in s:
    s = s.replace('SUSFS_ENABLE=1', 'SUSFS_ENABLE=0', 1)
    print('[patch] build.sh: disabled SUSFS (v2.3.00 inline vs BakaSU v2.0.0 mismatch) -> syscall-hook path')

open(p, 'w', encoding='utf-8').write(s)
PY

# ---------------------------------------------------------------------------
# unplug_suspend_guard: kernel-space fix for the unplug+deep-sleep reboot.
# Copies a self-contained module into drivers/misc, wires it into the build
# (Makefile + Kconfig) and relies on the defconfig force above
# (CONFIG_UNPLUG_SUSPEND_GUARD=y) to compile it in. It does NOT modify any
# charger / PD / fuel-gauge driver, so charging and other features are untouched.
# ---------------------------------------------------------------------------
USG_C="$BUILDER_DIR/patches/unplug_suspend_guard.c"
if [ "${USG_CAPTURE:-0}" = "1" ] || [ "${USG_CLEAN:-0}" = "1" ]; then
    # Diagnostic/capture build: the guard MUST NOT be compiled in. It holds a
    # suspend wakelock while USB is unplugged, which is exactly what keeps the
    # genuine unplug+deep-sleep panic from happening (so there would be
    # nothing for pstore/ramoops to capture). Skip the module entirely.
    echo "[patch] capture build (USG_CAPTURE=1): unplug_suspend_guard NOT wired in"
elif [ -f "$USG_C" ]; then
    cp "$USG_C" "$KDIR_ABS/drivers/misc/unplug_suspend_guard.c"
    echo "[patch] copied unplug_suspend_guard.c -> drivers/misc/"

    if ! grep -q "unplug_suspend_guard" "$KDIR_ABS/drivers/misc/Makefile"; then
        printf 'obj-$(CONFIG_UNPLUG_SUSPEND_GUARD)\t+= unplug_suspend_guard.o\n' >> "$KDIR_ABS/drivers/misc/Makefile"
        echo "[patch] drivers/misc/Makefile: added unplug_suspend_guard.o"
    fi

    if ! grep -q "UNPLUG_SUSPEND_GUARD" "$KDIR_ABS/drivers/misc/Kconfig"; then
        printf '\nconfig UNPLUG_SUSPEND_GUARD\n\ttristate "Unplug + deep-sleep reboot guard (sm8250)"\n\tdepends on PM_SLEEP && POWER_SUPPLY\n\tdefault n\n\thelp\n\t  Holds a suspend wakelock while USB is unplugged to prevent the\n\t  unplug+deep-sleep reboot seen on Xiaomi Pad 5 Pro (elish/enuma).\n\t  Self-contained; does not modify charger/PD/fuel-gauge drivers.\n\t  Toggle at runtime via the hold_while_unplugged module param.\n' >> "$KDIR_ABS/drivers/misc/Kconfig"
        echo "[patch] drivers/misc/Kconfig: added UNPLUG_SUSPEND_GUARD"
    fi

    # sanity: confirm the config actually landed in the defconfig
    if grep -q '^CONFIG_UNPLUG_SUSPEND_GUARD=y$' "$DEF"; then
        echo "[patch] CONFIRMED: CONFIG_UNPLUG_SUSPEND_GUARD=y in $DEF"
    else
        echo "[WARN] CONFIG_UNPLUG_SUSPEND_GUARD not found in $DEF - forced-enable may have missed"
    fi
else
    echo "[WARN] $USG_C missing - skipping unplug_suspend_guard (reboot guard absent)"
fi

# ---------------------------------------------------------------------------
# 方案 A: ramoops / pstore capture region. Insert a ramoops node into the SoC
# reserved_memory (kona.dtsi) so kernel panics survive reboot and can be read
# from /sys/fs/pstore after the device boots back up.
#   Address 0x100000000 (4GB) lies in free RAM ABOVE every static carveout
#   (the highest one, dfps_data_memory, ends at 0x9e400000). It is valid for
#   both 6GB and 8GB RAM configs. Always sanity-check with
#   `adb shell cat /proc/iomem` on the target device before flashing a new
#   device, in case the bootloader reserves extra high-memory regions.
# ---------------------------------------------------------------------------
KONA="$KDIR_ABS/arch/arm64/boot/dts/vendor/qcom/kona.dtsi"
if [ -f "$KONA" ]; then
python3 - "$KONA" <<'PY'
import sys, os
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if 'ramoops' in s:
    print('[patch] kona.dtsi: ramoops node already present, skipping')
else:
    marker = 'reserved_memory: reserved-memory {'
    idx = s.find(marker)
    if idx == -1:
        print('[WARN] kona.dtsi: reserved_memory node not found - ramoops NOT added')
    else:
        # 用括号配对精确找到 reserved_memory 自己的闭合 '}'，避免误插入到
        # root 闭合处（之前用 s.find('\n};') 会命中顶格的 root 闭合，导致
        # ramoops 成为 root 直接子节点、不被 ramoops 驱动识别、且可能干扰启动）。
        ob = s.find('{', idx)
        depth = 0
        close = -1
        i = ob
        while i < len(s):
            c = s[i]
            if c == '{':
                depth += 1
            elif c == '}':
                depth -= 1
                if depth == 0:
                    close = i
                    break
            i += 1
        if close == -1:
            print('[WARN] kona.dtsi: could not locate reserved_memory closing brace')
        else:
            node = ('\t\tramoops_mem: ramoops@100000000 {\n'
                    '\t\t\tcompatible = "ramoops";\n'
                    '\t\t\treg = <0x1 0x00000000 0x0 0x00100000>;\n'
                    '\t\t\trecord-size = <0x00040000>;\n'
                    '\t\t\tconsole-size = <0x00040000>;\n'
                    '\t\t\tftrace-size = <0x00040000>;\n'
                    '\t\t\tpmsg-size = <0x00040000>;\n'
                    '\t\t\tecc-size = <16>;\n'
                    '\t\t\tno-map;\n'
                    '\t\t};\n')
            # ALWAYS inject the ramoops reserved region (idempotent: skipped
            # above if already present). It is inert unless the kernel enables
            # PSTORE_RAM, and it moves the crash log out of the bootloader's
            # dynamic ramoops_memreserve region (0xB0000000) which is plain
            # System RAM and gets cleared by TZ on resume -> garbage. Declaring
            # it as a DTB "no-map" reservation at 0x100000000 (verified free
            # System RAM on this device) makes TZ preserve it across deep sleep.
            # record-size 0x40000 also turns the dmesg backend ON, so panics
            # survive reboot (the previous build had record_size=0 -> no capture).
            s = s[:close] + '\n' + node + s[close:]
            open(p, 'w', encoding='utf-8').write(s)
            print('[patch] kona.dtsi: inserted ramoops node @0x100000000 (1MB, no-map, record/console/ftrace/pmsg=256KB, ecc=16)')
PY
else
    echo "[WARN] kona.dtsi missing - ramoops NOT added (capture disabled)"
fi

# ---------------------------------------------------------------------------
# SPIFIX: real root cause of unplug + screen-off reboot (2026-11-15 pm_test).
# Live evidence (BISECT kernel, cable unplugged, pm_test=devices):
#   spi_geni 990000.spi: :spi_geni_suspend: runtime PM is active
#   PM: Device 990000.spi failed to suspend: error -16
#   Abort: Callback failed on 990000.spi in platform_pm_suspend returned -16
# freezer succeeds (rc=0); every later stage fails (rc=1).
# 990000.spi is qcom,spi-geni; its only child is spi0.0 = novatek,NVT-ts-spi
# touch panel. The pogo keyboard IRQ storm + NVT-ts resume firmware update
# keep issuing SPI transfers, so the controller is runtime-active exactly when
# the PM core calls spi_geni_suspend(). CAF 4.19 returns -EBUSY there, which
# aborts the WHOLE system suspend; Android retries in a loop until the SoC/PMIC
# watchdog resets the board ~64s after unplug + screen-off (last_kmsg shows
# only "Last boot reason: reboot", no oops/panic).
# Fix = align with upstream spi-geni (5.x): system suspend must NOT veto sleep
# because of runtime-PM accounting. Return 0 and let the PM core proceed.
# ---------------------------------------------------------------------------
if [ "${USG_SPIFIX:-0}" = "1" ]; then
python3 - "$KDIR_ABS/drivers/spi/spi-geni-qcom.c" "${USG_FORCE_RPM:-0}" <<'PY'
import sys
p = sys.argv[1]
force = len(sys.argv) > 2 and sys.argv[2] == '1'
s = open(p, encoding='utf-8').read()
old = "\t\tret = -EBUSY;\n\t\treturn ret;\n"
new_pass = ("\t\t/* spi-geni suspend fix (Xiaomi Pad 5 Pro, elish/enuma):\n"
       "\t\t * child NVT-ts touch panel issues SPI transfers during its\n"
       "\t\t * suspend/resume callbacks, so runtime PM can still be active\n"
       "\t\t * here. Vetoing system suspend with -EBUSY makes Android retry\n"
       "\t\t * forever until the watchdog resets the board. Upstream spi-geni\n"
       "\t\t * simply returns 0 from system suspend; do the same.\n"
       "\t\t */\n")
# spifix3: merely dropping -EBUSY lets an ACTIVE QUPV3 serial engine reach
# suspend_enter() -> the SoC hard-hangs in noirq/syscore and the watchdog
# resets it (pstore empty, probe frozen at screen-off). Force the controller
# down through its own runtime_suspend callback instead.
new_force = ("\t\t/* spi-geni suspend fix (spifix3 force-rpm):\n"
       "\t\t * runtime-active here means the QUPV3 SE still has clocks on.\n"
       "\t\t * Power it down via its own runtime_suspend() before the PM\n"
       "\t\t * core cuts the domain; paired with pm_runtime_force_resume()\n"
       "\t\t * in spi_geni_resume(). Never veto system suspend.\n"
       "\t\t */\n"
       "\t\tif (pm_runtime_force_suspend(dev))\n"
       "\t\t\tGENI_SE_ERR(geni_mas->ipc, true, dev,\n"
       "\t\t\t\t\":%s: force runtime suspend failed\\n\", __func__);\n")
new = new_force if force else new_pass
if old not in s:
    if "spi-geni suspend fix" in s:
        print("[patch] SPIFIX already applied")
    else:
        print("[FATAL] SPIFIX anchor 'ret = -EBUSY; return ret;' not found")
        sys.exit(1)
else:
    if s.count(old) != 1:
        print("[FATAL] SPIFIX anchor not unique (%d)" % s.count(old))
        sys.exit(1)
    s = s.replace(old, new, 1)
    open(p, 'w', encoding='utf-8').write(s)
    print("[patch] SPIFIX applied: spi_geni_suspend() no longer returns -EBUSY")
PY
    if grep -q "spi-geni suspend fix" "$KDIR_ABS/drivers/spi/spi-geni-qcom.c"; then
        echo "[patch] CONFIRMED: spi-geni suspend fix ACTIVE"
    else
        echo "[FATAL] spi-geni suspend fix NOT applied!"
        exit 1
    fi
else
    echo "[patch] SPIFIX not requested (stock spi-geni-qcom.c kept)"
fi

# ---------------------------------------------------------------------------
# FORCE_RPM (spifix3): power the GENI devices DOWN instead of merely waving
# them through. spifix2 post-mortem (on-device probe frozen at screen-off,
# pstore empty, fastboot after watchdog reset) proves that simply returning 0
# leaves the QUPV3 serial engines runtime-active while the PM core cuts their
# clocks, and the SoC never comes back from suspend_enter().
# pm_runtime_force_suspend() bypasses the userspace usage count and calls the
# driver's own runtime_suspend(); the paired force_resume() restores it early
# on the way back. Both drivers already include <linux/pm_runtime.h>.
# ---------------------------------------------------------------------------
if [ "${USG_FORCE_RPM:-0}" = "1" ]; then
python3 - "$KDIR_ABS/drivers/spi/spi-geni-qcom.c" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old = "static int spi_geni_resume(struct device *dev)\n{\n\treturn 0;\n}\n"
new = ("static int spi_geni_resume(struct device *dev)\n"
       "{\n"
       "\t/* spifix3: restore the SE clocks forced off in spi_geni_suspend() */\n"
       "\t(void)pm_runtime_force_resume(dev);\n"
       "\treturn 0;\n"
       "}\n")
if 'spifix3: restore the SE clocks' in s:
    print('[patch] FORCE_RPM spi resume already applied')
else:
    if s.count(old) < 1:
        print('[FATAL] FORCE_RPM: spi_geni_resume() anchor not found'); sys.exit(1)
    s = s.replace(old, new, 1)
    open(p, 'w', encoding='utf-8').write(s)
    print('[patch] FORCE_RPM applied: spi_geni_resume() force-resumes runtime PM')
PY
    if grep -q "spifix3: restore the SE clocks" "$KDIR_ABS/drivers/spi/spi-geni-qcom.c"; then
        echo "[patch] CONFIRMED: spifix3 spi force-resume ACTIVE"
    else
        echo "[FATAL] spifix3 spi force-resume NOT applied!"
        exit 1
    fi
else
    echo "[patch] FORCE_RPM not requested (spifix2 pass-through behaviour kept)"
fi

# ---------------------------------------------------------------------------
# GENI_SERIAL_FIX: the NEXT -EBUSY veto on the same QUPV3 subsystem.
# After the spi-geni fix, the pstore console of the reboot showed:
#   PM: Device 998000.qcom,qup_uart failed to suspend noirq: error -16
# 998000.qcom,qup_uart is qcom,msm-geni-serial-hs (the GPS / keyboard GENI
# UART), runtime_status=active because userspace holds the port open. Its CAF
# 4.19 sys_suspend_noirq() vetoes the WHOLE system suspend in that case.
# Same treatment as spi_geni_suspend(): drop the -EBUSY veto.
# ---------------------------------------------------------------------------
if [ "${USG_GENI_SERIAL_FIX:-0}" = "1" ]; then
python3 - "$KDIR_ABS/drivers/tty/serial/msm_geni_serial.c" "${USG_FORCE_RPM:-0}" <<'PY'
import sys
p = sys.argv[1]
force = len(sys.argv) > 2 and sys.argv[2] == '1'
s = open(p, encoding='utf-8').read()
dirty = False
fn = 'static int msm_geni_serial_sys_suspend_noirq(struct device *dev)'
old = "\t\t\tmutex_unlock(&tty_port->mutex);\n\t\t\treturn -EBUSY;\n"
new_pass = ("\t\t\t/* geni-serial suspend fix (Xiaomi Pad 5 Pro): a GENI UART\n"
       "\t\t\t * kept open by userspace is runtime-active; vetoing system\n"
       "\t\t\t * suspend here aborts the whole sleep and watchdog-resets\n"
       "\t\t\t * the board. Let the PM core proceed (same as spi-geni).\n"
       "\t\t\t */\n")
new_force = ("\t\t\t/* geni-serial suspend fix (spifix3 force-rpm):\n"
       "\t\t\t * a userspace-held UART is still runtime-active here; power\n"
       "\t\t\t * its QUPV3 SE down through the driver's runtime_suspend()\n"
       "\t\t\t * instead of letting suspend_enter() cut live clocks.\n"
       "\t\t\t */\n"
       "\t\t\tif (pm_runtime_force_suspend(dev))\n"
       "\t\t\t\tdev_err(dev, \"spifix3: force runtime suspend failed\\n\");\n")
new = new_force if force else new_pass
if 'geni-serial suspend fix' in s:
    print('[patch] GENI_SERIAL_FIX already applied')
else:
    i = s.find(fn)
    if i < 0:
        print('[FATAL] GENI_SERIAL_FIX: sys_suspend_noirq not found'); sys.exit(1)
    j = s.find('\n}\n', i)
    if j < 0:
        print('[FATAL] GENI_SERIAL_FIX: function end not found'); sys.exit(1)
    j += 3
    body = s[i:j]
    if body.count(old) != 1:
        print('[FATAL] GENI_SERIAL_FIX: anchor count %d' % body.count(old)); sys.exit(1)
    s = s[:i] + body.replace(old, new, 1) + s[j:]
    dirty = True
    print('[patch] GENI_SERIAL_FIX applied: sys_suspend_noirq no longer returns -EBUSY')

if force and 'spifix3: restore UART resources' not in s:
    fn2 = 'static int msm_geni_serial_sys_resume_noirq(struct device *dev)'
    i2 = s.find(fn2)
    if i2 < 0:
        print('[FATAL] FORCE_RPM: sys_resume_noirq not found'); sys.exit(1)
    j2 = s.find('\n}\n', i2)
    if j2 < 0:
        print('[FATAL] FORCE_RPM: resume function end not found'); sys.exit(1)
    j2 += 3
    body2 = s[i2:j2]
    old2 = "\treturn 0;\n"
    new2 = ("\t/* spifix3: restore UART resources forced down in suspend_noirq */\n"
            "\t(void)pm_runtime_force_resume(dev);\n"
            "\treturn 0;\n")
    if body2.count(old2) != 1:
        print('[FATAL] FORCE_RPM: resume anchor count %d' % body2.count(old2)); sys.exit(1)
    s = s[:i2] + body2.replace(old2, new2, 1) + s[j2:]
    dirty = True
    print('[patch] FORCE_RPM applied: sys_resume_noirq force-resumes runtime PM')

if dirty:
    open(p, 'w', encoding='utf-8').write(s)
PY
    if grep -q "geni-serial suspend fix" "$KDIR_ABS/drivers/tty/serial/msm_geni_serial.c"; then
        echo "[patch] CONFIRMED: geni-serial suspend fix ACTIVE"
    else
        echo "[FATAL] geni-serial suspend fix NOT applied!"
        exit 1
    fi
    if [ "${USG_FORCE_RPM:-0}" = "1" ]; then
        if grep -q "spifix3: restore UART resources" "$KDIR_ABS/drivers/tty/serial/msm_geni_serial.c"; then
            echo "[patch] CONFIRMED: spifix3 geni-serial force-resume ACTIVE"
        else
            echo "[FATAL] spifix3 geni-serial force-resume NOT applied!"
            exit 1
        fi
        if grep -q "pm_runtime_force_suspend(dev)" "$KDIR_ABS/drivers/spi/spi-geni-qcom.c"; then
            echo "[patch] CONFIRMED: spifix3 spi force-suspend ACTIVE"
        else
            echo "[FATAL] spifix3 spi force-suspend NOT applied!"
            exit 1
        fi
    fi
else
    echo "[patch] GENI_SERIAL_FIX not requested (stock msm_geni_serial.c kept)"
fi

# ---------------------------------------------------------------------------
# USG_NVTFIX: stop the Novatek touch driver from issuing SPI transfers during
# system suspend (elish/enuma, kernel 4.19.325-cip).
#
# Root cause confirmed on device 2026-11-17:
#   * `unbind spi0.0` (NVT-ts) + `echo mem` -> /sys/power/suspend_stats/success=1,
#     uptime continuous, NO reset.
#   * NVT bound + `echo mem` -> PMIC "Hard Reset" / "PS_HOLD" every single time.
#   * ftrace: NVT-ts IRQ 511 burst at screen-off, spi_geni runtime-active,
#     PM: Device 990000.spi failed to suspend: error -16 (-EBUSY).
#   * nvt_ts_suspend() takes the WAKEUP_GESTURE branch, calls enable_irq_wake()
#     and keeps the SPI controller busy, so spi_geni_suspend() vetoes the whole
#     system suspend and Android retries until the watchdog hard-resets.
#
# This patch forces the deep-sleep branch at suspend time:
#   ts->db_wakeup = 0  ->  `if (!ts->db_wakeup) nvt_irq_enable(false)` runs,
#   and the gesture branch (enable_irq_wake + 0x13) is skipped.
# Also cancels the charger notifier work that can issue SPI writes.
#
# Trade-off: double-tap / pen-click wake-up is disabled; use the power key.
# ---------------------------------------------------------------------------
if [ "${USG_NVTFIX:-0}" = "1" ]; then
python3 - "$KDIR_ABS/drivers/input/touchscreen/nt36523/nt36xxx.c" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if 'USG_NVTFIX' in s:
    print('[patch] USG_NVTFIX already applied')
else:
    anchor = ('\tif (!bTouchIsAwake) {\n'
              '\t\tNVT_LOG("Touch is already suspend\\n");\n'
              '\t\treturn 0;\n'
              '\t}\n')
    n = s.count(anchor)
    if n != 1:
        print('[FATAL] NVTFIX: suspend anchor count %d (expected 1)' % n)
        sys.exit(1)
    inject = anchor + (
        '\n\t/* USG_NVTFIX: force deep-sleep branch. In gesture mode the driver\n'
        '\t * calls enable_irq_wake() and keeps touching the SPI bus, which makes\n'
        '\t * spi_geni_suspend() return -EBUSY and vetoes the whole system\n'
        '\t * suspend (watchdog hard reset afterwards). Setting db_wakeup=0 makes\n'
        '\t * nvt_irq_enable(false) run and skips the gesture branch.\n'
        '\t */\n'
        '\tts->db_wakeup = 0;\n')
    s = s.replace(anchor, inject, 1)
    open(p, 'w', encoding='utf-8').write(s)
    print('[patch] USG_NVTFIX applied: db_wakeup forced to 0 in nvt_ts_suspend')
PY
    if grep -q "USG_NVTFIX" "$KDIR_ABS/drivers/input/touchscreen/nt36523/nt36xxx.c"; then
        echo "[patch] CONFIRMED: NVT suspend gesture-disable fix ACTIVE"
    else
        echo "[FATAL] USG_NVTFIX not applied!"
        exit 1
    fi
else
    echo "[patch] USG_NVTFIX not requested (stock nt36xxx.c kept)"
fi

# ---------------------------------------------------------------------------
# USG_SHALLOW (spifix4): skip the vendor SoC power-collapse entry point.
#
# Evidence gathered on the device:
#   * pm_test=core (all devices + syscore suspended, suspend_ops->enter NOT
#     called) always exits cleanly -> everything up to syscore_suspend is fine.
#   * real deep sleep calls suspend_ops->enter() -> hard reset, no pstore.
#   * runtime mem_sleep=s2idle also resets: this tree has a vendor change in
#     suspend_enter() that jumps into s2idle_loop() BEFORE dpm_suspend_noirq.
#   * runtime lpm_levels.sleep_disabled=Y (alone or with s2idle) also resets.
# Conclusion: the downstream QCOM RPMH/AOP/PSCI power-collapse path is broken
# on this source tree. Keep the full device/syscore suspend (real power saving)
# but idle the boot CPU in WFI instead of handing control to the SoC firmware.
# A module_param allows reverting to the stock path without reflashing.
# ---------------------------------------------------------------------------
if [ "${USG_SHALLOW:-0}" = "1" ]; then
python3 - "$KDIR_ABS/kernel/power/suspend.c" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if 'USG_SHALLOW' in s:
    print('[patch] USG_SHALLOW already applied')
else:
    inc = '#include <linux/wakeup_reason.h>\n'
    if s.count(inc) != 1:
        print('[FATAL] SHALLOW: include anchor count %d' % s.count(inc)); sys.exit(1)
    s = s.replace(inc, inc + '#include <linux/timekeeping.h>\n#include <linux/irqflags.h>\n', 1)

    fn = 'static int suspend_enter(suspend_state_t state, bool *wakeup)\n'
    if s.count(fn) != 1:
        print('[FATAL] SHALLOW: suspend_enter anchor count %d' % s.count(fn)); sys.exit(1)
    helper = '''/* spifix4: this downstream tree hard-resets inside the vendor SoC power
 * collapse path (RPMH/AOP/PSCI). Devices and syscore are already suspended
 * here, so wait in WFI on the boot CPU until a wakeup event is pending.
 */
static bool usg_shallow = true;
module_param(usg_shallow, bool, 0644);
MODULE_PARM_DESC(usg_shallow, "skip vendor power collapse, idle in WFI");

static void usg_shallow_suspend_loop(void)
{
\tu64 deadline = ktime_get_mono_fast_ns() + 600ULL * 1000000000ULL;

\tpr_info("USG_SHALLOW: WFI loop entered (no SoC power collapse)\\n");
\twhile (!pm_wakeup_pending()) {
\t\tif (ktime_get_mono_fast_ns() >= deadline) {
\t\t\tpr_info("USG_SHALLOW: timeout, resuming\\n");
\t\t\tbreak;
\t\t}
\t\tlocal_irq_enable();
\t\tasm volatile("wfi" : : : "memory");
\t\tlocal_irq_disable();
\t}
\tpr_info("USG_SHALLOW: wakeup pending, leaving WFI loop\\n");
}

'''
    s = s.replace(fn, helper + fn, 1)

    old = '\t\t\terror = suspend_ops->enter(state);\n'
    new = ('\t\t\tif (usg_shallow) {\n'
           '\t\t\t\tusg_shallow_suspend_loop();\n'
           '\t\t\t\terror = 0;\n'
           '\t\t\t} else {\n'
           '\t\t\t\terror = suspend_ops->enter(state);\n'
           '\t\t\t}\n')
    if s.count(old) != 1:
        print('[FATAL] SHALLOW: enter anchor count %d' % s.count(old)); sys.exit(1)
    s = s.replace(old, new, 1)
    open(p, 'w', encoding='utf-8').write(s)
    print('[patch] USG_SHALLOW applied: suspend_ops->enter replaced by WFI loop')
PY
    if grep -q "USG_SHALLOW: WFI loop entered" "$KDIR_ABS/kernel/power/suspend.c"; then
        echo "[patch] CONFIRMED: spifix4 shallow suspend ACTIVE"
    else
        echo "[FATAL] spifix4 shallow suspend NOT applied!"
        exit 1
    fi
else
    echo "[patch] USG_SHALLOW not requested (stock kernel/power/suspend.c kept)"
fi

echo "[patch] done"
