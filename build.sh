#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
build="$root/.build"
staging="$(mktemp -d "$build.staging.XXXXXX")"
previous="$staging/Previous.app"
cleanup() {
    if [[ -e "$previous" || -L "$previous" ]]; then
        printf 'Previous build retained at %s\n' "$previous" >&2
    else
        rm -rf "$staging"
    fi
}
trap cleanup EXIT
app="$staging/MenuDrawer.app"
cache="$build/ModuleCache"
mkdir -p "$cache" "$app/Contents/MacOS" "$app/Contents/Resources"

sdk="$(xcrun --sdk macosx --show-sdk-path)"
target="arm64-apple-macosx27.0"
identity="${SIGN_IDENTITY:--}"
plist="$app/Contents/Info.plist"
cp "$root/Resources/Info.plist" "$plist"
swift_flags=(-sdk "$sdk" -target "$target" -swift-version 6 -O -warnings-as-errors
    -module-cache-path "$cache" -import-objc-header "$root/Sources/VisibilityBridge.h")

if public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$plist" 2>/dev/null)"; then
    if [[ ! "$public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
        printf '%s\n' 'SUPublicEDKey must be a base64-encoded Ed25519 public key.' >&2
        exit 1
    fi
    sparkle="$staging/Sparkle"
    bash "$root/scripts/unpack-sparkle.sh" "$sparkle"
    framework="$app/Contents/Frameworks/Sparkle.framework"
    mkdir -p "$app/Contents/Frameworks"
    ditto "$sparkle/Sparkle.framework" "$framework"
    cp "$sparkle/LICENSE" "$app/Contents/Resources/Sparkle-LICENSE.txt"
    if [[ "$identity" != "-" ]]; then
        codesign --force --sign "$identity" "$framework"
    fi
    swift_flags+=(-D MENU_DRAWER_UPDATER -F "$app/Contents/Frameworks" -framework Sparkle
        -Xlinker -rpath -Xlinker @executable_path/../Frameworks)
fi

xcrun clang -isysroot "$sdk" -target "$target" -fobjc-arc -fmodules \
    -fmodules-cache-path="$cache" -Wall -Wextra -Werror \
    -c "$root/Sources/VisibilityBridge.m" -o "$staging/VisibilityBridge.o"
xcrun swiftc "${swift_flags[@]}" \
    "$root"/Sources/*.swift "$staging/VisibilityBridge.o" -o "$app/Contents/MacOS/MenuDrawer"

cp "$root/Resources/MenuDrawer.icns" "$app/Contents/Resources/"
for catalog in "$root"/Resources/*.xcstrings; do
    xcrun xcstringstool compile "$catalog" --output-directory "$app/Contents/Resources"
done
plutil -lint "$plist"
codesign --force --sign "$identity" "$app"
codesign --verify --strict --deep "$app"
output="$build/MenuDrawer.app"

# Serialize publication so two builds cannot replace each other's backup.
/usr/bin/lockf -k "$build/.publish.lock" /bin/bash -euc '
    app=$1 output=$2 previous=$3
    published=false
    finish() {
        if "$published"; then
            rm -rf "$previous"
        else
            if [[ ! -e "$app" ]]; then rm -rf "$output"; fi
            if [[ -e "$previous" || -L "$previous" ]]; then mv "$previous" "$output"; fi
        fi
    }
    trap finish EXIT
    trap "exit 130" INT
    trap "exit 143" TERM
    if [[ -e "$output" || -L "$output" ]]; then mv "$output" "$previous"; fi
    mv "$app" "$output"
    codesign --verify --strict --deep "$output"
    published=true
' bash "$app" "$output" "$previous"
printf '%s\n' "$output"
