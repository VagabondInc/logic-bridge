#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
root="$(pwd -P)"
derived="$root/.build/installer-xcode"
mkdir -p "$root/.build"
stage="$(mktemp -d "$root/.build/installer.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

app_identity="${LOGIC_BRIDGE_APPLICATION_SIGN_IDENTITY:-}"
installer_identity="${LOGIC_BRIDGE_INSTALLER_SIGN_IDENTITY:-}"
if [[ -n "$app_identity" || -n "$installer_identity" ]]; then
    if [[ "$app_identity" != "Developer ID Application: "* ||
          "$installer_identity" != "Developer ID Installer: "* ]]; then
        echo "Set both Developer ID Application and Developer ID Installer signing identities." >&2
        exit 2
    fi
fi

xcodegen generate
mkdir -p "$derived" "$root/dist"
if ! xcodebuild -project LogicBridge.xcodeproj -scheme LogicBridge -configuration Release \
    -derivedDataPath "$derived" -destination 'generic/platform=macOS' \
    ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    "LOGIC_BRIDGE_DONATION_URL=${LOGIC_BRIDGE_DONATION_URL:-}" build > "$derived/build.log" 2>&1; then
    tail -100 "$derived/build.log" >&2
    exit 1
fi

payload="$stage/payload"
app="$payload/Applications/Logic Bridge.app"
mkdir -p "$payload/Applications"
ditto "$derived/Build/Products/Release/LogicBridge.app" "$app"
extension="$app/Contents/PlugIns/StemGenerator.appex"
demo="$app/Contents/Resources/Demo/Logic Bridge Demo.logicx"

test -s "$demo/Alternatives/000/ProjectData"
test -s "$demo/Media/Audio Files/Afterglow.wav"

lipo "$app/Contents/MacOS/LogicBridge" -verify_arch x86_64 arm64
lipo "$extension/Contents/MacOS/StemGenerator" -verify_arch x86_64 arm64
if [[ -n "$app_identity" ]]; then
    codesign --force --timestamp --options runtime --sign "$app_identity" \
        --entitlements Plugin/StemGenerator.entitlements "$extension"
    codesign --force --timestamp --options runtime --sign "$app_identity" "$app"
fi
codesign --verify --deep --strict "$app"

components="$stage/components.plist"
pkgbuild --analyze --root "$payload" "$components"
root_bundle="$(/usr/libexec/PlistBuddy -c 'Print :0:RootRelativeBundlePath' "$components")"
[[ "$root_bundle" == "Applications/Logic Bridge.app" ]]
/usr/libexec/PlistBuddy -c 'Set :0:BundleIsRelocatable false' "$components"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
pkgbuild --root "$payload" --install-location / --component-plist "$components" \
    --scripts Installer/Scripts --identifier com.local.logicbridge.audio.installer \
    --version "$version" "$stage/LogicBridgeComponent.pkg"

sign=()
suffix="-Local"
if [[ -n "$installer_identity" ]]; then
    sign=(--sign "$installer_identity")
    suffix=""
fi
package="$root/dist/LogicBridge-$version-Universal$suffix.pkg"
productbuild --distribution Installer/Distribution.xml --resources Installer/Resources \
    --package-path "$stage" ${sign[@]+"${sign[@]}"} "$stage/LogicBridge.pkg"
mv "$stage/LogicBridge.pkg" "$package"
echo "Built $package"
