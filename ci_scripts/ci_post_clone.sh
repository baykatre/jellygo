#!/bin/sh
set -e

VLCKIT_VERSION="3.6.0"
DEST="$CI_WORKSPACE/MobileVLCKit-binary"
ZIP_URL="https://download.videolan.org/pub/cocoapods/unstable/MobileVLCKit-${VLCKIT_VERSION}.zip"
TMP_ZIP="/tmp/MobileVLCKit.zip"
TMP_DIR="/tmp/vlckit_extract"

echo "Downloading MobileVLCKit ${VLCKIT_VERSION}..."
curl -L --retry 3 --retry-delay 5 "$ZIP_URL" -o "$TMP_ZIP"

echo "Extracting..."
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
unzip -q "$TMP_ZIP" -d "$TMP_DIR"

echo "Moving to workspace..."
mkdir -p "$DEST"
# Zip içindeki klasör yapısını bul ve içeriği taşı
INNER=$(find "$TMP_DIR" -maxdepth 1 -type d | tail -1)
cp -R "$INNER/." "$DEST/"

echo "MobileVLCKit ready at $DEST"
ls "$DEST"
