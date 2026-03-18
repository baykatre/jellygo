#!/bin/sh
set -ex

URL="https://github.com/baykatre/jellygo/releases/download/v0.3.0/MobileVLCKit-3.6.0.tar.xz"
DEST="$CI_WORKSPACE/MobileVLCKit-binary"
TMP_TAR="/tmp/MobileVLCKit.tar.xz"
TMP_DIR="/tmp/vlckit_extract"

echo "CI_WORKSPACE=$CI_WORKSPACE"
echo "DEST=$DEST"
df -h /tmp

echo "Downloading MobileVLCKit 3.6.0..."
curl -L --fail --retry 3 --retry-delay 5 "$URL" -o "$TMP_TAR"
echo "Download complete. Size: $(du -sh $TMP_TAR)"

echo "Extracting..."
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
tar -xJf "$TMP_TAR" -C "$TMP_DIR"

echo "Moving to workspace..."
mkdir -p "$DEST"
cp -R "$TMP_DIR/MobileVLCKit.xcframework" "$DEST/"

echo "MobileVLCKit ready at $DEST"
ls "$DEST"
