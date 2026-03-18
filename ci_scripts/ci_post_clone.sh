#!/bin/sh
set -e

TARBALL="MobileVLCKit-3.6.0-c73b779f-dd8bfdba.tar.xz"
URL="https://download.videolan.org/pub/cocoapods/prod/${TARBALL}"
DEST="$CI_WORKSPACE/MobileVLCKit-binary"
TMP_TAR="/tmp/MobileVLCKit.tar.xz"
TMP_DIR="/tmp/vlckit_extract"

echo "Downloading MobileVLCKit 3.6.0 (stable)..."
curl -L --fail --retry 3 --retry-delay 5 "$URL" -o "$TMP_TAR"

echo "Extracting..."
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
tar -xJf "$TMP_TAR" -C "$TMP_DIR"

echo "Moving to workspace..."
mkdir -p "$DEST"
INNER=$(find "$TMP_DIR" -maxdepth 1 -mindepth 1 -type d | head -1)
cp -R "$INNER/." "$DEST/"

echo "MobileVLCKit ready at $DEST"
ls "$DEST"
