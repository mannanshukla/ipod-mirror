#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
swiftc -swift-version 5 -import-objc-header Sources/Bridge.h Sources/Transport.swift Sources/RFB.swift Tests/ProtocolTests.swift -o build/protocol-tests
build/protocol-tests "$@"
