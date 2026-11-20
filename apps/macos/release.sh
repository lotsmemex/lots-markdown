#!/bin/bash
# bump VERSION       Update Info.plist; review and commit it before preparing.
# prepare NOTES      Build committed HEAD, sign the ZIP, and write build/releases/vVERSION/.
# publish VERSION    After approval, publish the already prepared assets to GitHub Releases.
# Requires OpenSSL 3 and jq; publish also requires gh. Never commit the signing key.
# LM_RELEASE_KEY_FILE overrides the key for local prepare tests only.
set -euo pipefail
umask 077
cd "$(dirname "$0")"
app_dir=$PWD
repo=lotsmemex/lots-markdown
plist=/usr/libexec/PlistBuddy
production_key="$HOME/Library/Application Support/Lots Markdown/Release Signing/ed25519.pem"
command=${1:-}

die() { printf '%s\n' "$*" >&2; exit 1; }
valid_version() { [[ $1 =~ ^(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})$ ]]; }
version_triplet() { IFS=. read -r major minor patch <<< "$1"; printf '%06d%06d%06d' "$major" "$minor" "$patch"; }
current_version() { "$plist" -c 'Print CFBundleShortVersionString' "$1"; }
current_build() { "$plist" -c 'Print CFBundleVersion' "$1"; }

if [[ $command == bump && $# == 2 ]]; then
    git diff --quiet HEAD -- Info.plist || die 'Info.plist already has uncommitted changes.'
    previous=$(current_version Info.plist)
    build=$(current_build Info.plist)
    valid_version "$previous" && valid_version "$2" || die 'Use a numeric MAJOR.MINOR.PATCH version.'
    [[ $(version_triplet "$2") > $(version_triplet "$previous") ]] || die 'Version must increase.'
    [[ $build =~ ^[1-9][0-9]{0,8}$ ]] || die 'Invalid CFBundleVersion.'
    next=$((build + 1))
    bumped=$(mktemp ./Info.plist.XXXXXX)
    trap 'rm -f -- "$bumped"' EXIT
    # Preserve the formatting and comments of the tracked template.
    LM_VERSION=$2 LM_BUILD=$next perl -0777 -pe '
        s{(<key>CFBundleShortVersionString</key>\s*<string>)[0-9.]+(</string>)}{$1$ENV{LM_VERSION}$2} or die;
        s{(<key>CFBundleVersion</key>\s*<string>)[0-9]+(</string>)}{$1$ENV{LM_BUILD}$2} or die;
    ' Info.plist > "$bumped"
    /usr/bin/plutil -lint "$bumped" >/dev/null
    chmod "$(stat -f %Lp Info.plist)" "$bumped"
    mv "$bumped" Info.plist
    printf 'Bumped to %s (build %s). Review and commit Info.plist before preparing.\n' "$2" "$next"
    exit 0
fi

[[ $# == 2 && ( $command == prepare || $command == publish ) ]] || die 'Usage: release.sh bump VERSION | prepare NOTES | publish VERSION'
export LC_ALL=C
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
key=$production_key
if [[ $command == prepare ]]; then key=${LM_RELEASE_KEY_FILE:-$key}; fi
[[ -f $key && ! -L $key && $(stat -f %Lp "$key") == 600 ]] || die 'The Ed25519 private key must be a regular file with mode 600.'
openssl pkey -in "$key" -pubout -out "$scratch/public.pem"
openssl pkey -pubin -in "$scratch/public.pem" -outform DER -out "$scratch/public.der"
# RFC 8410 SubjectPublicKeyInfo prefix for a 32-byte Ed25519 public key.
[[ $(wc -c < "$scratch/public.der") -eq 44 && $(head -c 12 "$scratch/public.der" | xxd -p) == 302a300506032b6570032100 ]] || die 'The signing key is not Ed25519.'
public_key=$(tail -c 32 "$scratch/public.der" | openssl base64 -A)
root=$(git rev-parse --show-toplevel)
commit=$(git rev-parse HEAD)
git show "$commit:apps/macos/Info.plist" > "$scratch/Info.plist"
version=$(current_version "$scratch/Info.plist")
build=$(current_build "$scratch/Info.plist")
valid_version "$version" && [[ $build =~ ^[1-9][0-9]{0,8}$ && $build -gt 1 ]] || die 'Commit a new release version and build first.'
tag="v$version"
zip_name="LotsMarkdown-$version.zip"
url="https://github.com/$repo/releases/download/$tag/$zip_name"
output="$app_dir/build/releases/$tag"

if [[ $command == prepare ]]; then
    [[ -n $2 && ! -e $output ]] || die 'Release notes are required and the output directory must not exist.'
    mkdir -p "$scratch/source" "$scratch/assets" "$(dirname "$output")"
    git -C "$root" archive "$commit" apps/macos core themes | tar -xf - -C "$scratch/source"
    cd "$scratch/source/apps/macos"
    "$plist" -c "Add LMUpdatePublicKey string $public_key" Info.plist
    ./build.sh
    app='build/Lots Markdown.app'
    /usr/bin/codesign --verify --deep --strict "$app"
    ditto -c -k --norsrc --keepParent "$app" "$scratch/assets/$zip_name"
    openssl pkeyutl -sign -rawin -inkey "$key" -in "$scratch/assets/$zip_name" -out "$scratch/signature"
    sha=$(shasum -a 256 "$scratch/assets/$zip_name" | cut -d ' ' -f 1)
    jq -n --arg version "$version" --argjson build "$build" --arg url "$url" --arg sha256 "$sha" \
        --arg signature "$(openssl base64 -A -in "$scratch/signature")" --arg notes "$2" \
        '{version:$version, build:$build, url:$url, sha256:$sha256, signature:$signature, notes:$notes}' > "$scratch/assets/update.json"
    printf '%s\n' "$commit" > "$scratch/assets/source-commit"
    mv "$scratch/assets" "$output"
    printf 'Prepared %s (build %s) at %s; nothing published.\n' "$tag" "$build" "$output"
    exit 0
fi

[[ $2 == "$version" && -d $output && $(cat "$output/source-commit") == "$commit" ]] || die 'Prepare the committed version before publishing.'
[[ $(gh api "repos/$repo/git/ref/heads/main" --jq .object.sha) == "$commit" ]] || die 'HEAD is not the published main commit.'
refs=$(gh api "repos/$repo/git/matching-refs/tags/$tag" --jq '.[].ref')
if grep -Fxq "refs/tags/$tag" <<< "$refs"; then die 'The release tag already exists.'; fi
zip="$output/$zip_name"
manifest="$output/update.json"
sha=$(shasum -a 256 "$zip" | cut -d ' ' -f 1)
jq -e --arg v "$version" --argjson b "$build" --arg u "$url" --arg sha "$sha" \
    '.version == $v and .build == $b and .url == $u and .sha256 == $sha and (.notes | type == "string" and length > 0)' "$manifest" >/dev/null
jq -er '.signature | strings' "$manifest" | tr -d '\n' | openssl base64 -d -A -out "$scratch/signature"
openssl pkeyutl -verify -rawin -pubin -inkey "$scratch/public.pem" -in "$zip" -sigfile "$scratch/signature"
ditto -x -k "$zip" "$scratch/unpacked"
app="$scratch/unpacked/Lots Markdown.app"
[[ $(find "$scratch/unpacked" -mindepth 1 -maxdepth 1 -print) == "$app" ]] || die 'Expected exactly one app in the ZIP.'
info="$app/Contents/Info.plist"
[[ $(current_version "$info") == "$version" && $(current_build "$info") == "$build" && \
   $("$plist" -c 'Print CFBundleIdentifier' "$info") == com.lotsmemex.markdown && \
   $("$plist" -c 'Print LMUpdatePublicKey' "$info") == "$public_key" ]] || die 'App metadata does not match the release.'
/usr/bin/codesign --verify --deep --strict "$app"

latest=$(gh release list -R "$repo" --exclude-drafts --exclude-pre-releases --json isLatest,tagName --jq '.[] | select(.isLatest) | .tagName')
if [[ -n $latest ]]; then
    gh release download "$latest" -R "$repo" -p update.json -D "$scratch"
    latest_build=$(jq -er '.build | numbers | select(. >= 1 and . == floor)' "$scratch/update.json")
    latest_version=$(jq -er '.version | strings' "$scratch/update.json")
    valid_version "$latest_version" && [[ $latest_build =~ ^[1-9][0-9]{0,8}$ && $build -gt $latest_build && \
       $(version_triplet "$version") > $(version_triplet "$latest_version") ]] || die 'Release is not newer than the live feed.'
    # Existing installations pin the original key. Don't publish after an accidental key change.
    latest_zip="LotsMarkdown-$latest_version.zip"
    gh release download "$latest" -R "$repo" -p "$latest_zip" -D "$scratch"
    jq -er '.signature | strings' "$scratch/update.json" | tr -d '\n' | openssl base64 -d -A -out "$scratch/signature"
    openssl pkeyutl -verify -rawin -pubin -inkey "$scratch/public.pem" \
        -in "$scratch/$latest_zip" -sigfile "$scratch/signature" || die 'The previous release was signed by a different key.'
fi
gh release create "$tag" "$zip" "$manifest" -R "$repo" --target "$commit" --latest \
    --title "Lots Markdown $version" --notes="$(jq -r .notes "$manifest")"
