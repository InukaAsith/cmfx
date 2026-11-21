#!/bin/bash
# CMFX for iOS: an unsigned IPA (dist/CMFX.ipa) that AltStore, SideStore or any signing tool signs with your Apple
# ID when it installs it. Needs Xcode (the Build iOS workflow has it) and XcodeGen (brew install xcodegen).
set -euo pipefail
cd "$(dirname "$0")"
# whatsmeow for the WhatsApp watch app (Go + gomobile); CI builds it in its own step
[ -d WABridge/WABridge.xcframework ] || bash WABridge/build.sh
# the App Loader the Firmware page installs: the newest cmf-watch-sdk release of it
bash fetch-loader.sh
xcodegen generate --quiet
rm -rf build dist
xcodebuild -project CMFX.xcodeproj -scheme CMFX -configuration Release -sdk iphoneos \
  -destination 'generic/platform=iOS' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  ${VERSION:+MARKETING_VERSION=$VERSION} ${BUILD_NUMBER:+CURRENT_PROJECT_VERSION=$BUILD_NUMBER} \
  CMFX_SPOTIFY_CLIENT_ID="${CMFX_SPOTIFY_CLIENT_ID:-}" CMFX_GEMINI_KEY="${CMFX_GEMINI_KEY:-}" \
  CMFX_GOOGLE_CLIENT_ID="${CMFX_GOOGLE_CLIENT_ID:-}" \
  build | (command -v xcbeautify >/dev/null && xcbeautify || cat)
APP=build/Build/Products/Release-iphoneos/CMFX.app
mkdir -p dist/Payload
cp -R "$APP" dist/Payload/
(cd dist && zip -qry CMFX.ipa Payload && rm -rf Payload)
ls -lh dist/CMFX.ipa
