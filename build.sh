#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p 'build/iPod Mirror.app/Contents/MacOS' 'build/iPod Mirror.app/Contents/Resources'
swiftc -target arm64-apple-macos13.0 -swift-version 5 -O -import-objc-header Sources/Bridge.h Sources/Transport.swift Sources/RFB.swift Sources/Audio.swift Sources/DirectVideo.swift Sources/Glass.swift Sources/App.swift -o 'build/iPod Mirror.app/Contents/MacOS/iPodMirror' -framework AppKit -framework AVFoundation
cp Info.plist 'build/iPod Mirror.app/Contents/Info.plist'
cp Assets/AppIcon.icns Assets/AppIcon.png 'build/iPod Mirror.app/Contents/Resources/'
codesign --force --sign - 'build/iPod Mirror.app'
echo 'Built build/iPod Mirror.app'
