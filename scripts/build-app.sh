#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="XFinder"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$ROOT_DIR"

# NOTE: `set -e` + pipefail aborts the whole script on a non-zero git exit.
# `git describe --exact-match` exits 128 when HEAD has no tag (the normal case
# between releases), so every git call below MUST end in `|| true`, or the app
# never gets packaged and dist silently keeps a stale binary.
VERSION="${XFINDER_VERSION:-}"
if [[ -z "$VERSION" ]]; then
    VERSION="$(git describe --tags --exact-match 2>/dev/null | sed 's/^v//' || true)"
fi
if [[ -z "$VERSION" ]]; then
    VERSION="$(git describe --tags --always --dirty 2>/dev/null | sed 's/^v//' || true)"
fi
if [[ -z "$VERSION" ]]; then
    VERSION="0.1.0-dev"
fi
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

swift build -c release

rm -rf "$APP_DIR"
rm -rf "$ROOT_DIR/dist/FinderHub.app"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp ".build/release/$APP_NAME" "$MACOS_DIR/$APP_NAME"
cp "$ROOT_DIR/Assets/XFinder.icns" "$RESOURCES_DIR/XFinder.icns"
# Bundled so the in-app "What's New" panel can show it.
cp "$ROOT_DIR/CHANGELOG.md" "$RESOURCES_DIR/CHANGELOG.md"
cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$RESOURCES_DIR/THIRD_PARTY_NOTICES.md"
cp -R "$ROOT_DIR/ThirdPartyLicenses" "$RESOURCES_DIR/ThirdPartyLicenses"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>XFinder</string>
    <key>CFBundleIdentifier</key>
    <string>local.xfinder.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>XFinder</string>
    <key>CFBundleIconFile</key>
    <string>XFinder</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>XFinder controls Finder to import open Finder windows as panes for your workspaces.</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>XFinder needs access to your Desktop to list and manage files in panes that open it.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>XFinder needs access to your Documents to list and manage files in panes that open it.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>XFinder needs access to your Downloads to list and manage files in panes that open it.</string>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>XFinder needs access to removable volumes to browse files stored on them.</string>
    <key>NSNetworkVolumesUsageDescription</key>
    <string>XFinder needs access to network volumes to browse files stored on them.</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS will grant Apple Events automation (Import Finder
# Windows) and per-folder privacy access. An UNSIGNED app cannot be granted
# automation permission, so Finder import silently fails without this.
codesign --force --deep --sign - "$APP_DIR"

echo "Built $APP_DIR"
