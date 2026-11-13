import Dispatch
import Foundation
import os.lock

#if EXTERNAL_LOCK_MODULE
import StateGraphLock
#endif

/// An elapsed batch and its observable result, used to check that work was retained.
private struct Measurement: Codable {
  let nanoseconds: UInt64
  let checksum: UInt64
}

/// One comparison using the same workload, thread count, and iteration count.
private struct Scenario {
  let name: String
  let operations: Int
  let workers: Int
  let original: () -> Measurement
  let portable: () -> Measurement
}

/// A mutable counter whose accesses are protected by the manual lock being measured.
private final class ManualCounter: @unchecked Sendable {
  var value: UInt64 = 0
}

/// Raw paired samples and summary statistics; contention reports throughput per operation.
private struct Comparison: Codable {
  let scenario: String
  let operations: Int
  let workers: Int
  let original: [Measurement]
  let portable: [Measurement]
  let originalMedianNanosecondsPerOperation: Double
  let portableMedianNanosecondsPerOperation: Double
  let originalMADNanosecondsPerOperation: Double
  let portableMADNanosecondsPerOperation: Double
  let medianRatio: Double
}

/// The complete run receipt. This benchmark compares Apple backends only.
private struct Report: Codable {
  let moduleBoundary: String
  let operatingSystem: String
  let processorCount: Int
  let repetitions: Int
  let comparisons: [Comparison]
}

/// Measures optimized batches rather than timing each acquisition separately.
@main
private enum LockBenchmark {

  static func measure(_ body: () -> UInt64) -> Measurement {
    let start = DispatchTime.now().uptimeNanoseconds
    let checksum = body()
    return Measurement(
      nanoseconds: DispatchTime.now().uptimeNanoseconds - start,
      checksum: checksum
    )
  }

  /// Returning retained handles prevents promotion into this function's stack.
  @inline(never)
  static func makeOriginalLocks(count: Int) -> [OSAllocatedUnfairLock<UInt64>] {
    (0..<count).map { OSAllocatedUnfairLock(initialState: UInt64($0)) }
  }

  /// Uses the same escaping lifetime as the original-lock allocation batch.
  @inline(never)
  static func makePortableLocks(count: Int) -> [AllocatedLock<UInt64>] {
    (0..<count).map { AllocatedLock(initialState: UInt64($0)) }
  }

  static func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    let middle = sorted.count / 2
    return sorted.count.isMultiple(of: 2)
      ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
  }

  /// Creates dedicated workers before timing, then measures their shared workload.
  /// Start and completion synchronization is included once per batch, not per operation.
  static func measureContended(
    workers: Int, body: @escaping @Sendable () -> Void
  ) -> UInt64 {
    let ready = DispatchSemaphore(value: 0)
    let start = DispatchSemaphore(value: 0)
    let finished = DispatchGroup()
    for _ in 0..<workers {
      finished.enter()
      Thread.detachNewThread {
        ready.signal()
        start.wait()
        body()
        finished.leave()
      }
    }
    for _ in 0..<workers { ready.wait() }
    let began = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<workers { start.signal() }
    finished.wait()
    return DispatchTime.now().uptimeNanoseconds - began
  }

  static func compare(_ scenario: Scenario, repetitions: Int) -> Comparison {
    // Warm both implementations and the dispatch worker pool before sampling.
    let warmOriginal = scenario.original()
    let warmPortable = scenario.portable()
    let expectedChecksum: UInt64 = scenario.name.hasPrefix("lifecycle.")
      ? UInt64(scenario.operations * (scenario.operations - 1) / 2)
      : UInt64(scenario.operations)
    precondition(warmOriginal.checksum == expectedChecksum)
    precondition(warmPortable.checksum == expectedChecksum)
    var original: [Measurement] = []
    var portable: [Measurement] = []
    for index in 0..<repetitions {
      // Alternate order to reduce temperature and scheduler drift between pairs.
      let old: Measurement
      let new: Measurement
      if index.isMultiple(of: 2) {
        old = scenario.original()
        new = scenario.portable()
      } else {
        new = scenario.portable()
        old = scenario.original()
      }
      precondition(old.checksum == warmOriginal.checksum)
      precondition(new.checksum == warmOriginal.checksum)
      original.append(old)
      portable.append(new)
    }
    let oldCosts = original.map { Double($0.nanoseconds) / Double(scenario.operations) }
    let newCosts = portable.map { Double($0.nanoseconds) / Double(scenario.operations) }
    let oldMedian = median(oldCosts)
    let newMedian = median(newCosts)
    return Comparison(
      scenario: scenario.name, operations: scenario.operations, workers: scenario.workers,
      original: original, portable: portable,
      originalMedianNanosecondsPerOperation: oldMedian,
      portableMedianNanosecondsPerOperation: newMedian,
      originalMADNanosecondsPerOperation: median(oldCosts.map { abs($0 - oldMedian) }),
      portableMADNanosecondsPerOperation: median(newCosts.map { abs($0 - newMedian) }),
      medianRatio: newMedian / oldMedian
    )
  }

  static func main() throws {
    try run()
  }

  /// Avoids inheriting the executable entry point's MainActor into measured closures.
  nonisolated static func run() throws {
    let iterations = Int(CommandLine.arguments.dropFirst().first ?? "2000000")!
    let repetitions = Int(CommandLine.arguments.dropFirst(2).first ?? "11")!
    precondition(iterations >= 8 && repetitions >= 3)
    var scenarios: [Scenario] = [
      Scenario(name: "state.withLock", operations: iterations, workers: 1,
        original: {
          let lock = OSAllocatedUnfairLock(initialState: UInt64(0))
          return measure {
            for _ in 0..<iterations { lock.withLock { $0 &+= 1 } }
            return lock.withLock { $0 }
          }
        }, portable: {
          let lock = AllocatedLock(initialState: UInt64(0))
          return measure {
            for _ in 0..<iterations { lock.withLock { $0 &+= 1 } }
            return lock.withLock { $0 }
          }
        }),
      Scenario(name: "state.withLockUnchecked", operations: iterations, workers: 1,
        original: {
          let lock = OSAllocatedUnfairLock(initialState: UInt64(0))
          return measure {
            for _ in 0..<iterations { lock.withLockUnchecked { $0 &+= 1 } }
            return lock.withLockUnchecked { $0 }
          }
        }, portable: {
          let lock = AllocatedLock(initialState: UInt64(0))
          return measure {
            for _ in 0..<iterations { lock.withLockUnchecked { $0 &+= 1 } }
            return lock.withLockUnchecked { $0 }
          }
        }),
      Scenario(name: "void.withLockUnchecked", operations: iterations, workers: 1,
        original: {
          let lock = OSAllocatedUnfairLock<Void>()
          return measure {
            var value: UInt64 = 0
            for _ in 0..<iterations { lock.withLockUnchecked { value &+= 1 } }
            return value
          }
        }, portable: {
          let lock = AllocatedLock<Void>()
          return measure {
            var value: UInt64 = 0
            for _ in 0..<iterations { lock.withLockUnchecked { value &+= 1 } }
            return value
          }
        }),
      Scenario(name: "manual.lockUnlock", operations: iterations, workers: 1,
        original: {
          let lock = OSAllocatedUnfairLock<Void>()
          return measure {
            var value: UInt64 = 0
            for _ in 0..<iterations { lock.lock(); value &+= 1; lock.unlock() }
            return value
          }
        }, portable: {
          let lock = AllocatedLock<Void>()
          return measure {
            var value: UInt64 = 0
            for _ in 0..<iterations { lock.lock(); value &+= 1; lock.unlock() }
            return value
          }
        }),
      Scenario(name: "manual.tryLockUnlock", operations: iterations, workers: 1,
        original: {
          let lock = OSAllocatedUnfairLock<Void>()
          return measure {
            var value: UInt64 = 0
            for _ in 0..<iterations {
              precondition(lock.lockIfAvailable())
              value &+= 1
              lock.unlock()
            }
            return value
          }
        }, portable: {
          let lock = AllocatedLock<Void>()
          return measure {
            var value: UInt64 = 0
            for _ in 0..<iterations {
              precondition(lock.lockIfAvailable())
              value &+= 1
              lock.unlock()
            }
            return value
          }
        }),
      Scenario(name: "lifecycle.createUseDestroy", operations: iterations / 4, workers: 1,
        original: {
          measure {
            var checksum: UInt64 = 0
            for index in 0..<(iterations / 4) {
              let lock = OSAllocatedUnfairLock(initialState: UInt64(index))
              checksum &+= lock.withLock { $0 }
            }
            return checksum
          }
        }, portable: {
          measure {
            var checksum: UInt64 = 0
            for index in 0..<(iterations / 4) {
              let lock = AllocatedLock(initialState: UInt64(index))
              checksum &+= lock.withLock { $0 }
            }
            return checksum
          }
        }),
      Scenario(name: "lifecycle.retainedBatch", operations: iterations / 4, workers: 1,
        original: {
          measure {
            let locks = makeOriginalLocks(count: iterations / 4)
            var checksum: UInt64 = 0
            for lock in locks { checksum &+= lock.withLock { $0 } }
            return checksum
          }
        }, portable: {
          measure {
            let locks = makePortableLocks(count: iterations / 4)
            var checksum: UInt64 = 0
            for lock in locks { checksum &+= lock.withLock { $0 } }
            return checksum
          }
        }),
    ]
    for workers in [2, 4, 8] {
      let perWorker = iterations / workers
      let operations = perWorker * workers
      scenarios.append(Scenario(name: "contended.state.withLock", operations: operations,
        workers: workers, original: {
          let lock = OSAllocatedUnfairLock(initialState: UInt64(0))
          let elapsed = measureContended(workers: workers) {
            for _ in 0..<perWorker { lock.withLock { $0 &+= 1 } }
          }
          return Measurement(nanoseconds: elapsed, checksum: lock.withLock { $0 })
        }, portable: {
          let lock = AllocatedLock(initialState: UInt64(0))
          let elapsed = measureContended(workers: workers) {
            for _ in 0..<perWorker { lock.withLock { $0 &+= 1 } }
          }
          return Measurement(nanoseconds: elapsed, checksum: lock.withLock { $0 })
        }))
      scenarios.append(Scenario(name: "contended.manual.lockUnlock", operations: operations,
        workers: workers, original: {
          let lock = OSAllocatedUnfairLock<Void>()
          let counter = ManualCounter()
          let elapsed = measureContended(workers: workers) {
            for _ in 0..<perWorker {
              lock.lock(); counter.value &+= 1; lock.unlock()
            }
          }
          return Measurement(nanoseconds: elapsed, checksum: counter.value)
        }, portable: {
          let lock = AllocatedLock<Void>()
          let counter = ManualCounter()
          let elapsed = measureContended(workers: workers) {
            for _ in 0..<perWorker {
              lock.lock(); counter.value &+= 1; lock.unlock()
            }
          }
          return Measurement(nanoseconds: elapsed, checksum: counter.value)
        }))
    }
    #if EXTERNAL_LOCK_MODULE
    let boundary = "external-dynamic-module"
    #else
    let boundary = "same-module"
    #endif
    let report = Report(moduleBoundary: boundary,
      operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
      processorCount: ProcessInfo.processInfo.processorCount,
      repetitions: repetitions,
      comparisons: scenarios.map { compare($0, repetitions: repetitions) })
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(report), as: UTF8.self))
  }
}
