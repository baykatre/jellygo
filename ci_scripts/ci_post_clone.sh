#!/bin/sh
set -ex

# Derive repo root from script location (ci_scripts/ is inside the repo)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
DERIVED_DATA="/Volumes/workspace/DerivedData"

echo "REPO_ROOT=$REPO_ROOT"

# --- Download MobileVLCKit ---
URL="https://github.com/baykatre/jellygo/releases/download/v0.3.0/MobileVLCKit-3.6.0.tar.xz"
DEST="$REPO_ROOT/MobileVLCKit-binary"
TMP_TAR="/tmp/MobileVLCKit.tar.xz"
TMP_DIR="/tmp/vlckit_extract"

echo "Downloading MobileVLCKit 3.6.0..."
curl -L --fail --retry 3 --retry-delay 5 "$URL" -o "$TMP_TAR"

echo "Extracting..."
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
tar -xJf "$TMP_TAR" -C "$TMP_DIR"

mkdir -p "$DEST"
cp -R "$TMP_DIR/MobileVLCKit.xcframework" "$DEST/"
echo "MobileVLCKit ready at $DEST"

# --- Resolve SPM packages and patch invalid bundle IDs ---
echo "Resolving SPM packages..."
xcodebuild -resolvePackageDependencies \
  -project "$REPO_ROOT/JellyGo.xcodeproj" \
  -scheme JellyGo \
  -derivedDataPath "$DERIVED_DATA"

echo "Patching invalid framework bundle IDs (underscores)..."
find "$DERIVED_DATA/SourcePackages" -name "Info.plist" 2>/dev/null | while read plist; do
  id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist" 2>/dev/null || true)
  if echo "$id" | grep -q "_"; then
    fixed=$(echo "$id" | tr '_' '-')
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $fixed" "$plist"
    echo "Patched: $id -> $fixed in $plist"
  fi
done

echo "Done."
