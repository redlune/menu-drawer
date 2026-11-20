#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
destination="$1"
version=2.10.1
checksum=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
cache="$root/.build/Dependencies"
archive="$cache/Sparkle-$version.tar.xz"
mkdir -p "$cache" "$destination"

verify_archive() {
    printf '%s  %s\n' "$checksum" "$1" | shasum -a 256 -c - >/dev/null
}

if [[ ! -f "$archive" ]] || ! verify_archive "$archive"; then
    download="$(mktemp "$cache/Sparkle-$version.XXXXXX")"
    trap 'rm -f "$download"' EXIT
    /usr/bin/curl --fail --silent --show-error --location --retry 2 --proto '=https' --proto-redir '=https' \
        "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz" -o "$download"
    verify_archive "$download"
    mv -f "$download" "$archive"
fi

verify_archive "$archive"
/usr/bin/tar -xf "$archive" -C "$destination" \
    ./Sparkle.framework ./LICENSE ./bin/generate_appcast ./bin/sign_update
