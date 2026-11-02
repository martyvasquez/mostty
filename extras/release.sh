#!/bin/bash
# mostty: build, sign and publish a release that installed copies of mostty
# pick up through Sparkle.
#
#   extras/release.sh 0.2.0            # build + publish GitHub release v0.2.0
#   extras/release.sh auto             # version 0.1.<build> (what CI uses)
#   extras/release.sh 0.2.0 --local    # build into release-out/ only (for testing)
#
# What it does:
#   1. zig build (ReleaseFast)
#   2. stamps CFBundleShortVersionString=<version>, CFBundleVersion=<build>
#      where <build> is the commit count on main (always increasing)
#   3. re-signs the app (ad-hoc, keeping entitlements / hardened runtime)
#   4. zips it and writes release-out/appcast.xml, signed with the "mostty" EdDSA
#      key in your login keychain (created with: generate_keys --account mostty),
#      or with the key in $SPARKLE_ED_KEY when set (CI)
#   5. creates GitHub release v<version> with the zip + appcast.xml
#
# Installed apps read https://github.com/martyvasquez/mostty/releases/latest/download/appcast.xml
set -euo pipefail

REPO="martyvasquez/mostty"
KEY_ACCOUNT="mostty"

version="${1:-}"
mode="${2:-publish}"
# MOSTTY_BUILD overrides the build number (only useful for local test builds).
build="${MOSTTY_BUILD:-$(git rev-list --count HEAD)}"
[ "$version" = "auto" ] && version="0.1.$build"
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: $0 <x.y.z> [--local]" >&2
  exit 1
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
dist="$root/release-out"
tag="v$version"

# Sparkle's tools ship with the Sparkle Swift package Xcode resolves.
# $SPARKLE_BIN overrides it (CI downloads them; there's no DerivedData yet).
sparkle_bin="${SPARKLE_BIN:-$(dirname "$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*/artifacts/sparkle/Sparkle/bin/generate_appcast' 2>/dev/null | head -1)")}"
[ -x "$sparkle_bin/generate_appcast" ] || { echo "Sparkle tools not found (build once in Xcode/zig build first)" >&2; exit 1; }

if [ "$mode" != "--local" ]; then
  [ -z "$(git status --porcelain)" ] || { echo "Working tree not clean; commit first." >&2; exit 1; }
  [ "$(git branch --show-current)" = "main" ] || { echo "Release from main." >&2; exit 1; }
  git fetch -q origin main
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "main is not pushed (or is behind origin)." >&2; exit 1; }
  if gh release view "$tag" --repo "$REPO" >/dev/null 2>&1; then
    echo "Release $tag already exists." >&2; exit 1
  fi
fi

echo "==> mostty $version (build $build)"

echo "==> Building"
zig build -Doptimize=ReleaseFast

rm -rf "$dist" && mkdir -p "$dist/archives"
app="$dist/mostty.app"
ditto "$root/zig-out/mostty.app" "$app"

echo "==> Stamping version"
plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$build" "$app/Contents/Info.plist"

echo "==> Signing app"
codesign --force --deep --sign - \
  --preserve-metadata=entitlements,requirements,flags,runtime "$app"
codesign --verify --deep --strict "$app"

echo "==> Packaging"
zip="$dist/archives/mostty-$version.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"

if [ "$mode" = "--local" ]; then
  prefix="http://localhost:8000/"
else
  prefix="https://github.com/$REPO/releases/download/$tag/"
fi

echo "==> Writing appcast"
key_args=(--account "$KEY_ACCOUNT")
if [ -n "${SPARKLE_ED_KEY:-}" ]; then
  key_file="$(mktemp)"
  trap 'rm -f "$key_file"' EXIT
  chmod 600 "$key_file"
  printf '%s' "$SPARKLE_ED_KEY" > "$key_file"
  key_args=(--ed-key-file "$key_file")
fi
"$sparkle_bin/generate_appcast" \
  "${key_args[@]}" \
  --download-url-prefix "$prefix" \
  --link "https://github.com/$REPO" \
  --maximum-deltas 0 \
  -o "$dist/appcast.xml" \
  "$dist/archives"
grep -q 'sparkle:edSignature' "$dist/appcast.xml" || { echo "appcast is missing the EdDSA signature" >&2; exit 1; }

if [ "$mode" = "--local" ]; then
  cp "$dist/appcast.xml" "$dist/archives/appcast.xml"
  echo
  echo "Local release ready in $dist"
  echo "  serve:  (cd '$dist/archives' && python3 -m http.server 8000)"
  echo "  point:  defaults write com.mostty.app MosttyUpdateFeedURL http://localhost:8000/appcast.xml"
  echo "  undo:   defaults delete com.mostty.app MosttyUpdateFeedURL"
  exit 0
fi

echo "==> Publishing $tag"
gh release create "$tag" "$zip" "$dist/appcast.xml" \
  --repo "$REPO" \
  --title "mostty $version" \
  --generate-notes \
  --target "$(git rev-parse HEAD)"

echo
echo "Published https://github.com/$REPO/releases/tag/$tag"
echo "Installed copies of mostty will offer it on their next update check."
