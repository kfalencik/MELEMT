#!/bin/zsh
# Builds, signs, notarizes and publishes a MELEMT release, and adds it to the Sparkle appcast.
#
#   scripts/release.sh 1.1 [notes.md]
#
# Needs (one-time setup, see README "Releasing"):
#   - "Developer ID Application" certificate in the login keychain
#   - notarytool credentials saved as the "MELEMT" keychain profile
#   - the MELEMT Sparkle private key in the login keychain (generate_keys --account MELEMT)
#   - gh signed in with push access to the repo
#   - MEMT/Helper/LEModHelper built (Helper/fetch-sources.sh, then Helper/build-helper.sh)
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version> [notes.md]}"
NOTES_FILE="${2:-}"
TAG="v$VERSION"

ROOT="${0:A:h:h}"
BUILD="$ROOT/build"
REPO="kfalencik/MELEMT"
TEAM_ID="37KPZYVX63"
IDENTITY="Developer ID Application: Kevin Falencik ($TEAM_ID)"
NOTARY_PROFILE="MELEMT"
SPARKLE_ACCOUNT="MELEMT"
MIN_SYSTEM_VERSION="26.0"

cd "$ROOT"

[[ -f MEMT/Helper/LEModHelper ]] || { echo "MEMT/Helper/LEModHelper is missing. Run Helper/fetch-sources.sh and Helper/build-helper.sh first."; exit 1; }
[[ -z "$(git status --porcelain -- MEMT MEMT.xcodeproj)" ]] || { echo "Commit your app changes before releasing."; exit 1; }
git rev-parse "$TAG" >/dev/null 2>&1 && { echo "Tag $TAG already exists."; exit 1; }

# Sparkle compares CFBundleVersion, so it must always go up: use the commit count on main.
BUILD_NUMBER=$(git rev-list --count HEAD)

echo "==> Building MELEMT $VERSION ($BUILD_NUMBER)"
rm -rf "$BUILD"
xcodebuild -project MEMT.xcodeproj -scheme MEMT -configuration Release \
    -derivedDataPath "$BUILD/DerivedData" -destination "generic/platform=macOS" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM_ID" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    clean build | grep -E "error:|warning: .*signing|BUILD (SUCCEEDED|FAILED)" || true
APP="$BUILD/DerivedData/Build/Products/Release/MELEMT.app"
[[ -d "$APP" ]] || { echo "Build failed."; exit 1; }

echo "==> Signing (inside out)"
sign() { codesign --force --timestamp --options runtime --sign "$IDENTITY" "$@"; }
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$SPARKLE/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
sign "$SPARKLE/Autoupdate"
sign "$SPARKLE/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign --entitlements "$ROOT/scripts/LEModHelper.entitlements" "$APP/Contents/Resources/LEModHelper"
sign --preserve-metadata=entitlements,requirements,flags "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Notarizing"
ditto -c -k --keepParent "$APP" "$BUILD/notarize.zip"
xcrun notarytool submit "$BUILD/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"

ZIP_NAME="MELEMT-$VERSION.zip"
ZIP="$BUILD/$ZIP_NAME"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "==> Updating appcast.xml"
SPARKLE_BIN=$(ls -d "$BUILD"/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin)
SIGNATURE_ATTRS=$("$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" "$ZIP")
python3 "$ROOT/scripts/add_appcast_item.py" "$ROOT/appcast.xml" \
    --version "$BUILD_NUMBER" --short-version "$VERSION" --min-system "$MIN_SYSTEM_VERSION" \
    --url "https://github.com/$REPO/releases/download/$TAG/$ZIP_NAME" \
    --signature-attrs "$SIGNATURE_ATTRS" \
    --release-page "https://github.com/$REPO/releases/tag/$TAG" \
    ${NOTES_FILE:+--notes "$NOTES_FILE"}

echo "==> Publishing $TAG"
git tag "$TAG"
git push origin HEAD "$TAG"
if [[ -n "$NOTES_FILE" ]]; then
    NOTES_ARGS=(--notes-file "$NOTES_FILE")
else
    NOTES_ARGS=(--generate-notes)
fi
gh release create "$TAG" "$ZIP" --repo "$REPO" --title "MELEMT $VERSION" "${NOTES_ARGS[@]}"
# The appcast goes live last, once the download it points to exists.
git add appcast.xml
git commit -m "Release $VERSION"
git push origin HEAD

echo "==> Done: https://github.com/$REPO/releases/tag/$TAG"
