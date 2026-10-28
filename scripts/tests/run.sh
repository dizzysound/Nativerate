#!/bin/bash
# Pure-logic tests: compiles the listed app sources with each test and runs it. No Xcode project needed.
set -e
cd "$(dirname "$0")"
out=$(mktemp -d)
xcrun swiftc -o "$out/source_inference" ../../Nativerate/SourceInference.swift source_inference/main.swift
"$out/source_inference"
xcrun swiftc -o "$out/stall_policy" ../../Nativerate/StallPolicy.swift stall_policy/main.swift
"$out/stall_policy"
xcrun swiftc -o "$out/engine_slot" ../../Nativerate/EngineSlot.swift engine_slot/main.swift
"$out/engine_slot"
xcrun swiftc -o "$out/osascript_runner" ../../Nativerate/OsascriptRunner.swift osascript_runner/main.swift
"$out/osascript_runner"
