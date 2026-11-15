#!/bin/bash
# Build a genuinely clean LineageOS sm8250 4.19.325 kernel for elish / enuma.
#
# Why this is feasible: LineageOS/android_kernel_xiaomi_sm8250 and
# ymdzq/kernel_xiaomi_sm8250_mod are forks of the SAME CAF/CIP tree
# (4.19.325, localversion-cip/-st differ only by patch level). The LOS tree
# already carries the Xiaomi BSP (techpack, cnss2, touchscreen, clk/qcom,
# soc/qcom, codecs, gpu/msm, power/supply/qcom) and vendor/xiaomi/*.config.
# The only structural gap is arch/arm64/boot/dts/vendor/xiaomi/*.
#
# What is deliberately NOT carried over from the aptusitu tree:
#   - SukiSU / KernelPatch / KPM (no root injection, no Image binary patch)
#   - 0001 esoc0/SSR, 0002 smb5 watchdog, 0003 cgroup freezer patches
#   - unplug_suspend_guard wakelock driver
#   - the A17/MIUI compatibility rewrites in apply_patches.sh
# Only the Xiaomi DTS files and the device defconfig are borrowed.
#
# Usage: build_los_clean.sh <kernel-dir> <bsp-donor-dir> <device> <config_base>
set -euo pipefail

KDIR=${1:-kernel}
BSP=${2:-bsp}
DEVICE=${3:-enuma}
CONFIG_BASE=${4:-ymdzq_defconfig}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILDER_DIR="$(dirname "$SCRIPT_DIR")"
K="$(cd "$KDIR" && pwd)"
B="$(cd "$BSP" && pwd)"

echo "[LOS] kernel tree : $K"
echo "[LOS] BSP donor   : $B"
echo "[LOS] device      : $DEVICE"
echo "[LOS] config base : $CONFIG_BASE"
sed -n '2,6p' "$K/Makefile"
printf '[LOS] localversion: '
tr -d '\n' < "$K/localversion-cip"; printf ' '
tr -d '\n' < "$K/localversion-st"; echo

# --- 1) The only missing BSP: Xiaomi DTS ----------------------------------
# Copy the xiaomi DTS directory wholesale; for qcom/ only ADD files the LOS
# tree lacks (--ignore-existing) so no LOS source is ever overwritten.
mkdir -p "$K/arch/arm64/boot/dts/vendor/xiaomi"
cp -a "$B/arch/arm64/boot/dts/vendor/xiaomi/." "$K/arch/arm64/boot/dts/vendor/xiaomi/"
rsync -a --ignore-existing \
  "$B/arch/arm64/boot/dts/vendor/qcom/" "$K/arch/arm64/boot/dts/vendor/qcom/"
cp "$B/arch/arm64/boot/dts/vendor/Makefile" "$K/arch/arm64/boot/dts/vendor/Makefile"
echo "[LOS] xiaomi dts files: $(find "$K/arch/arm64/boot/dts/vendor/xiaomi" -type f | wc -l)"

# --- 2) Configuration ------------------------------------------------------
# The donor defconfig is the exact one used by every previous (bootable)
# build, so the source tree is the ONLY variable in this experiment.
DEF="$K/arch/arm64/configs/${DEVICE}_defconfig"
cp "$B/arch/arm64/configs/${DEVICE}_defconfig" "$DEF"
# Strip every root-injection symbol; the LOS tree has no KernelSU Kconfig at
# all, so leaving these lines would be misleading (olddefconfig drops them).
sed -i -E '/^CONFIG_(KSU|KPM|KSU_[A-Z_]*|SUSFS|KERNEL_PATCH|KERNEL_SU)[A-Z_]*=/Id' "$DEF"
echo "[LOS] defconfig lines: $(wc -l < "$DEF")"

export PATH="$HOME/ZyC-clang/bin:$PATH"
command -v clang
clang --version | head -2
MAKE_ARGS=(ARCH=arm64 SUBARCH=arm64 O=out CC=clang
  CROSS_COMPILE=aarch64-linux-gnu-
  CROSS_COMPILE_ARM32=arm-linux-gnueabi-
  CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
  CLANG_TRIPLE=aarch64-linux-gnu-)

cd "$K"
case "$CONFIG_BASE" in
  official_ikcfg)
    # Align with the stock OS4 boot.img's embedded IKCFG (extracted from
    # diag/boot_cmp/official_boot.img, stored in configs/cfg_official.txt).
    mkdir -p out
    cp "$BUILDER_DIR/configs/cfg_official.txt" out/.config
    echo "[LOS] seeding .config from stock IKCFG"
    make "${MAKE_ARGS[@]}" olddefconfig
    ;;
  *)
    make "${MAKE_ARGS[@]}" "${DEVICE}_defconfig"
    ;;
esac

echo "[LOS] effective config (root/suspend related):"
grep -E '^CONFIG_(KSU|KPM|SUSFS|PM_SLEEP_DEBUG|ESOC|AIROHA_GPS|SERIAL_MSM_GENI|CHARGER_LN8000|QPNP_SMB5)=' out/.config || true

# --- 3) Build --------------------------------------------------------------
echo "[LOS] building Image ..."
make "${MAKE_ARGS[@]}" -j"$(nproc)" Image
if [ ! -s out/arch/arm64/boot/Image ]; then
  echo "[LOS] FATAL: no Image produced"; exit 1
fi
ls -lh out/arch/arm64/boot/Image

# dtb is collected for AK3 parity but never flashed (anykernel.sh keeps the
# dtb/dtbo mv lines commented, so the stock dtbo stays untouched).
if make "${MAKE_ARGS[@]}" -j"$(nproc)" dtbs >/tmp/los_dtbs.log 2>&1; then
  echo "[LOS] dtbs built"
else
  echo "[LOS] WARNING: dtbs failed, kernel Image is still valid"
  tail -20 /tmp/los_dtbs.log || true
fi
find out/arch/arm64/boot/dts -name '*.dtb' -exec cat {} + > out/arch/arm64/boot/dtb 2>/dev/null || true
[ -s out/arch/arm64/boot/dtb ] || : > out/arch/arm64/boot/dtb

# --- 4) AnyKernel3 package -------------------------------------------------
rm -rf anykernel
git clone -q --depth=1 -b kona https://github.com/liyafe1997/AnyKernel3 anykernel
cp "$SCRIPT_DIR/ak3/anykernel.sh" anykernel/anykernel.sh
mkdir -p anykernel/kernels
cp out/arch/arm64/boot/Image anykernel/kernels/Image
cp out/arch/arm64/boot/dtb anykernel/kernels/dtb

echo "[LOS] kernel banner:"
strings out/arch/arm64/boot/Image | grep -m1 'Linux version' || true
echo "[LOS] injection markers (must all be zero):"
for s in KernelPatch SukiSU sukisu KPM unplug_suspend_guard 'decoupled esoc0'; do
  printf '  %-24s %s\n' "$s" "$(grep -a -c "$s" out/arch/arm64/boot/Image 2>/dev/null || echo 0)"
done

cd anykernel
ZIP="Kernel_LOS_${DEVICE}_${CONFIG_BASE}_$(date +%Y%m%d_%H%M%S)_anykernel3.zip"
zip -r9 -q "$ZIP" ./* -x .git .gitignore out/ ./*.zip
mv "$ZIP" "$K/"
echo "[LOS] ARTIFACT: $K/$ZIP"
