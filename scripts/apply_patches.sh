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

echo "=== verification ==="
grep -E '^CONFIG_(AIROHA_GPS|QRTR|QMI_HELPERS|ANDROID_BINDERFS|BPF_SYSCALL)=' "$DEF"
echo "=== device DTS GPS node ==="
grep -rn 'compatible = "bcm4775"' arch/arm64/boot/dts/vendor/qcom/${DEVICE}-sm8250.dtsi || echo '(none - normal for enuma: modem GNSS)'
echo "[patch] done"
