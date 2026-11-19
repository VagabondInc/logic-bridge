#!/usr/bin/env bash
set -euo pipefail

mode="${1:-run}"
case "$mode" in
  run|--verify|--build-only|--debug|--logs|--telemetry) ;;
  *) echo "Usage: $0 [--verify|--build-only|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac
cd "$(dirname "$0")/.."
root="$(pwd -P)"
derived="$root/.build/xcode"
bundle="$root/dist/LogicBridgeAudioUnit.app"
plugin="$bundle/Contents/PlugIns/StemGenerator.appex"
plugin_id="com.local.logicbridge.audio.stemgenerator"

xcodegen generate
install -d "$derived" "$root/dist"
if ! xcodebuild -project LogicBridge.xcodeproj -scheme LogicBridge \
    -configuration Debug -derivedDataPath "$derived" \
    -destination "platform=macOS,arch=$(uname -m)" build > "$derived/build.log" 2>&1; then
  tail -100 "$derived/build.log" >&2
  exit 1
fi
/usr/bin/ditto "$derived/Build/Products/Debug/LogicBridge.app" "$bundle"
/usr/bin/codesign --verify --deep --strict "$bundle"
if [[ "$mode" == --build-only ]]; then
  echo "Built $bundle"
  exit 0
fi

lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$lsregister" -f "$bundle"
/usr/bin/pluginkit -a "$plugin"
/usr/bin/pluginkit -m -i "$plugin_id"
/usr/bin/auval -v aufx StmG LbAu

case "$mode" in
  --debug) exec lldb ;;
  --logs|--telemetry)
    exec /usr/bin/log stream --style compact --predicate 'process CONTAINS "AUHostingService"'
    ;;
  *)
    echo "Registered Logic Bridge → Stem Generator. Open it from an Audio FX slot in Logic Pro."
    ;;
esac
