#!/bin/bash
# Cut a new llcpp release and open a tap PR pointing at it.
#
#   ./release.sh 0.4.0
#
# Must be run from an up-to-date main. The version bump is a real commit on
# main and the tag is cut from it, so running this from a feature branch
# would tag the wrong history.
#
# The tap side goes through a pull request rather than a direct push to main,
# so the tap's own test-bot CI gets to build and test the formula first.
set -euo pipefail

VER="${1:?usage: ./release.sh <version>   e.g. ./release.sh 0.4.0}"
# NOT `USER` — that is an environment variable Homebrew reads to resolve the
# real OS user, and clobbering it makes `brew install` fail with
# "user HatimDiab doesn't exist".
OWNER=HatimDiab
REPO="$OWNER/llcpp"
SRC="$(cd "$(dirname "$0")" && pwd)"
TAP="$(brew --repository)/Library/Taps/hatimdiab/homebrew-tap"
FORMULA="$TAP/Formula/llcpp.rb"

[[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must be X.Y.Z" >&2; exit 1; }
[[ -d "$TAP" ]] || { echo "tap not found at $TAP — run: brew tap $OWNER/tap" >&2; exit 1; }
command -v gh >/dev/null || { echo "gh not installed" >&2; exit 1; }

cd "$SRC"

# The bump commit and the tag both belong on main. Releasing from a feature
# branch tags history that main does not have.
BRANCH=$(git rev-parse --abbrev-ref HEAD)
[[ "$BRANCH" == "main" ]] || { echo "on '$BRANCH'; releases are cut from main" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "working tree is dirty; commit first" >&2; exit 1; }

# Refuse to build on a stale main — otherwise the push at the end is rejected
# after the tag already exists locally.
git fetch --quiet origin
if [[ "$(git rev-parse @)" != "$(git rev-parse @{u})" ]]; then
    echo "main is not in sync with origin/main; pull (or push) first" >&2; exit 1
fi
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
git push origin "$BRANCH"
git push origin "v$VER"

# 2. GitHub regenerates tag tarballs, so the checksum must come from GitHub's
#    copy — never from a local `git archive`, which produces a different blob.
URL="https://github.com/$REPO/archive/refs/tags/v$VER.tar.gz"
echo "waiting for the tag tarball…"
until curl -fsIL "$URL" >/dev/null 2>&1; do sleep 2; done
SHA=$(curl -fsL "$URL" | shasum -a 256 | awk '{print $1}')
echo "github tarball sha256: $SHA"

# 3. Point the formula at the new tag, on a branch of its own.
cd "$TAP"
git fetch --quiet origin
git checkout main --quiet
git pull --quiet --ff-only
git checkout -b "llcpp-$VER" --quiet

/usr/bin/sed -i '' \
  -e "s|^  url .*|  url \"$URL\"|" \
  -e "s|^  sha256 .*|  sha256 \"$SHA\"|" \
  "$FORMULA"

git add -A
git commit -m "llcpp $VER"

# 4. Prove it builds and passes its own test block before asking anyone to merge.
brew audit --strict --online "$OWNER/tap/llcpp"
brew reinstall --build-from-source "$OWNER/tap/llcpp"
brew test "$OWNER/tap/llcpp"

git push -u origin "llcpp-$VER"
gh pr create --repo "$OWNER/homebrew-tap" --base main --head "llcpp-$VER" \
  --title "llcpp $VER" \
  --body "Points the formula at v$VER.

Audited, built from source and tested locally before opening."

echo
echo "llcpp $VER tagged and pushed. Merge the tap PR above, then users get it with:"
echo "  brew update && brew upgrade llcpp"
