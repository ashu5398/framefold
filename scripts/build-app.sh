#!/bin/sh
# Builds FrameFold.app into ./build. Needs only the Xcode Command Line Tools.
#   scripts/build-app.sh            release build
#   CONFIG=debug scripts/build-app.sh
set -eu

cd "$(dirname "$0")/.."
CONFIG=${CONFIG:-release}
SDK=$(xcrun --show-sdk-path)
APP=build/FrameFold.app

mkdir -p build
OPT=-O

# Some Command Line Tools installs ship two module maps that both define SwiftBridging, which
# breaks every Swift import. Hide the duplicate behind a VFS overlay instead of editing /Library.
VFS=""
CLT_SWIFT_INCLUDE=/Library/Developer/CommandLineTools/usr/include/swift
if [ -f "$CLT_SWIFT_INCLUDE/bridging.modulemap" ] && [ -f "$CLT_SWIFT_INCLUDE/module.modulemap" ] \
    && grep -q "module SwiftBridging" "$CLT_SWIFT_INCLUDE/module.modulemap"; then
    # Implicit module builds re-split these flags on spaces, so keep the overlay at a path without any.
    OVERLAY_DIR=$(mktemp -d "${TMPDIR:-/tmp}/framefold-vfs.XXXXXX")
    : > "$OVERLAY_DIR/empty.modulemap"
    cat > "$OVERLAY_DIR/overlay.yaml" <<YAML
{ "version": 0, "case-sensitive": "false", "roots": [ { "type": "directory", "name": "$CLT_SWIFT_INCLUDE",
  "contents": [ { "type": "file", "name": "bridging.modulemap", "external-contents": "$OVERLAY_DIR/empty.modulemap" } ] } ] }
YAML
    VFS="-vfsoverlay $OVERLAY_DIR/overlay.yaml -Xcc -ivfsoverlay -Xcc $OVERLAY_DIR/overlay.yaml"
fi
[ "$CONFIG" = debug ] && OPT="-Onone -g -D DEBUG"

echo "Compiling ($CONFIG)…"
# shellcheck disable=SC2046,SC2086
xcrun swiftc -parse-as-library -module-name FrameFold \
    -target "$(uname -m)-apple-macos14.0" -sdk "$SDK" $OPT $VFS -Xcc -DACCELERATE_NEW_LAPACK \
    $(find Sources -name '*.swift') -o build/FrameFold

echo "Bundling…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/FrameFold "$APP/Contents/MacOS/FrameFold"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ ! -f build/AppIcon.icns ]; then
    # shellcheck disable=SC2086
    xcrun swiftc -sdk "$SDK" $VFS scripts/make-icon.swift -o build/make-icon
    build/make-icon build/AppIcon.iconset >/dev/null
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"

# Face recognition model (see scripts/make-face-model.sh), made on first build. Without it,
# people aren't grouped. SKIP_FACE_MODEL=1 builds without it.
if [ ! -d Resources/Models/AuraFace.mlpackage ] && [ -z "${SKIP_FACE_MODEL:-}" ]; then
    scripts/make-face-model.sh
fi
if [ -d Resources/Models/AuraFace.mlpackage ]; then
    cp -R Resources/Models/AuraFace.mlpackage "$APP/Contents/Resources/"
    cp Resources/Models/AuraFace-LICENSE.md "$APP/Contents/Resources/"
else
    echo "warning: Resources/Models/AuraFace.mlpackage missing; run scripts/make-face-model.sh for people grouping"
fi

# Ad-hoc signature so macOS can remember the Photos and camera permissions.
codesign --force --sign - --entitlements Resources/FrameFold.entitlements "$APP"
echo "Built $APP"
