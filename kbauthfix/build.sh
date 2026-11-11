#!/usr/bin/env bash
# Build a minimal LSPosed module APK using only the Android SDK CLI tools.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}"
PLATFORM="$(ls -1 "$SDK"/platforms/*/android.jar 2>/dev/null | sort -V | tail -1)"
BT="$(ls -1d "$SDK"/build-tools/* 2>/dev/null | sort -V | tail -1)"
echo "SDK=$SDK"
echo "PLATFORM=$PLATFORM"
echo "BUILD_TOOLS=$BT"
test -n "$PLATFORM" && test -n "$BT"

rm -rf out stubcp dexout apk unsigned.apk aligned.apk KBAuthFix.apk res.flata
mkdir -p out dexout apk/assets

# Stub classes exist only at compile time (the real ones come from LSPosed).
# android.jar is needed for android.util.Log.
javac -source 8 -target 8 -nowarn -encoding UTF-8 -d out \
    -classpath "$PLATFORM" \
    $(find stub src -name '*.java')
mkdir -p stubcp
cp -r out/de stubcp/
rm -rf out/de

"$BT/d8" --lib "$PLATFORM" --classpath stubcp --output dexout \
    $(find out -name '*.class')
test -f dexout/classes.dex

cp dexout/classes.dex apk/classes.dex
cp assets/xposed_init apk/assets/xposed_init

if [ -x "$BT/aapt2" ]; then
  "$BT/aapt2" link -o unsigned.apk -I "$PLATFORM" \
      --manifest AndroidManifest.xml \
      --min-sdk-version 30 --target-sdk-version 36 \
      -A apk/assets
else
  "$BT/aapt" package -f -M AndroidManifest.xml -A apk/assets \
      -I "$PLATFORM" -F unsigned.apk
fi
(cd apk && zip -q -g ../unsigned.apk classes.dex)

keytool -genkeypair -alias kbauthfix -keystore kb.jks \
    -storepass 123456 -keypass 123456 \
    -dname "CN=KBAuthFix, OU=WorkBuddy" -keyalg RSA -keysize 2048 -validity 10000
"$BT/zipalign" -f 4 unsigned.apk aligned.apk
"$BT/apksigner" sign --ks kb.jks --ks-pass pass:123456 --key-pass pass:123456 \
    --v1-signing-enabled true --v2-signing-enabled true \
    --out KBAuthFix.apk aligned.apk
"$BT/apksigner" verify --verbose KBAuthFix.apk

echo "=== APK contents ==="
unzip -l KBAuthFix.apk
echo "=== xposed_init ==="
unzip -p KBAuthFix.apk assets/xposed_init
