#!/bin/bash
# HubKit's checks with swiftc alone (no SwiftPM / Xcode): builds one binary and runs it.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)
cat > "$out/main.swift" <<'S'
import Foundation
let bad = try Checks.run(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
print(bad.isEmpty ? "HubKit: all checks pass" : bad.joined(separator: "\n"))
exit(bad.isEmpty ? 0 : 1)
S
sed 's/@testable import HubKit//' Tests/HubKitTests/Checks.swift > "$out/Checks.swift"
swiftc -O -swift-version 6 -o "$out/checks" Sources/HubKit/*.swift "$out/Checks.swift" "$out/main.swift"
"$out/checks" Tests/HubKitTests/vectors.json
