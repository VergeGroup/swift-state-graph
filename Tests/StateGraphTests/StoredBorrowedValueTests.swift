import Foundation
import Testing
import os

@testable import StateGraph

@Suite("Stored borrowed value access", .serialized)
struct StoredBorrowedValueTests {

  private enum ProjectionError: Error {
    case rejected
  }

  @Test
  func projectionTracksCommittedDependencies() {
    let source = Stored(wrappedValue: [1: "First"])
    let invocationCount = OSAllocatedUnfairLock(initialState: 0)
    let selectedValue = Computed { _ in
      invocationCount.withLock { $0 += 1 }
      return source.withBorrowedValue { $0[1] }
    }

    #expect(selectedValue.wrappedValue == "First")
    #expect(invocationCount.withLock { $0 } == 1)

    source.wrappedValue[1] = "Second"

    #expect(selectedValue.wrappedValue == "Second")
    #expect(invocationCount.withLock { $0 } == 2)
  }

  @Test
  func projectionReadsTransactionVisibleValue() {
    let source = Stored(wrappedValue: [1: "Committed"])

    withGraphTransaction {
      source.wrappedValue[1] = "Staged"
      #expect(source.withBorrowedValue { $0[1] } == "Staged")
    }

    #expect(source.withBorrowedValue { $0[1] } == "Staged")
  }

  @Test
  func throwingProjectionReleasesTheNodeLock() {
    let source = Stored(wrappedValue: 0)

    #expect(throws: ProjectionError.rejected) {
      try source.withBorrowedValue { _ throws(ProjectionError) -> Int in
        throw .rejected
      }
    }

    source.wrappedValue = 1
    #expect(source.wrappedValue == 1)
  }

  @Test
  func throwingProjectionStillFinishesDeferredReadWork() {
    let source = Stored(wrappedValue: 0)
    let invocationCount = OSAllocatedUnfairLock(initialState: 0)

    #expect(throws: ProjectionError.rejected) {
      try source.withBorrowedValue { _ throws(ProjectionError) -> Int in
        let returnedAction = deferUntilGraphReadCompletes {
          invocationCount.withLock { $0 += 1 }
        }
        #expect(returnedAction == nil)
        throw .rejected
      }
    }

    #expect(invocationCount.withLock { $0 } == 1)
  }

#if DEBUG
  @Test
  func deferredActionRunsAfterNodeLockAndReadAdmissionAreReleased() async {
    let source = Stored(wrappedValue: 0)
    let transactionStaged = TestSignal()
    let resumeTransactionCommit = TestThreadGate()
    let projectionStarted = TestSignal()
    let resumeProjection = TestThreadGate()
    let readerFinished = TestSignal()
    let transactionFinished = TestSignal()
    let publisherCheckFinished = TestSignal()
    let deferredActionFinished = TestSignal()
    let deferredReadFinished = TestThreadGate()

    let transactionGatePassed = OSAllocatedUnfairLock<Bool?>(initialState: nil)
    let projectionGatePassed = OSAllocatedUnfairLock<Bool?>(initialState: nil)
    let didDefer = OSAllocatedUnfairLock<Bool?>(initialState: nil)
    let didObserveBlockedPublisher = OSAllocatedUnfairLock<Bool?>(initialState: nil)
    let deferredWorkerFinished = OSAllocatedUnfairLock<Bool?>(initialState: nil)
    let deferredReadValue = OSAllocatedUnfairLock<Int?>(initialState: nil)
    let shouldPauseProjection = OSAllocatedUnfairLock(initialState: true)
    let computedBox = WeakObjectBox<Computed<Int>>()

    let computed = Computed { _ in
      let value = source.withBorrowedValue { $0 }
      let shouldPause = shouldPauseProjection.withLock { value in
        guard value else { return false }
        value = false
        return true
      }

      if shouldPause {
        let returnedAction = deferUntilGraphReadCompletes {
          Thread {
            deferredReadValue.withLock {
              $0 = computedBox.value?.wrappedValue
            }
            deferredReadFinished.open()
          }.start()

          let didFinish = deferredReadFinished.wait(
            until: Date().addingTimeInterval(5)
          )
          deferredWorkerFinished.withLock { $0 = didFinish }
          deferredActionFinished.signal()
        }
        let wasDeferred = returnedAction == nil
        didDefer.withLock { $0 = wasDeferred }
        projectionStarted.signal()

        let didResume = resumeProjection.wait(
          until: Date().addingTimeInterval(5)
        )
        projectionGatePassed.withLock { $0 = didResume }
      }

      return value
    }
    computedBox.value = computed

    Thread {
      withGraphTransaction {
        source.wrappedValue = 1
        transactionStaged.signal()

        let didResume = resumeTransactionCommit.wait(
          until: Date().addingTimeInterval(5)
        )
        transactionGatePassed.withLock { $0 = didResume }
      }
      transactionFinished.signal()
    }.start()

    #expect(await transactionStaged.wait(for: .seconds(5)))

    Thread {
      _ = computed.wrappedValue
      readerFinished.signal()
    }.start()

    #expect(await projectionStarted.wait(for: .seconds(5)))
    resumeTransactionCommit.open()

    Thread {
      let didBlock = GraphTransactionCoordinator.shared.__testing__waitForPublisherToBlock(
        until: Date().addingTimeInterval(5)
      )
      didObserveBlockedPublisher.withLock { $0 = didBlock }
      publisherCheckFinished.signal()
    }.start()

    #expect(await publisherCheckFinished.wait(for: .seconds(5)))
    #expect(didObserveBlockedPublisher.withLock { $0 } == true)

    resumeProjection.open()

    #expect(await transactionFinished.wait(for: .seconds(5)))
    #expect(await deferredActionFinished.wait(for: .seconds(5)))
    #expect(await readerFinished.wait(for: .seconds(5)))
    #expect(transactionGatePassed.withLock { $0 } == true)
    #expect(projectionGatePassed.withLock { $0 } == true)
    #expect(didDefer.withLock { $0 } == true)
    #expect(deferredWorkerFinished.withLock { $0 } == true)
    // A transaction has separate Observation-willSet and value-publication
    // barriers. The deferred read may enter between them, but must complete with
    // one whole committed snapshot after the original read and node locks unwind.
    #expect(deferredReadValue.withLock { value in
      value == 0 || value == 1
    })
  }
#endif

  @Test
  func unavailableDeferralReturnsTheActionWithoutRunningIt() {
    let didRun = OSAllocatedUnfairLock(initialState: false)

    var returnedAction = deferUntilGraphReadCompletes {
      didRun.withLock { $0 = true }
    }

    #expect(returnedAction != nil)
    #expect(!didRun.withLock { $0 })

    returnedAction?()
    returnedAction = nil

    #expect(didRun.withLock { $0 })
  }

  @Test
  func unavailableDeferralPreservesASoleOwnedNonSendableCapture() {
    let deinitCount = OSAllocatedUnfairLock(initialState: 0)

    var returnedAction = deferUntilGraphReadCompletes({
      let probe = NonSendableDeinitProbe {
        deinitCount.withLock { $0 += 1 }
      }
      return { _ = probe }
    }())

    #expect(returnedAction != nil)
    #expect(deinitCount.withLock { $0 } == 0)

    returnedAction?()
    #expect(deinitCount.withLock { $0 } == 0)

    returnedAction = nil
    #expect(deinitCount.withLock { $0 } == 1)
  }

  @Test
  func transactionDeferralTransfersCaptureBeyondTheBorrowedNodeLock() {
    let source = Stored(wrappedValue: 0)
    let deinitCount = OSAllocatedUnfairLock(initialState: 0)
    let valueReadFromDeinit = OSAllocatedUnfairLock<Int?>(initialState: nil)
    var returnedAction: (() -> Void)?

    withGraphTransaction {
      source.wrappedValue = 1
      returnedAction = source.withBorrowedValue { _ in
        deferUntilGraphReadCompletes({
          let probe = NonSendableDeinitProbe {
            valueReadFromDeinit.withLock {
              $0 = source.wrappedValue
            }
            deinitCount.withLock { $0 += 1 }
          }
          return { _ = probe }
        }())
      }

      #expect(returnedAction != nil)
      #expect(deinitCount.withLock { $0 } == 0)
    }

    #expect(source.wrappedValue == 1)
    #expect(deinitCount.withLock { $0 } == 0)

    returnedAction?()
    returnedAction = nil

    #expect(deinitCount.withLock { $0 } == 1)
    #expect(valueReadFromDeinit.withLock { $0 } == 1)
  }
}

private final class TestThreadGate: @unchecked Sendable {

  private let condition = NSCondition()
  private var isOpen = false

  func open() {
    condition.lock()
    isOpen = true
    condition.broadcast()
    condition.unlock()
  }

  func wait(until deadline: Date) -> Bool {
    condition.lock()
    defer { condition.unlock() }

    while !isOpen {
      guard condition.wait(until: deadline) else {
        return isOpen
      }
    }

    return true
  }
}

private final class NonSendableDeinitProbe {

  private let onDeinit: () -> Void

  init(onDeinit: @escaping () -> Void) {
    self.onDeinit = onDeinit
  }

  deinit {
    onDeinit()
  }
}

private final class WeakObjectBox<Value: AnyObject & Sendable>: @unchecked Sendable {

  private let lock = OSAllocatedUnfairLock<Void>()
  nonisolated(unsafe) private weak var storedValue: Value?

  var value: Value? {
    get {
      lock.withLock { storedValue }
    }
    set {
      lock.withLock { storedValue = newValue }
    }
  }
}
