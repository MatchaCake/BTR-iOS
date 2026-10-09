#!/usr/bin/env bash
# Builds BTR-iOS.dylib (arm64, iOS 14+) with the plain Xcode clang toolchain. No Theos needed.
set -euo pipefail
cd "$(dirname "$0")"

OUT=build
MIN_IOS=${MIN_IOS:-14.0}
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
mkdir -p "$OUT"

xcrun --sdk iphoneos clang \
  -target "arm64-apple-ios${MIN_IOS}" -isysroot "$SDK" \
  -dynamiclib -fobjc-arc -fmodules -O2 -g0 -fvisibility=hidden \
  -Wall -Wextra -Wno-unused-parameter -Werror=incompatible-pointer-types -Werror=objc-method-access \
  -install_name "@rpath/BTR-iOS.dylib" \
  -framework Foundation -framework Security -framework UIKit -lz \
  src/BTRCore.m src/BTRRewriter.m src/BTRProxy.m src/BTRHooks.m src/BTRModelHooks.m src/BTRUI.m src/BTRTweak.m \
  -o "$OUT/BTR-iOS.dylib"

# Ad-hoc signature so the Mach-O is valid; LiveContainer re-signs tweaks with its own
# certificate before launch.
codesign -f -s - "$OUT/BTR-iOS.dylib" >/dev/null 2>&1 || echo "warning: codesign failed (LiveContainer will sign it anyway)"

file "$OUT/BTR-iOS.dylib"
otool -L "$OUT/BTR-iOS.dylib"
shasum -a 256 "$OUT/BTR-iOS.dylib"
