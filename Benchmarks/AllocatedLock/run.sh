#!/usr/bin/env bash
set -euo pipefail

task_project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
task_output="${1:-$task_project_root/.tmp/allocated-lock-benchmark}"
task_iterations="${2:-2000000}"
task_repetitions="${3:-11}"
mkdir -p "$task_output"
task_output="$(cd "$task_output" && pwd)"
task_lock_source="${ALLOCATED_LOCK_BENCHMARK_SOURCE:-$task_project_root/Sources/StateGraph/Primitives/AllocatedLock.swift}"
task_benchmark_source="$task_project_root/Benchmarks/AllocatedLock/Benchmark.swift"
task_architecture="$(uname -m)"
task_compile_flags=(-O -whole-module-optimization -swift-version 6 -parse-as-library
  -target "$task_architecture-apple-macosx14.0"
  -module-cache-path "$task_output/module-cache")

# The first build allows specialization within one module. The second preserves
# the public boundary of a dynamic library, as StateGraph's products do.
swiftc "${task_compile_flags[@]}" "$task_lock_source" "$task_benchmark_source" \
  -o "$task_output/same-module"
swiftc "${task_compile_flags[@]}" "$task_lock_source" -emit-library -emit-module \
  -module-name StateGraphLock -emit-module-path "$task_output/StateGraphLock.swiftmodule" \
  -Xlinker -install_name -Xlinker @rpath/libStateGraphLock.dylib \
  -o "$task_output/libStateGraphLock.dylib"
swiftc "${task_compile_flags[@]}" -D EXTERNAL_LOCK_MODULE "$task_benchmark_source" \
  -I "$task_output" -L "$task_output" -lStateGraphLock \
  -Xlinker -rpath -Xlinker "$task_output" -o "$task_output/external-module"

swiftc --version > "$task_output/toolchain.txt"
printf '%s\n' "${task_compile_flags[@]}" > "$task_output/build-flags.txt"
if ! sysctl -n machdep.cpu.brand_string > "$task_output/cpu.txt" 2>/dev/null; then
  printf 'CPU model unavailable from sysctl\n' > "$task_output/cpu.txt"
fi
shasum -a 256 "$task_lock_source" "$task_benchmark_source" \
  "$task_project_root/Benchmarks/AllocatedLock/run.sh" > "$task_output/sources.sha256"
if [[ "${ALLOCATED_LOCK_BENCHMARK_BUILD_ONLY:-0}" == 1 ]]; then
  exit 0
fi
"$task_output/same-module" "$task_iterations" "$task_repetitions" > "$task_output/same-module.json"
"$task_output/external-module" "$task_iterations" "$task_repetitions" > "$task_output/external-module.json"
