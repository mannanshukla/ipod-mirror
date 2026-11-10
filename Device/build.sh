#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
SDK="${IPOD_SDK:?Set IPOD_SDK to your iPhoneOS4.3.sdk directory}"
mkdir -p ../build/device
clang -target armv7-apple-ios4.3 -isysroot "$SDK" -marm -O2 -dynamiclib AudioTap.c -framework AudioToolbox -o ../build/device/iPodMirrorAudio.dylib
ldid -S ../build/device/iPodMirrorAudio.dylib
clang -target armv7-apple-ios4.3 -isysroot "$SDK" -marm -O2 ScreenServer.m -framework Foundation -framework UIKit -framework CoreGraphics -o ../build/device/ipod-mirror-screen
ldid -S ../build/device/ipod-mirror-screen
