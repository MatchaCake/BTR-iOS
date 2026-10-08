#!/usr/bin/env bash
# iOS Simulator smoke test (needs Xcode with an iOS simulator runtime).
set -euo pipefail
cd "$(dirname "$0")/../.."
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
ARCH=$(uname -m)
APP=build/sim/BTRSim.app
rm -rf build/sim && mkdir -p "$APP"
xcrun --sdk iphonesimulator clang -target "$ARCH-apple-ios14.0-simulator" -isysroot "$SDK" \
  -dynamiclib -fobjc-arc -fmodules -DBTR_TESTING -framework Foundation -framework UIKit -lz \
  src/BTRCore.m src/BTRRewriter.m src/BTRProxy.m src/BTRHooks.m src/BTRModelHooks.m src/BTRUI.m src/BTRTweak.m \
  -install_name @rpath/BTR-iOS.dylib -o "$APP/BTR-iOS.dylib"
xcrun --sdk iphonesimulator clang -target "$ARCH-apple-ios14.0-simulator" -isysroot "$SDK" \
  -fobjc-arc -fmodules -framework Foundation -framework UIKit tests/sim/main.m -o "$APP/BTRSim"
cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>tv.danmaku.bilianime.btrsim</string>
<key>CFBundleExecutable</key><string>BTRSim</string>
<key>CFBundleName</key><string>BTRSim</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSRequiresIPhoneOS</key><true/>
<key>UILaunchScreen</key><dict/>
<key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><false/></dict>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
codesign -f -s - "$APP/BTR-iOS.dylib" "$APP" >/dev/null

PORT=18741
python3 tests/range_server.py $PORT ok >/dev/null 2>&1 & SRV=$!
trap 'kill $SRV 2>/dev/null || true' EXIT

DEV=$(xcrun simctl create BTRSim "iPhone 17" 2>/dev/null || xcrun simctl create BTRSim com.apple.CoreSimulator.SimDeviceType.iPhone-16)
trap 'kill $SRV 2>/dev/null || true; xcrun simctl shutdown $DEV >/dev/null 2>&1 || true; xcrun simctl delete $DEV >/dev/null 2>&1 || true' EXIT
xcrun simctl boot "$DEV"
xcrun simctl bootstatus "$DEV" -b >/dev/null
xcrun simctl install "$DEV" "$APP"
SIMCTL_CHILD_BTR_OPEN_PANEL=1 SIMCTL_CHILD_BTRSIM_PORT=$PORT xcrun simctl launch --console-pty "$DEV" tv.danmaku.bilianime.btrsim > build/sim/console.log 2>&1 &
LAUNCH=$!
sleep 12
xcrun simctl io "$DEV" screenshot build/sim/screenshot.png >/dev/null 2>&1 || true
kill $LAUNCH 2>/dev/null || true
grep -E "BTRSIM|\[BTR\]" build/sim/console.log || true
grep -q "BTRSIM proxy status=206 bytes=7340033" build/sim/console.log && echo "SIMULATOR SMOKE TEST PASSED"
