#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
test_build_dir=$(mktemp -d /tmp/ornithopter-tests.XXXXXX)
trap 'rm -rf "$test_build_dir"' EXIT
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export CLANG_MODULE_CACHE_PATH="$test_build_dir/clang-cache"
export SWIFT_MODULECACHE_PATH="$test_build_dir/swift-cache"
xcrun swiftc -swift-version 5 -default-isolation MainActor -parse-as-library \
    Ornithopter/Models/ServerProfile.swift \
    Ornithopter/Services/SSHCommandBuilder.swift \
    Ornithopter/Services/SSHPasswordSupport.swift \
    Ornithopter/Services/ProcessPipeWriter.swift \
    Ornithopter/Services/ProcessOutputCollector.swift \
    Ornithopter/Services/FilePermissionPreflight.swift \
    Ornithopter/Services/TerminalInputRouting.swift \
    Tests/RegressionTests.swift -o "$test_build_dir/regressions"
"$test_build_dir/regressions" | tee "$test_build_dir/result.txt"
/usr/bin/grep -q '^PASS: [0-9][0-9]* regression checks$' "$test_build_dir/result.txt"
