#!/bin/bash
set -e

cd /root/SN/Koreader

export ANDROID_NDK_HOME=/root/android-ndk-r23c
export ANDROID_HOME=/root/koreader-old/base/toolchain/android-sdk-linux

INSTALL_DIR=koreader-android-aarch64-unknown-linux-android21
ASSETS_DIR=$INSTALL_DIR/luajit-launcher/assets/module
KOREADER_DIR=$INSTALL_DIR/koreader
LAUNCHER_DIR=platform/android/luajit-launcher
APK_OUT=$INSTALL_DIR/luajit-launcher/outputs/apk/arm64Rocks/release/NativeActivity.apk
FINAL_APK=/tmp/koreader-sn.apk
ADB="/mnt/d/Program Files/ADB/adb.exe"
APKSIGNER=/root/koreader-old/base/toolchain/android-sdk-linux/build-tools/34.0.0/apksigner
# Auto-detect device port
DEVICE=$("$ADB" devices 2>/dev/null | grep '192.168.137.106' | awk '{print $1}')
if [ -z "$DEVICE" ]; then
    echo "ERROR: Supernote not connected" && exit 1
fi

# Auto-increment version
VERSION="supernote-eink-v$(date +%Y%m%d-%H%M%S)"
echo "=== Version: $VERSION ==="

# 1. Write version
echo "$VERSION" > $KOREADER_DIR/git-rev
echo "$VERSION" > $ASSETS_DIR/version.txt

# 2. Rebuild 7z
echo "=== Packing 7z ==="
rm -f $ASSETS_DIR/koreader.7z
cd $KOREADER_DIR
./tools/mkrelease.sh --epoch="$(date +%Y-%m-%d)" \
    ../../$ASSETS_DIR/koreader.7z . \
    '-x!libs' '-x!sdcv' '-x!*.dbg' '-x!*.dSYM' \
    '-x!spec' '-x!test' '-x!ev_replay.py' \
    '-x!resources/fonts*' '-x!resources/icons/src*' \
    '-x!l10n/templates' '-xr!*.po' '-xr!*.orig'
cd /root/SN/Koreader

# 3. Build APK (clean gradle cache to force repackage)
VCODE=$(($(cat .verscode 2>/dev/null || echo 0) + 1))
echo "=== Building APK (versCode=$VCODE) ==="
rm -rf $INSTALL_DIR/luajit-launcher/gradle $INSTALL_DIR/luajit-launcher/outputs
$LAUNCHER_DIR/gradlew \
    --project-dir=$LAUNCHER_DIR \
    --project-cache-dir=$(pwd)/$INSTALL_DIR/luajit-launcher/gradle \
    -PassetsPath=$(pwd)/$INSTALL_DIR/luajit-launcher/assets \
    -PbuildDir=$(pwd)/$INSTALL_DIR/luajit-launcher \
    -PlibsPath=$(pwd)/$INSTALL_DIR/luajit-launcher/libs/ \
    -PsevenZipLib=koreader-monolibtic \
    -PprojectName=KOReader \
    -PversCode=$VCODE \
    -PversName="$VERSION" \
    app:assemblearm64RocksRelease

# 4. Verify version in APK
PACKED_VER=$(unzip -p $APK_OUT assets/module/version.txt)
echo "=== APK version: $PACKED_VER ==="
if [ "$PACKED_VER" != "$VERSION" ]; then
    echo "ERROR: version mismatch!" && exit 1
fi

# 5. Sign
echo "=== Signing ==="
cp $APK_OUT $FINAL_APK
$APKSIGNER sign --ks ~/.android/debug.keystore --ks-pass pass:android --key-pass pass:android $FINAL_APK

# 6. Install
echo "=== Installing ==="
"$ADB" -s $DEVICE install -r $FINAL_APK

echo "$VCODE" > .verscode
echo "=== Done: $VERSION (versCode=$VCODE) ==="
