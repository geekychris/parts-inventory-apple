#!/bin/sh
# Build the Mac app for running on this Mac without a provisioning profile: signed with your Apple Development
# certificate (not ad hoc), with the entitlements that need no profile (no iCloud or push; run it with
# -localStore). A stable signature matters for the Keychain: macOS trusts an item for the app's signature, and an
# ad-hoc one changes with every build, so "Always Allow" would be forgotten each time.
#
#   tools/build-mac.sh            build to build/dd
#   tools/build-mac.sh --run      build, then open it with -localStore
set -e
cd "$(dirname "$0")/.."
IDENTITY=${IDENTITY:-"Apple Development"}
xcodebuild -project PartsInventory.xcodeproj -scheme PartsInventory -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/dd \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM=T2M6R36LYY PROVISIONING_PROFILE_SPECIFIER= \
  CODE_SIGN_ENTITLEMENTS="$PWD/tools/Local.entitlements" build -quiet
APP="build/dd/Build/Products/Debug/e-Parts Inventory Manager.app"
codesign -dv "$APP" 2>&1 | grep -E '^(Authority|TeamIdentifier)=' | head -2
if [ "$1" = "--run" ]; then shift; open -n "$APP" --args -localStore "$@"; fi
