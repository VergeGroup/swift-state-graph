#!/usr/bin/env bash
set -euo pipefail

task_project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
task_lock_package="$(mktemp -d "${TMPDIR:-/tmp}/state-graph-lock-tests.XXXXXX")"
trap 'rm -rf "$task_lock_package"' EXIT

# Compile the real primitive and reuse its tests without building the package's
# remaining Apple-only dependencies. This proves only AllocatedLock portability.
mkdir -p "$task_lock_package/Sources/StateGraph" "$task_lock_package/Tests/StateGraphTests"
cp "$task_project_root/Sources/StateGraph/Primitives/AllocatedLock.swift" \
  "$task_lock_package/Sources/StateGraph/AllocatedLock.swift"
cp "$task_project_root/Tests/StateGraphTests/AllocatedLockTests.swift" \
  "$task_lock_package/Tests/StateGraphTests/AllocatedLockTests.swift"

cat > "$task_lock_package/Package.swift" <<'SWIFT'
// swift-tools-version: 6.3
import PackageDescription

let package = Package(
  name: "StateGraphLockTests",
  platforms: [.macOS(.v14)],
  targets: [
    .target(name: "StateGraph"),
    .testTarget(name: "StateGraphTests", dependencies: ["StateGraph"]),
  ],
  swiftLanguageModes: [.v6]
)
SWIFT

CLANG_MODULE_CACHE_PATH="$task_lock_package/.module-cache" \
SWIFT_MODULECACHE_PATH="$task_lock_package/.module-cache" \
swift test --package-path "$task_lock_package" \
  --cache-path "$task_lock_package/.cache" \
  --config-path "$task_lock_package/.config" \
  --security-path "$task_lock_package/.security" \
  -Xswiftc -module-cache-path -Xswiftc "$task_lock_package/.module-cache" "$@"
