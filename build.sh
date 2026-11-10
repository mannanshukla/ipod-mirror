#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p 'build/iPod Mirror.app/Contents/MacOS'
swiftc -swift-version 5 -O -import-objc-header Sources/Bridge.h Sources/Transport.swift Sources/RFB.swift Sources/App.swift -o 'build/iPod Mirror.app/Contents/MacOS/iPodMirror' -framework AppKit
cp Info.plist 'build/iPod Mirror.app/Contents/Info.plist'
codesign --force --sign - 'build/iPod Mirror.app'
echo 'Built build/iPod Mirror.app'
