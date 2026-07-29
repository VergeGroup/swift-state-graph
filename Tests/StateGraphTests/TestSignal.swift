import Foundation
import os

/// A one-shot test signal that resumes asynchronous waiters from synchronous callbacks.
///
/// Unlike `DispatchSemaphore.wait()`, waiting on this type suspends the test task instead of
/// blocking a cooperative-executor thread. This keeps synchronization-heavy tests from
/// starving unrelated tests when Swift Testing runs suites in parallel.
final class TestSignal: @unchecked Sendable {

  private struct State {
    var isSignaled = false
    var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  /// Marks the signal as completed and resumes every current or future waiter.
  func signal() {
    let waiters = state.withLock { state in
      guard !state.isSignaled else { return [CheckedContinuation<Bool, Never>]() }

      state.isSignaled = true
      let waiters = Array(state.waiters.values)
      state.waiters.removeAll()
      return waiters
    }

    waiters.forEach { $0.resume(returning: true) }
  }

  /// Suspends until the signal is completed or the timeout expires.
  ///
  /// - Parameter timeout: The maximum duration to wait.
  /// - Returns: `true` when signaled, or `false` when the timeout expires first.
  func wait(for timeout: Duration) async -> Bool {
    let id = UUID()

    return await withCheckedContinuation { continuation in
      let isAlreadySignaled = state.withLock { state in
        guard !state.isSignaled else { return true }
        state.waiters[id] = continuation
        return false
      }

      guard !isAlreadySignaled else {
        continuation.resume(returning: true)
        return
      }

      Task.detached { [self] in
        try? await Task.sleep(for: timeout)
        timeOutWaiter(id: id)
      }
    }
  }

  private func timeOutWaiter(id: UUID) {
    let waiter = state.withLock { state in
      state.waiters.removeValue(forKey: id)
    }
    waiter?.resume(returning: false)
  }
}

/// An asynchronous countdown used when a test must observe several completions.
///
/// Producers call ``signal()`` from synchronous callbacks or worker threads. The
/// test task awaits ``wait(for:)``, which suspends rather than blocking a
/// cooperative-executor thread.
final class TestCountdown: @unchecked Sendable {

  private let remaining: OSAllocatedUnfairLock<Int>
  private let completion = TestSignal()

  init(count: Int) {
    precondition(count > 0)
    self.remaining = .init(initialState: count)
  }

  /// Decrements the remaining completion count.
  ///
  /// Calls after the countdown reaches zero have no effect.
  func signal() {
    let didFinish = remaining.withLock { remaining in
      guard remaining > 0 else { return false }
      remaining -= 1
      return remaining == 0
    }

    if didFinish {
      completion.signal()
    }
  }

  /// Suspends until every producer signals or the timeout expires.
  func wait(for timeout: Duration) async -> Bool {
    await completion.wait(for: timeout)
  }
}
