import Dispatch
import Foundation
import StateGraph
import Testing

@Suite("AllocatedLock Tests")
struct AllocatedLockTests {

  /// Copying a handle preserves the identity of its protected state.
  @Test
  func copiedHandlesShareState() {
    let original = AllocatedLock(initialState: 1)
    let copy = original

    copy.withLock { $0 += 1 }

    #expect(original.withLock { $0 } == 2)

    original.withLock { $0 += 1 }

    #expect(copy.withLock { $0 } == 3)
  }

  /// Concurrent accesses through copied handles cannot lose state mutations.
  @Test
  func concurrentAccessIsMutuallyExclusive() {
    let lock = AllocatedLock(initialState: 0)
    let iterationCount = 1_024

    DispatchQueue.concurrentPerform(iterations: iterationCount) { _ in
      let copy = lock
      copy.withLock { $0 += 1 }
    }

    #expect(lock.withLock { $0 } == iterationCount)
  }

  /// Raw operations protect caller-owned state while copied handles contend.
  @Test
  func concurrentManualAccessIsMutuallyExclusive() async {
    let lock = AllocatedLock<Void>()
    let state = AllocatedLockTestRawState()
    let workers = DispatchGroup()
    let workerCount = 4
    let iterationsPerWorker = 1_024

    for _ in 0..<workerCount {
      workers.enter()
      DispatchQueue.global().async {
        let copy = lock
        defer { workers.leave() }

        for _ in 0..<iterationsPerWorker {
          copy.lock()
          state.count += 1
          copy.unlock()
        }
      }
    }

    // A broken raw lock must fail with a timeout rather than hang the test task.
    let finished = await withCheckedContinuation { continuation in
      let completion = AllocatedLockTestCompletion(continuation)
      workers.notify(queue: .global()) {
        completion.resume(returning: true)
      }
      DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(5)) {
        completion.resume(returning: false)
      }
    }
    #expect(finished)
    guard finished else { return }

    #expect(lock.withLock { state.count } == workerCount * iterationsPerWorker)
  }

  /// All scoped APIs unlock after a throw; mutations are not rolled back.
  @Test(arguments: [false, true], [false, true])
  func throwingBodyReleasesLock(
    usesUncheckedAccess: Bool,
    usesConditionalAcquisition: Bool
  ) {
    let lock = AllocatedLock(initialState: 0)

    #expect(throws: AllocatedLockTestError.self) {
      if usesConditionalAcquisition && usesUncheckedAccess {
        _ = try lock.withLockIfAvailableUnchecked { state -> Void in
          state = 1
          throw AllocatedLockTestError.expected
        }
      } else if usesConditionalAcquisition {
        _ = try lock.withLockIfAvailable { state -> Void in
          state = 1
          throw AllocatedLockTestError.expected
        }
      } else if usesUncheckedAccess {
        try lock.withLockUnchecked { state -> Void in
          state = 1
          throw AllocatedLockTestError.expected
        }
      } else {
        try lock.withLock { state -> Void in
          state = 1
          throw AllocatedLockTestError.expected
        }
      }
    }

    // Nonblocking acquisition reports a missing unlock without hanging the test.
    #expect(lock.withLockIfAvailable { $0 } == 1)
  }

  /// Manual and scoped access use the same physical lock across copied handles.
  @Test
  func manualAndScopedLockingShareIdentity() {
    let original = AllocatedLock<Void>()
    let copy = original

    original.lock()
    let enteredWhileManuallyLocked = copy.lockIfAvailable()
    if enteredWhileManuallyLocked {
      copy.unlock()
    }
    original.unlock()

    #expect(enteredWhileManuallyLocked == false)

    let enteredWhileScopedLocked = original.withLock {
      copy.lockIfAvailable()
    }
    if enteredWhileScopedLocked {
      copy.unlock()
    }

    #expect(enteredWhileScopedLocked == false)

    let enteredAfterUnlock = copy.lockIfAvailable()
    #expect(enteredAfterUnlock)
    if enteredAfterUnlock {
      copy.unlock()
    }
  }

  /// A conditional acquisition skips its body when busy and runs it after unlock.
  @Test(arguments: [false, true])
  func conditionalAcquisitionSkipsBusyBody(usesUncheckedAccess: Bool) {
    let lock = AllocatedLock(initialState: 0)

    let declinedResult: Int? = lock.withLock { _ in
      if usesUncheckedAccess {
        return lock.withLockIfAvailableUnchecked { state in
          state += 100
          return state
        }
      } else {
        return lock.withLockIfAvailable { state in
          state += 100
          return state
        }
      }
    }

    #expect(declinedResult == nil)
    #expect(lock.withLock { $0 } == 0)

    let acquiredResult: Int?
    if usesUncheckedAccess {
      acquiredResult = lock.withLockIfAvailableUnchecked { state in
        state += 1
        return state
      }
    } else {
      acquiredResult = lock.withLockIfAvailable { state in
        state += 1
        return state
      }
    }

    #expect(acquiredResult == 1)
    #expect(lock.withLock { $0 } == 1)
  }

  /// Protected state lives until the final handle releases the shared allocation.
  @Test
  func stateIsDestroyedWhenLastHandleIsReleased() {
    var resource: AllocatedLockTestResource? = AllocatedLockTestResource()
    weak let weakResource = resource
    var original: AllocatedLock<AllocatedLockTestResource>? = AllocatedLock(
      initialState: resource!
    )
    var copy = original
    resource = nil
    original = nil

    // Keep the remaining handle alive through the weak-reference check.
    withExtendedLifetime(copy) {
      #expect(weakResource != nil)
    }

    copy = nil

    #expect(weakResource == nil)
  }

  /// A caller can move a resource out of state and let its deinit reenter after unlock.
  @Test
  func extractedResourceCanReenterAfterUnlock() {
    let lock = AllocatedLock<AllocatedLockTestDeinitResource?>(initialState: nil)
    let didReenter = AllocatedLock(initialState: false)

    lock.withLock { state in
      state = AllocatedLockTestDeinitResource {
        let acquiredResult = lock.withLockIfAvailable { $0 == nil }
        didReenter.withLock { $0 = acquiredResult == true }
      }
    }

    // Removing the resource also breaks its capture of the shared lock handle.
    var extracted = lock.withLock { state in
      defer { state = nil }
      return state
    }
    #expect(extracted != nil)

    extracted = nil

    #expect(didReenter.withLock { $0 })
  }

  /// An unchecked initializer can exclusively own mutable, non-Sendable state.
  @Test
  func uncheckedStateSupportsSynchronizedNonSendableValue() {
    // The initial reference is owned only by the lock; all mutable access is synchronized.
    let lock = AllocatedLock(uncheckedState: AllocatedLockTestMutableState())
    let iterationCount = 1_024

    DispatchQueue.concurrentPerform(iterations: iterationCount) { _ in
      lock.withLockUnchecked { $0.count += 1 }
    }

    #expect(lock.withLock { $0.count } == iterationCount)
  }

  /// Unchecked access permits a non-Sendable result without claiming it is safe to share.
  @Test
  func uncheckedAccessCanReturnNonSendableValue() {
    let lock = AllocatedLock(uncheckedState: AllocatedLockTestMutableState())
    let state = lock.withLockUnchecked { $0 }

    // This alias is inspected only synchronously; it does not escape to concurrent work.
    state.count = 1

    #expect(lock.withLock { $0.count } == 1)
  }
}

/// The single error used to check scoped unlock without conflating it with rollback.
private enum AllocatedLockTestError: Error {
  case expected
}

/// An immutable reference whose destruction exposes the lifetime of shared lock storage.
private final class AllocatedLockTestResource: Sendable {}

/// Owns an immutable deinit action so final release can exercise callback reentry.
private final class AllocatedLockTestDeinitResource: Sendable {
  private let onDeinit: @Sendable () -> Void

  init(_ onDeinit: @escaping @Sendable () -> Void) {
    self.onDeinit = onDeinit
  }

  deinit {
    onDeinit()
  }
}

/// State owned by the raw-API test; every access uses its external shared lock.
private final class AllocatedLockTestRawState: @unchecked Sendable {
  var count = 0
}

/// Resolves the completion/timeout race once without blocking the test's executor.
///
/// NSLock keeps this test fixture independent of the primitive being verified.
private final class AllocatedLockTestCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Bool, Never>?

  init(_ continuation: CheckedContinuation<Bool, Never>) {
    self.continuation = continuation
  }

  func resume(returning result: Bool) {
    lock.lock()
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()

    continuation?.resume(returning: result)
  }
}

/// Deliberately lacks Sendable conformance so tests exercise the unchecked state contract.
private final class AllocatedLockTestMutableState {
  var count = 0
}
