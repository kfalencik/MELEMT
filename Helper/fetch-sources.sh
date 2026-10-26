#!/bin/zsh
# Downloads the upstream sources LEModHelper is built from into Helper/external, at the exact
# versions MELEMT is tested with, and applies the macOS fixes in Helper/patches.
# Run this once after cloning, then Helper/build-helper.sh.
set -euo pipefail

HELPER_DIR="${0:A:h}"
EXTERNAL="$HELPER_DIR/external"

ME3TWEAKSCORE_URL="https://github.com/ME3Tweaks/ME3TweaksCore.git"
ME3TWEAKSCORE_COMMIT="b5f006add38dbaea91dde3f16f45ecbc3b0155a9"
OOZEXTRACT_URL="https://github.com/lvlvllvlvllvlvl/oozextract.git"
OOZEXTRACT_TAG="v0.5.6"

mkdir -p "$EXTERNAL"

echo "==> ME3TweaksCore (with LegendaryExplorerCore)"
if [[ ! -d "$EXTERNAL/ME3TweaksCore/.git" ]]; then
    git clone "$ME3TWEAKSCORE_URL" "$EXTERNAL/ME3TweaksCore"
fi
cd "$EXTERNAL/ME3TweaksCore"
git fetch --quiet origin
git checkout --quiet --force "$ME3TWEAKSCORE_COMMIT"
# Submodules are pinned by ME3TweaksCore itself.
git submodule update --init --recursive --force
git apply "$HELPER_DIR/patches/ME3TweaksCore-macOS.patch"
(cd ME3TweaksCore/submodules/LegendaryExplorer && git apply "$HELPER_DIR/patches/LegendaryExplorerCore-macOS.patch")

echo "==> oozextract $OOZEXTRACT_TAG"
rm -rf "$EXTERNAL/oozextract"
git clone --quiet --depth 1 --branch "$OOZEXTRACT_TAG" "$OOZEXTRACT_URL" "$EXTERNAL/oozextract"

echo "==> Sources ready in $EXTERNAL. Next: Helper/build-helper.sh"
