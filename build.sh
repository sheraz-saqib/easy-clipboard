#!/bin/bash
# ./build.sh          → build/Easy Clipboard.app
# ./build.sh install  → also copy to /Applications and launch
# ./build.sh dmg      → build/EasyClipboard.dmg to share (Apple Silicon, macOS 14+)
set -euo pipefail
cd "$(dirname "$0")"
APP="build/Easy Clipboard.app"

rm -rf "$APP" build/AppIcon.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/AppIcon.iconset

# Keep target in sync with LSMinimumSystemVersion in Info.plist (default would be the host's macOS).
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 main.swift -o "$APP/Contents/MacOS/EasyClipboard"
cp Info.plist "$APP/Contents/"
# CI passes VERSION from the git tag (v1.2 → 1.2); local builds keep Info.plist's value.
if [[ -n "${VERSION:-}" ]]; then
  plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
fi

swift icon.swift build/icon.png "$APP/Contents/Resources/MenuIcon.png"
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
  # Ad-hoc signature changes every build, so the old Accessibility grant goes stale
  # (toggle still shows ON but doesn't apply). Reset it so launch prompts fresh.
  tccutil reset Accessibility com.sherazcoder.easyclipboard >/dev/null 2>&1 || true
  pkill -x EasyClipboard && sleep 1 || true
  rm -rf "/Applications/Easy Clipboard.app"
  cp -R "$APP" /Applications/
  open "/Applications/Easy Clipboard.app"
  echo "Installed to /Applications"
fi

if [[ "${1:-}" == "dmg" ]]; then
  # Classic drag-to-install window: the app + a shortcut to /Applications.
  rm -rf build/dmg build/rw.dmg build/EasyClipboard.dmg
  mkdir -p build/dmg
  cp -R "$APP" build/dmg/
  ln -s /Applications build/dmg/Applications
  cp "$APP/Contents/Resources/AppIcon.icns" build/dmg/.VolumeIcon.icns
  # Writable image first, so the mounted volume can be flagged "has custom icon".
  hdiutil create -volname "Easy Clipboard" -srcfolder build/dmg -ov -format UDRW build/rw.dmg >/dev/null
  MNT=$(hdiutil attach -nobrowse -readwrite build/rw.dmg | awk -F'\t' '/\/Volumes\//{print $NF}')
  xcrun SetFile -a C "$MNT"
  hdiutil detach "$MNT" >/dev/null
  hdiutil convert build/rw.dmg -format UDZO -o build/EasyClipboard.dmg >/dev/null
  rm -rf build/dmg build/rw.dmg
  # Icon on the .dmg file itself. Survives AirDrop; browser downloads strip it (mounted volume still shows it).
  osascript -l JavaScript -e "ObjC.import('AppKit'); \$.NSWorkspace.sharedWorkspace.setIconForFileOptions(\$.NSImage.alloc.initWithContentsOfFile('$(pwd)/build/icon.png'), '$(pwd)/build/EasyClipboard.dmg', 0)" >/dev/null
  echo "Share this: $(pwd)/build/EasyClipboard.dmg"
fi
