#!/bin/bash
# WABridge.xcframework (whatsmeow for CMFX) with gomobile: iOS arm64 only, stripped. Needs Go (go.mod's version)
# and gomobile/gobind at go.mod's golang.org/x/mobile; the Build iOS workflow installs both.
set -euo pipefail
cd "$(dirname "$0")"
X=$(go list -m -f '{{.Version}}' golang.org/x/mobile)
command -v gomobile >/dev/null || go install "golang.org/x/mobile/cmd/gomobile@$X" "golang.org/x/mobile/cmd/gobind@$X"
export PATH="$(go env GOPATH)/bin:$PATH"
rm -rf WABridge.xcframework
gomobile bind -target ios/arm64 -iosversion 17.0 -ldflags "-s -w" -trimpath -o WABridge.xcframework .
du -sh WABridge.xcframework
