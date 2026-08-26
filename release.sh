#!/bin/bash
# Cut a new llcpp release and point the tap at it.
#
#   ./release.sh 0.4.0
#
# Unlike publish.sh (a one-time bootstrap that created both repos), this is
# safe to re-run for every version.
set -euo pipefail

VER="${1:?usage: ./release.sh <version>   e.g. ./release.sh 0.4.0}"
USER=HatimDiab
REPO="$USER/llcpp"
SRC="$(cd "$(dirname "$0")" && pwd)"
TAP="$(brew --repository)/Library/Taps/hatimdiab/homebrew-tap"
FORMULA="$TAP/Formula/llcpp.rb"

[[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must be X.Y.Z" >&2; exit 1; }
[[ -d "$TAP" ]] || { echo "tap not found at $TAP — run: brew tap $USER/tap" >&2; exit 1; }

cd "$SRC"
[[ -z "$(git status --porcelain)" ]] || { echo "working tree is dirty; commit first" >&2; exit 1; }
if git rev-parse -q --verify "refs/tags/v$VER" >/dev/null; then
    echo "tag v$VER already exists" >&2; exit 1
fi

# 1. Bump the version in the script itself, so `llcpp --version` matches the tag.
#    The formula's test block asserts exactly this, so a mismatch fails the build.
/usr/bin/sed -i '' -e "s|^__version__ = .*|__version__ = \"$VER\"|" llcpp
./llcpp --version | grep -q "$VER" || { echo "version bump did not take" >&2; exit 1; }

git add llcpp
git commit -m "$VER"
git tag "v$VER"
git push origin main
git push origin "v$VER"

# 2. GitHub regenerates tag tarballs, so the checksum must come from GitHub's
#    copy — never from a local `git archive`, which produces a different blob.
URL="https://github.com/$REPO/archive/refs/tags/v$VER.tar.gz"
echo "waiting for the tag tarball…"
until curl -fsIL "$URL" >/dev/null 2>&1; do sleep 2; done
SHA=$(curl -fsL "$URL" | shasum -a 256 | awk '{print $1}')
echo "github tarball sha256: $SHA"

# 3. Point the formula at the new tag.
/usr/bin/sed -i '' \
  -e "s|^  url .*|  url \"$URL\"|" \
  -e "s|^  sha256 .*|  sha256 \"$SHA\"|" \
  "$FORMULA"

cd "$TAP"
git add -A
git commit -m "llcpp $VER"

# 4. Prove it builds and passes its own test block before anyone else installs it.
#    Everything above this point is local or already-tagged; the tap push is last.
brew audit --strict --online "$USER/tap/llcpp"
brew reinstall --build-from-source "$USER/tap/llcpp"
brew test "$USER/tap/llcpp"

git push origin main

echo
echo "llcpp $VER released. Users get it with:"
echo "  brew update && brew upgrade llcpp"
