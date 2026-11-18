#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
build="$root/.build"
staging="$(mktemp -d "$build.staging.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/MenuDrawer.app"
cache="$build/ModuleCache"
mkdir -p "$cache" "$app/Contents/MacOS" "$app/Contents/Resources"

sdk="$(xcrun --sdk macosx --show-sdk-path)"
target="arm64-apple-macosx27.0"
xcrun clang -isysroot "$sdk" -target "$target" -fobjc-arc -fmodules \
    -fmodules-cache-path="$cache" -Wall -Wextra -Werror \
    -c "$root/Sources/VisibilityBridge.m" -o "$staging/VisibilityBridge.o"
xcrun swiftc -sdk "$sdk" -target "$target" -swift-version 6 -O -warnings-as-errors \
    -module-cache-path "$cache" -import-objc-header "$root/Sources/VisibilityBridge.h" \
    "$root"/Sources/*.swift "$staging/VisibilityBridge.o" -o "$app/Contents/MacOS/MenuDrawer"

cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
cp "$root/Resources/MenuDrawer.icns" "$app/Contents/Resources/"
for catalog in "$root"/Resources/*.xcstrings; do
    xcrun xcstringstool compile "$catalog" --output-directory "$app/Contents/Resources"
done
plutil -lint "$app/Contents/Info.plist"
codesign --force --sign "${SIGN_IDENTITY:--}" "$app"
codesign --verify --strict "$app"
ditto "$app" "$build/MenuDrawer.app"
printf '%s\n' "$build/MenuDrawer.app"
