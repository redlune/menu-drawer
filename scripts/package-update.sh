#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
build="$root/.build"
repo=https://github.com/redlune/menu-drawer
signing_key="${SPARKLE_PRIVATE_KEY:-}"
unset SPARKLE_PRIVATE_KEY

if ! public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$root/Resources/Info.plist" 2>/dev/null)"; then
    printf '%s\n' 'Set SUPublicEDKey in Resources/Info.plist before packaging an update.' >&2
    exit 1
fi
if [[ -z "$signing_key" ]]; then
    printf '%s\n' 'Set the SPARKLE_PRIVATE_KEY GitHub Actions secret before packaging an update.' >&2
    exit 1
fi

mkdir -p "$build/dist"
key_public="$(printf '%s' "$signing_key" | xcrun swift -module-cache-path "$build/ModuleCache" "$root/scripts/sparkle-key.swift" public)"
if [[ "$key_public" != "$public_key" ]]; then
    printf '%s\n' 'SPARKLE_PRIVATE_KEY does not match SUPublicEDKey in Resources/Info.plist.' >&2
    exit 1
fi
work="$(mktemp -d "$build/Update.XXXXXX")"
output=""
complete=false
cleanup() {
    rm -rf "$work"
    if ! "$complete" && [[ -n "$output" ]]; then rm -rf "$output"; fi
}
trap cleanup EXIT
sparkle="$work/Sparkle"
bash "$root/scripts/unpack-sparkle.sh" "$sparkle"

bash "$root/build.sh" >&2
volume="$work/Volume"
mkdir "$volume"
/usr/bin/lockf -k "$build/.publish.lock" ditto "$build/MenuDrawer.app" "$volume/MenuDrawer.app"
codesign --verify --strict --deep "$volume/MenuDrawer.app"
plist="$volume/MenuDrawer.app/Contents/Info.plist"
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$plist")" != "$public_key" ]]; then
    printf '%s\n' 'The built app has a different update key.' >&2
    exit 1
fi
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s\n' 'CFBundleShortVersionString must be a three-part release version.' >&2
    exit 1
fi

output="$(mktemp -d "$build/dist/v$version.XXXXXX")"
archive="MenuDrawer-$version-macOS-arm64.dmg"
ln -s /Applications "$volume/Applications"
hdiutil create -quiet -srcfolder "$volume" -volname 'Menu Drawer' -format UDZO "$output/$archive"
hdiutil verify -quiet "$output/$archive"
printf '%s' "$signing_key" | "$sparkle/bin/generate_appcast" --ed-key-file - --maximum-deltas 0 \
    --download-url-prefix "$repo/releases/download/v$version/" \
    --full-release-notes-url "$repo/releases" "$output" >&2
printf '%s' "$signing_key" | "$sparkle/bin/sign_update" --ed-key-file - --verify "$output/appcast.xml" >&2
complete=true
printf '%s\n' "$output"
