# AllocatedLock performance comparison

On macOS with the package's Swift toolchain, run:

```sh
bash Benchmarks/AllocatedLock/run.sh
```

Optional arguments select the output directory, iterations per batch, and sample
count. Defaults are `.tmp/allocated-lock-benchmark`, 2,000,000 iterations, and 11
samples. This benchmark compares `AllocatedLock` to `OSAllocatedUnfairLock` on
Apple platforms; it does not measure Linux or Windows backends.

Both executables target macOS 14 and use `-O -whole-module-optimization`. One compiles the real lock
source into the benchmark module. The other builds it as a dynamic library and
compiles a separate client, matching the public boundary of StateGraph's dynamic
products. The compiler's default cross-module optimizations remain enabled.
The entry point delegates to a nonisolated runner so inherited MainActor executor
checks do not contaminate the unchecked-closure comparison.

The cases cover checked and unchecked state access, a Void scope, manual locking,
successful try-lock, two allocation lifetimes, and contention with 2/4/8 dedicated
threads. The short `createUseDestroy` lifetime allows compiler stack promotion.
The `retainedBatch` case returns an array of handles from a non-inlined function
to require allocations that survive the creating function; it includes array
management, one locked read per handle, and destruction.

Each case warms both implementations before sampling. Sample order alternates,
and checksums are verified against the expected workload. Contended threads are
created before timing and use a shared start gate. Start/completion synchronization
is included once per batch. Reported contended ns/op is amortized throughput,
not the latency of an individual blocked acquisition.

JSON output retains every batch, median ns/op, median absolute deviation, and
the new/original median ratio. Toolchain, CPU metadata when available, and source
hashes are saved alongside it. Run on an otherwise idle machine and compare
several runs before interpreting small differences. Performance results are
separate from the functional and Thread Sanitizer tests; timing is not asserted
in the unit suite.

For compile-only preparation, set `ALLOCATED_LOCK_BENCHMARK_BUILD_ONLY=1`.
`ALLOCATED_LOCK_BENCHMARK_SOURCE` can select a saved lock implementation while
keeping the same benchmark source and flags for a before/after comparison.
