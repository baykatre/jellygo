#!/bin/sh
set -ex

# Derive repo root from script location (ci_scripts/ is inside the repo)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

URL="https://github.com/baykatre/jellygo/releases/download/v0.3.0/MobileVLCKit-3.6.0.tar.xz"
DEST="$REPO_ROOT/MobileVLCKit-binary"
TMP_TAR="/tmp/MobileVLCKit.tar.xz"
TMP_DIR="/tmp/vlckit_extract"

echo "REPO_ROOT=$REPO_ROOT"
echo "DEST=$DEST"

echo "Downloading MobileVLCKit 3.6.0..."
curl -L --fail --retry 3 --retry-delay 5 "$URL" -o "$TMP_TAR"

echo "Extracting..."
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
tar -xJf "$TMP_TAR" -C "$TMP_DIR"

echo "Moving to workspace..."
mkdir -p "$DEST"
cp -R "$TMP_DIR/MobileVLCKit.xcframework" "$DEST/"

echo "MobileVLCKit ready at $DEST"
ls "$DEST"
