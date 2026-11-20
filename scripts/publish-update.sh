#!/bin/bash
set -euo pipefail

directory="$1"
version="$2"
commit="$3"
tag="v$version"
archive="$directory/MenuDrawer-$version-macOS-arm64.dmg"
appcast="$directory/appcast.xml"

if [[ ! -s "$archive" || ! -s "$appcast" ]]; then
    printf 'Release %s is missing its DMG or signed appcast.\n' "$tag" >&2
    exit 1
fi

latest="$(gh release list --exclude-drafts --exclude-pre-releases --json tagName,isLatest \
    --jq '.[] | select(.isLatest) | .tagName')"
if [[ -n "$latest" ]]; then
    if [[ "$(printf '%s\n' "$latest" "$tag" | sort -V | tail -1)" != "$tag" || "$latest" == "$tag" ]]; then
        printf 'Release %s must be newer than %s.\n' "$tag" "$latest" >&2
        exit 1
    fi
    if [[ "$(gh release view "$latest" --json assets --jq 'any(.assets[]; .name == "appcast.xml")')" == true ]]; then
        previous="$(mktemp -d)"
        trap 'rm -rf "$previous"' EXIT
        gh release download "$latest" --pattern appcast.xml --dir "$previous"
        python3 - "$appcast" "$previous/appcast.xml" <<'PY'
import sys
import xml.etree.ElementTree as xml

def build(path):
    version = xml.parse(path).findtext("./channel/item/{http://www.andymatuschak.org/xml-namespaces/sparkle}version")
    if version is None or not version.isdecimal():
        sys.exit("The appcast has an invalid build number.")
    return int(version)

if build(sys.argv[1]) <= build(sys.argv[2]):
    sys.exit("CFBundleVersion must increase for Sparkle to offer the update.")
PY
    fi
fi

# A preexisting tag overrides --target, including when a failed run is retried.
tag_refs="$(git ls-remote "https://github.com/$GH_REPO.git" "refs/tags/$tag" "refs/tags/$tag^{}")"
tag_commit="$(printf '%s\n' "$tag_refs" | awk 'NF { if ($2 ~ /\^\{\}$/) peeled=$1; else direct=$1 } END { print peeled ? peeled : direct }')"
if [[ -n "$tag_commit" && "$tag_commit" != "$commit" ]]; then
    printf 'Release tag %s already points to a different commit.\n' "$tag" >&2
    exit 1
fi

if draft="$(gh release view "$tag" --json isDraft,targetCommitish,databaseId)"; then
    if [[ "$(jq -r .isDraft <<< "$draft")" != true ]]; then
        printf 'Release %s is already public.\n' "$tag" >&2
        exit 1
    fi
    if [[ -z "$tag_commit" && "$(jq -r .targetCommitish <<< "$draft")" != "$commit" ]]; then
        printf 'Existing draft %s targets a different commit.\n' "$tag" >&2
        exit 1
    fi
else
    gh release create "$tag" --draft --target "$commit" --title "Menu Drawer $version" --generate-notes
    draft="$(gh release view "$tag" --json databaseId)"
fi

gh release upload "$tag" --clobber "$archive" "$appcast"
assets="$(gh api "repos/$GH_REPO/releases/$(jq -r .databaseId <<< "$draft")/assets")"
for path in "$archive" "$appcast"; do
    digest="sha256:$(shasum -a 256 "$path" | cut -d ' ' -f1)"
    jq -e --arg name "$(basename "$path")" --arg digest "$digest" \
        'any(.[]; .name == $name and .state == "uploaded" and .digest == $digest)' <<< "$assets" >/dev/null
done
gh release edit "$tag" --draft=false --latest
