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

python3 - "$DEF" <<'PY'
import re, sys
path = sys.argv[1]
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
}
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
if [ -f "$SSR_PATCH" ]; then
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
if grep -q "decoupled esoc0 from SSR restart order" drivers/soc/qcom/subsystem_restart.c 2>/dev/null; then
    echo "[patch] CONFIRMED: esoc0 decouple block present in subsystem_restart.c (GPS-recover + WiFi-stable fix ACTIVE)"
else
    echo "[FATAL] esoc0 decouple block NOT found in subsystem_restart.c - 0001 patch did NOT land!"
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

echo "[patch] done"
