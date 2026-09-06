import Foundation
import Observation
import Testing

@testable import StateGraph

@Suite("Graph transactions", .serialized)
struct GraphTransactionTests {

  /// The typed failure used to verify transaction and savepoint rollback.
  private enum TransactionError: Error {
    case rollback
  }

  /// A small synchronized test value for callbacks and concurrent assertions.
  private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
      self.storage = value
    }

    var value: Value {
      lock.lock()
      defer { lock.unlock() }
      return storage
    }

    func update(_ body: (inout Value) -> Void) {
      lock.lock()
      body(&storage)
      lock.unlock()
    }
  }

  /// Runs a supplied action when a staged reference value is destroyed.
  private final class DeinitAction {
    private let action: () -> Void

    init(_ action: @escaping () -> Void = {}) {
      self.action = action
    }

    deinit {
      action()
    }
  }

  /// Observes a transaction context's lifetime without extending it beyond its scope.
  private final class WeakTransactionContext {
    weak var value: GraphTransactionContext?
  }

  @Test
  func transactionContextEqualityUsesIdentity() {
    let context = GraphTransactionContext()
    let alias = context
    let otherContext = GraphTransactionContext()

    #expect(context == alias)
    #expect(context != otherContext)
  }

  @Test
  func commitsMultipleStoredValuesAndReadsStagedMutations() {
    let first = Stored(wrappedValue: 0)
    let second = Stored(wrappedValue: 0)

    withGraphTransaction {
      first.wrappedValue = 1
      second.wrappedValue = 2

      #expect(first.wrappedValue == 1)
      #expect(second.wrappedValue == 2)
    }

    #expect(first.wrappedValue == 1)
    #expect(second.wrappedValue == 2)
  }

  @Test
  func graphStoredRepeatedMutationsUseTheLatestStagedValue() {
    final class Model {
      @GraphStored var values: [Int] = []
    }

    let model = Model()

    withGraphTransaction {
      model.values.append(1)
      model.values.append(2)

      #expect(model.values == [1, 2])
    }

    #expect(model.values == [1, 2])
  }

  @Test
  func outsideReaderSeesCommittedValueAfterNestedTransactionReturns() async {
    let node = Stored(wrappedValue: 0)
    let transactionStarted = TestThreadSignal()
    let resumeTransaction = TestThreadGate()
    let transactionFinished = TestThreadSignal()
    let coordinatorFinished = TestSignal()
    let scenarioResult = OSAllocatedUnfairLock(
      initialState: (
        transactionStarted: false,
        pausedReadValue: Int?.none,
        transactionFinished: false,
        committedValue: Int?.none
      )
    )

    let transactionThread = Thread {
      withGraphTransaction {
        node.wrappedValue = 1
        withGraphTransaction {
          node.wrappedValue = 2
        }
        transactionStarted.signal()
        resumeTransaction.wait(until: Date.distantFuture)
      }
      transactionFinished.signal()
    }
    transactionThread.start()
    defer { resumeTransaction.open() }

    // A dedicated coordinator owns every intermediate synchronous handoff. The async
    // test task only waits for the final TestSignal and never blocks its executor worker.
    Thread {
      defer {
        resumeTransaction.open()
        coordinatorFinished.signal()
      }

      let didStart = transactionStarted.wait(until: Date().addingTimeInterval(20))
      scenarioResult.withLock { $0.transactionStarted = didStart }
      guard didStart else { return }

      let pausedReadValue = node.wrappedValue
      scenarioResult.withLock { $0.pausedReadValue = pausedReadValue }

      resumeTransaction.open()
      let didFinish = transactionFinished.wait(until: Date().addingTimeInterval(20))
      let committedValue = node.wrappedValue
      scenarioResult.withLock {
        $0.transactionFinished = didFinish
        $0.committedValue = committedValue
      }
    }.start()

    #expect(await coordinatorFinished.wait(for: .seconds(30)))
    let result = scenarioResult.withLock { $0 }
    #expect(result.transactionStarted)
    #expect(result.pausedReadValue == 0)
    #expect(result.transactionFinished)
    #expect(result.committedValue == 2)
  }

  @Test
  func outsideWriterWaitsForOuterTransactionAfterNestedTransactionReturns() async {
    let node = Stored(wrappedValue: 0)
    let transactionStarted = TestThreadSignal()
    let resumeTransaction = TestThreadGate()
    let transactionFinished = TestThreadSignal()
    let writerStarted = TestThreadSignal()
    let writerFinished = TestThreadSignal()
    let writerDidFinish = LockedBox(false)
    let coordinatorFinished = TestSignal()
    let scenarioResult = OSAllocatedUnfairLock(
      initialState: (
        transactionStarted: false,
        writerStarted: false,
        didObserveBlockedWriter: false,
        writerRemainedBlockedBeforeRelease: false,
        transactionFinished: false,
        writerFinished: false,
        finalValue: Int?.none
      )
    )

    let transactionThread = Thread {
      withGraphTransaction {
        node.wrappedValue = 1
        withGraphTransaction {
          node.wrappedValue = 2
        }
        transactionStarted.signal()
        resumeTransaction.wait(until: Date.distantFuture)
      }
      transactionFinished.signal()
    }
    transactionThread.start()
    defer { resumeTransaction.open() }

    // Keep the transaction pause, contending writer, and completion handoffs independent
    // of Swift's cooperative executor. Only the final result crosses the async boundary.
    Thread {
      defer {
        resumeTransaction.open()
        coordinatorFinished.signal()
      }

      let transactionDidStart = transactionStarted.wait(until: Date().addingTimeInterval(20))
      scenarioResult.withLock { $0.transactionStarted = transactionDidStart }
      guard transactionDidStart else { return }

      Thread {
        writerStarted.signal()
        node.wrappedValue = 3
        writerDidFinish.update { $0 = true }
        writerFinished.signal()
      }.start()

      let writerDidStart = writerStarted.wait(until: Date().addingTimeInterval(5))
      scenarioResult.withLock { $0.writerStarted = writerDidStart }
      guard writerDidStart else { return }

#if DEBUG
      let didBlock =
        GraphTransactionCoordinator.shared.__testing__waitForImmediateWriterToBlock(
          until: Date().addingTimeInterval(5)
        )
      scenarioResult.withLock { $0.didObserveBlockedWriter = didBlock }
#endif
      scenarioResult.withLock {
        $0.writerRemainedBlockedBeforeRelease = !writerDidFinish.value
      }

      resumeTransaction.open()
      let transactionDidFinish = transactionFinished.wait(until: Date().addingTimeInterval(20))
      let writerDidComplete = writerFinished.wait(until: Date().addingTimeInterval(20))
      let finalValue = node.wrappedValue
      scenarioResult.withLock {
        $0.transactionFinished = transactionDidFinish
        $0.writerFinished = writerDidComplete
        $0.finalValue = finalValue
      }
    }.start()

    #expect(await coordinatorFinished.wait(for: .seconds(30)))
    let result = scenarioResult.withLock { $0 }
    #expect(result.transactionStarted)
    #expect(result.writerStarted)
#if DEBUG
    #expect(result.didObserveBlockedWriter)
#endif
    #expect(result.writerRemainedBlockedBeforeRelease)
    #expect(result.transactionFinished)
    #expect(result.writerFinished)
    #expect(result.finalValue == 3)
  }

  @Test
  func thrownTransactionRollsBackAssignmentsWithoutGraphNotifications() {
    let source = Stored(wrappedValue: 0)
    let derived = Stored(wrappedValue: 0)
    let computed = Computed { _ in
      source.wrappedValue * 2 + derived.wrappedValue
    }
    let didSetCount = LockedBox(0)
    let trackingCallbackCount = LockedBox(0)
    let observationCallbackCount = LockedBox(0)

    source.onDidSet { _, newValue in
      didSetCount.update { $0 += 1 }
      derived.wrappedValue += newValue
    }

    let registration = TrackingRegistration(
      didChange: {
        trackingCallbackCount.update { $0 += 1 }
      },
      isolation: nil
    )
    ThreadLocal.registration.withValue(registration) {
      _ = source.wrappedValue
      _ = derived.wrappedValue
    }

    withObservationTracking {
      _ = source.wrappedValue
      _ = derived.wrappedValue
    } onChange: {
      observationCallbackCount.update { $0 += 1 }
    }

    #expect(computed.wrappedValue == 0)

    var didRollBack = false
    do {
      try withGraphTransaction { () throws(TransactionError) -> Void in
        source.wrappedValue = 1

        #expect(source.wrappedValue == 1)
        #expect(derived.wrappedValue == 1)

        throw .rollback
      }
    } catch {
      didRollBack = true
    }

    #expect(didRollBack)

    #expect(source.wrappedValue == 0)
    #expect(derived.wrappedValue == 0)
    #expect(computed.wrappedValue == 0)
    #expect(didSetCount.value == 1)
    #expect(trackingCallbackCount.value == 0)
    #expect(observationCallbackCount.value == 0)
  }

  @Test
  func rollbackDestroysStagedReferencesAfterReleasingWriterCoordination() {
    let committedValue = DeinitAction()
    let source = Stored(wrappedValue: committedValue)
    let sideEffect = Stored(wrappedValue: 0)

    do {
      try withGraphTransaction { () throws(TransactionError) -> Void in
        source.wrappedValue = DeinitAction {
          sideEffect.wrappedValue = 1
        }
        throw .rollback
      }
    } catch {
      // The staged reference is destroyed during rollback.
    }

    #expect(source.wrappedValue === committedValue)
    #expect(sideEffect.wrappedValue == 1)
  }

  @Test
  func nestedRollbackRestoresEveryParentValueBeforeDestroyingStagedReferences() {
    let committedValue = DeinitAction()
    let parentValue = DeinitAction()
    let source = Stored(wrappedValue: committedValue)
    let second = Stored(wrappedValue: 0)
    let sideEffect = Stored(wrappedValue: 0)
    let cleanupObservedParentSnapshot = LockedBox(false)

    #expect(throws: TransactionError.self) {
      try withGraphTransaction { () throws(TransactionError) -> Void in
        source.wrappedValue = parentValue
        second.wrappedValue = 1

        var didRollBackNestedTransaction = false
        do {
          try withGraphTransaction { () throws(TransactionError) -> Void in
            source.wrappedValue = DeinitAction {
              cleanupObservedParentSnapshot.update {
                $0 = source.wrappedValue === parentValue && second.wrappedValue == 1
              }
              // Cleanup runs after the child scope is detached and joins its parent.
              sideEffect.wrappedValue = 3
            }
            second.wrappedValue = 2
            throw .rollback
          }
        } catch {
          didRollBackNestedTransaction = true
        }

        #expect(didRollBackNestedTransaction)
        #expect(cleanupObservedParentSnapshot.value)
        #expect(source.wrappedValue === parentValue)
        #expect(second.wrappedValue == 1)
        #expect(sideEffect.wrappedValue == 3)
        throw .rollback
      }
    }

    #expect(source.wrappedValue === committedValue)
    #expect(second.wrappedValue == 0)
    #expect(sideEffect.wrappedValue == 0)
  }

  @Test
  func nestedMergeTransfersEveryValueBeforeDestroyingReplacedParentValues() {
    let committedValue = DeinitAction()
    let childValue = DeinitAction()
    let source = Stored(wrappedValue: committedValue)
    let second = Stored(wrappedValue: 0)
    let sideEffect = Stored(wrappedValue: 0)
    let cleanupObservedMergedSnapshot = LockedBox(false)

    #expect(throws: TransactionError.self) {
      try withGraphTransaction { () throws(TransactionError) -> Void in
        source.wrappedValue = DeinitAction {
          cleanupObservedMergedSnapshot.update {
            $0 = source.wrappedValue === childValue && second.wrappedValue == 2
          }
          sideEffect.wrappedValue = 3
        }
        second.wrappedValue = 1

        withGraphTransaction {
          source.wrappedValue = childValue
          second.wrappedValue = 2
          #expect(!cleanupObservedMergedSnapshot.value)
        }

        #expect(cleanupObservedMergedSnapshot.value)
        #expect(source.wrappedValue === childValue)
        #expect(second.wrappedValue == 2)
        #expect(sideEffect.wrappedValue == 3)
        throw .rollback
      }
    }

    #expect(source.wrappedValue === committedValue)
    #expect(second.wrappedValue == 0)
    #expect(sideEffect.wrappedValue == 0)
  }

  @Test
  func overlappingRollbacksKeepEachContextsTypedValuesDistinct() async {
    let first = Stored(wrappedValue: DeinitAction())
    let second = Stored(wrappedValue: DeinitAction())
    let firstCleanupStarted = TestSignal()
    let resumeFirstCleanup = TestThreadGate()
    let outerFinished = TestSignal()
    let innerFinished = TestSignal()
    let outerSecondCleanupCount = LockedBox(0)
    let innerCleanupCount = LockedBox(0)

    Thread {
      do {
        try withGraphTransaction { () throws(TransactionError) -> Void in
          first.wrappedValue = DeinitAction {
            firstCleanupStarted.signal()
            resumeFirstCleanup.wait(
              until: Date().addingTimeInterval(5)
            )
          }
          second.wrappedValue = DeinitAction {
            outerSecondCleanupCount.update { $0 += 1 }
          }
          throw .rollback
        }
      } catch {
        // The staged values are destroyed by rollback cleanup.
      }
      outerFinished.signal()
    }.start()

    #expect(await firstCleanupStarted.wait(for: .seconds(5)))

    Thread {
      do {
        try withGraphTransaction { () throws(TransactionError) -> Void in
          second.wrappedValue = DeinitAction {
            innerCleanupCount.update { $0 += 1 }
          }
          throw .rollback
        }
      } catch {
        // This rollback overlaps the first transaction's deferred cleanup.
      }
      innerFinished.signal()
    }.start()

    #expect(await innerFinished.wait(for: .seconds(5)))
    #expect(innerCleanupCount.value == 1)
    #expect(outerSecondCleanupCount.value == 0)

    resumeFirstCleanup.open()
    #expect(await outerFinished.wait(for: .seconds(5)))
    #expect(outerSecondCleanupCount.value == 1)
  }

  @Test
  func replacingAStagedReferenceDestroysItOutsideTheNodeLock() {
    let replacementFromDeinit = DeinitAction()
    let source = Stored(wrappedValue: DeinitAction())
    let didReenter = LockedBox(false)

    withGraphTransaction {
      source.wrappedValue = DeinitAction { [weak source] in
        didReenter.update { $0 = true }
        source?.wrappedValue = replacementFromDeinit
      }
      source.wrappedValue = DeinitAction()
    }

    #expect(didReenter.value)
    #expect(source.wrappedValue === replacementFromDeinit)
  }

  @Test
  @MainActor
  func transactionRunsOnDidSetDuringBodyAndDefersGraphCallbacksUntilCommit() async {
    let source = Stored(wrappedValue: 0)
    let didSetCount = LockedBox(0)
    let trackingCallbackCount = LockedBox(0)
    let observationCallbackCount = LockedBox(0)
    let trackingDelivered = TestSignal()
    let observationDelivered = TestSignal()

    source.onDidSet { _, _ in
      didSetCount.update { $0 += 1 }
    }

    let registration = TrackingRegistration(
      didChange: {
        trackingCallbackCount.update { $0 += 1 }
        trackingDelivered.signal()
      },
      isolation: nil
    )
    ThreadLocal.registration.withValue(registration) {
      _ = source.wrappedValue
    }

    withObservationTracking {
      _ = source.wrappedValue
    } onChange: {
      observationCallbackCount.update { $0 += 1 }
      observationDelivered.signal()
    }

    withGraphTransaction {
      source.wrappedValue = 1

      #expect(didSetCount.value == 1)
      #expect(trackingCallbackCount.value == 0)
      #expect(observationCallbackCount.value == 0)
    }

    #expect(source.wrappedValue == 1)
    #expect(didSetCount.value == 1)
    #expect(await trackingDelivered.wait(for: .seconds(5)))
    #expect(trackingCallbackCount.value == 1)
    #expect(await observationDelivered.wait(for: .seconds(5)))
    #expect(observationCallbackCount.value == 1)
  }

  @Test
  @MainActor
  func rollbackPreservesExistingObservationAndTrackingRegistrations() async {
    let source = Stored(wrappedValue: 0)
    let trackingCount = LockedBox(0)
    let observationCount = LockedBox(0)
    let trackingDelivered = TestSignal()
    let observationDelivered = TestSignal()

    let registration = TrackingRegistration(
      didChange: {
        trackingCount.update { $0 += 1 }
        trackingDelivered.signal()
      },
      isolation: nil
    )
    ThreadLocal.registration.withValue(registration) {
      _ = source.wrappedValue
    }

    withObservationTracking {
      _ = source.wrappedValue
    } onChange: {
      observationCount.update { $0 += 1 }
      observationDelivered.signal()
    }

    #expect(throws: TransactionError.self) {
      try withGraphTransaction { () throws(TransactionError) -> Void in
        source.wrappedValue = 1
        throw .rollback
      }
    }

    source.wrappedValue = 2

    #expect(await trackingDelivered.wait(for: .seconds(5)))
    #expect(await observationDelivered.wait(for: .seconds(5)))
    #expect(trackingCount.value == 1)
    #expect(observationCount.value == 1)
  }

  @Test
  @MainActor
  func transactionReadsDoNotCreateObservationOrTrackingRegistrations() {
    let source = Stored(wrappedValue: 0)
    let trackingCount = LockedBox(0)
    let observationCount = LockedBox(0)
    let registration = TrackingRegistration(
      didChange: {
        trackingCount.update { $0 += 1 }
      },
      isolation: nil
    )

    ThreadLocal.registration.withValue(registration) {
      withGraphTransaction {
        _ = source.wrappedValue
      }
    }

    withObservationTracking {
      withGraphTransaction {
        _ = source.wrappedValue
      }
    } onChange: {
      observationCount.update { $0 += 1 }
    }

    source.wrappedValue = 1

    #expect(trackingCount.value == 0)
    #expect(observationCount.value == 0)
  }

  @Test
  @MainActor
  func continuousGraphTrackingReregistersAfterTransactionCallbacks() async {
    let source = Stored(wrappedValue: 0)
    let observedValues = LockedBox<[Int]>([])
    let observedOne = TestSignal()
    let observedTwo = TestSignal()
    let cancellable = withGraphTracking {
      withGraphTrackingMap(
        { source.wrappedValue },
        onChange: { value in
          observedValues.update { $0.append(value) }
          if value == 1 {
            observedOne.signal()
          } else if value == 2 {
            observedTwo.signal()
          }
        }
      )
    }
    defer { cancellable.cancel() }

    withGraphTransaction {
      source.wrappedValue = 1
    }

    #expect(await observedOne.wait(for: .seconds(5)))
    source.wrappedValue = 2

    #expect(await observedTwo.wait(for: .seconds(5)))
    #expect(observedValues.value == [0, 1, 2])
  }

  @Test
  func multipleWritesPreserveOnDidSetAssignmentsAndCommitOnlyTheFinalValue() {
    let node = Stored(wrappedValue: 0)
    var didSetValues: [(Int, Int)] = []

    node.onDidSet { oldValue, newValue in
      didSetValues.append((oldValue, newValue))
    }

    withGraphTransaction {
      node.wrappedValue = 1
      node.wrappedValue = 2
      node.wrappedValue = 2
    }

    #expect(node.wrappedValue == 2)
    #expect(didSetValues.count == 3)
    #expect(didSetValues[0].0 == 0)
    #expect(didSetValues[0].1 == 1)
    #expect(didSetValues[1].0 == 1)
    #expect(didSetValues[1].1 == 2)
    #expect(didSetValues[2].0 == 2)
    #expect(didSetValues[2].1 == 2)
  }

  @Test
  func comparatorRunsOnceWithTheCommittedOldValueAndFinalStagedValue() {
    let comparisons = LockedBox<[(Int, Int)]>([])
    let node = Stored(
      wrappedValue: 0,
      shouldNotify: { oldValue, newValue in
        comparisons.update { $0.append((oldValue, newValue)) }
        return oldValue != newValue
      }
    )

    withGraphTransaction {
      node.wrappedValue = 1
      node.wrappedValue = 2
      node.wrappedValue = 3
    }

    #expect(node.wrappedValue == 3)
    #expect(comparisons.value.count == 1)
    #expect(comparisons.value[0].0 == 0)
    #expect(comparisons.value[0].1 == 3)
  }

  @Test
  func comparatorReadsTheWholePendingCommit() {
    let second = Stored(wrappedValue: 0)
    let secondValueSeenByComparator = LockedBox<Int?>(nil)
    let first = Stored(
      wrappedValue: 0,
      shouldNotify: { oldValue, newValue in
        secondValueSeenByComparator.update {
          $0 = second.wrappedValue
        }
        return oldValue != newValue
      }
    )

    withGraphTransaction {
      first.wrappedValue = 1
      second.wrappedValue = 2
    }

    #expect(secondValueSeenByComparator.value == 2)
  }

  @Test
  func comparatorCanWaitForAnotherThreadToReadCommittedGraph() async {
    let unrelated = Stored(wrappedValue: 42)
    let readerFinished = TestThreadGate()
    let transactionFinished = TestSignal()
    let readerCompletedBeforeComparatorReturned = LockedBox(false)
    let node = Stored(
      wrappedValue: 0,
      shouldNotify: { oldValue, newValue in
        Thread {
          _ = unrelated.wrappedValue
          readerFinished.open()
        }.start()

        // Waiting is the behavior under test. The comparator itself runs on the
        // explicitly created transaction thread rather than a test executor.
        readerCompletedBeforeComparatorReturned.update {
          $0 = readerFinished.wait(until: Date().addingTimeInterval(5))
        }
        return oldValue != newValue
      }
    )

    Thread {
      withGraphTransaction {
        node.wrappedValue = 1
      }
      transactionFinished.signal()
    }.start()

    #expect(await transactionFinished.wait(for: .seconds(5)))
    #expect(readerCompletedBeforeComparatorReturned.value)
  }

  @Test
  func stagedOptionalNilIsDifferentFromTheAbsenceOfAStagedValue() {
    let optional = Stored<Int?>(wrappedValue: 1)
    let untouched = Stored<Int?>(wrappedValue: 2)

    withGraphTransaction {
      optional.wrappedValue = nil

      #expect(optional.wrappedValue == nil)
      #expect(untouched.wrappedValue == 2)
    }

    #expect(optional.wrappedValue == nil)
    #expect(untouched.wrappedValue == 2)
  }

  @Test
  func caughtNestedTransactionErrorRestoresTheParentStagedValue() {
    let node = Stored(wrappedValue: 0)

    withGraphTransaction {
      node.wrappedValue = 1

      do {
        try withGraphTransaction { () throws(TransactionError) -> Void in
          node.wrappedValue = 2
          throw .rollback
        }
      } catch TransactionError.rollback {
      } catch {
        Issue.record("Unexpected nested transaction error: \(error)")
      }

      #expect(node.wrappedValue == 1)
    }

    #expect(node.wrappedValue == 1)
  }

  @Test
  @MainActor
  func successfulNestedTransactionDefersPublicationUntilTheOuterCommit() {
    let comparisons = LockedBox<[(Int, Int)]>([])
    let first = Stored(
      wrappedValue: 0,
      shouldNotify: { oldValue, newValue in
        comparisons.update { $0.append((oldValue, newValue)) }
        return oldValue != newValue
      }
    )
    let second = Stored(wrappedValue: 0)
    let notificationCount = LockedBox(0)

    withObservationTracking {
      _ = first.wrappedValue
      _ = second.wrappedValue
    } onChange: {
      notificationCount.update { $0 += 1 }
    }

    withGraphTransaction {
      first.wrappedValue = 1

      let result = withGraphTransaction {
        #expect(first.wrappedValue == 1)
        first.wrappedValue = 2
        second.wrappedValue = 3
        return "merged"
      }

      #expect(result == "merged")
      #expect(first.wrappedValue == 2)
      #expect(second.wrappedValue == 3)
      #expect(comparisons.value.isEmpty)
      #expect(notificationCount.value == 0)
    }

    #expect(first.wrappedValue == 2)
    #expect(second.wrappedValue == 3)
    #expect(notificationCount.value == 1)
    #expect(comparisons.value.count == 1)
    #expect(comparisons.value.first?.0 == 0)
    #expect(comparisons.value.first?.1 == 2)
  }

  @Test
  func successfulNestedTransactionRollsBackWhenTheOuterBodyThrows() {
    let first = Stored(wrappedValue: 0)
    let second = Stored(wrappedValue: 0)

    #expect(throws: TransactionError.self) {
      try withGraphTransaction { () throws(TransactionError) -> Void in
        first.wrappedValue = 1

        withGraphTransaction {
          first.wrappedValue = 2
          second.wrappedValue = 3
        }

        #expect(first.wrappedValue == 2)
        #expect(second.wrappedValue == 3)
        throw .rollback
      }
    }

    #expect(first.wrappedValue == 0)
    #expect(second.wrappedValue == 0)
  }

  @Test
  @MainActor
  func nestedRollbackRestoresOptionalNilAndRemovesItsNewParticipants() {
    let optional = Stored<Int?>(wrappedValue: 1)
    let comparisonCount = LockedBox(0)
    let innerOnly = Stored(
      wrappedValue: 0,
      shouldNotify: { oldValue, newValue in
        comparisonCount.update { $0 += 1 }
        return oldValue != newValue
      }
    )
    let notificationCount = LockedBox(0)

    withObservationTracking {
      _ = innerOnly.wrappedValue
    } onChange: {
      notificationCount.update { $0 += 1 }
    }

    withGraphTransaction {
      optional.wrappedValue = nil

      #expect(throws: TransactionError.self) {
        try withGraphTransaction { () throws(TransactionError) -> Void in
          #expect(optional.wrappedValue == nil)
          optional.wrappedValue = 2
          innerOnly.wrappedValue = 3
          throw .rollback
        }
      }

      #expect(optional.wrappedValue == nil)
      #expect(innerOnly.wrappedValue == 0)
    }

    #expect(optional.wrappedValue == nil)
    #expect(innerOnly.wrappedValue == 0)
    #expect(comparisonCount.value == 0)
    #expect(notificationCount.value == 0)

    // A rolled-back participant must retain its existing observation registration.
    innerOnly.wrappedValue = 4
    #expect(comparisonCount.value == 1)
    #expect(notificationCount.value == 1)
  }

  @Test
  func nestedRollbackDiscardsSuccessfulGrandchildrenAndAllowsAnotherSavepoint() {
    let first = Stored(wrappedValue: 0)
    let second = Stored(wrappedValue: 0)

    withGraphTransaction {
      first.wrappedValue = 1
      second.wrappedValue = 10

      #expect(throws: TransactionError.self) {
        try withGraphTransaction { () throws(TransactionError) -> Void in
          first.wrappedValue = 2

          withGraphTransaction {
            #expect(first.wrappedValue == 2)
            // The middle scope has not staged this node; reads reach the grandparent.
            #expect(second.wrappedValue == 10)
            first.wrappedValue = 3
            second.wrappedValue = 4
          }

          #expect(first.wrappedValue == 3)
          #expect(second.wrappedValue == 4)
          throw .rollback
        }
      }

      #expect(first.wrappedValue == 1)
      #expect(second.wrappedValue == 10)

      withGraphTransaction {
        first.wrappedValue = 5

        #expect(throws: TransactionError.self) {
          try withGraphTransaction { () throws(TransactionError) -> Void in
            #expect(second.wrappedValue == 10)
            second.wrappedValue = 6
            throw .rollback
          }
        }

        #expect(second.wrappedValue == 10)
      }
    }

    #expect(first.wrappedValue == 5)
    #expect(second.wrappedValue == 10)
  }

  /// Rollback decisions ordered from the outermost scope to the innermost scope.
  ///
  /// Two and three scopes cover every outcome combination. Eight scopes cover
  /// all-success, each individual rollback boundary, and all-rollback without
  /// multiplying the same deep traversal into every possible combination.
  private static let nestedTransactionRollbackPatterns: [[Bool]] = {
    var patterns: [[Bool]] = []
    for scopeCount in [2, 3] {
      for mask in 0..<(1 << scopeCount) {
        patterns.append((0..<scopeCount).map { mask & (1 << $0) != 0 })
      }
    }

    let deepScopeCount = 8
    patterns.append(Array(repeating: false, count: deepScopeCount))
    for rollbackIndex in 0..<deepScopeCount {
      var pattern = Array(repeating: false, count: deepScopeCount)
      pattern[rollbackIndex] = true
      patterns.append(pattern)
    }
    patterns.append(Array(repeating: true, count: deepScopeCount))
    return patterns
  }()

  @Test(arguments: nestedTransactionRollbackPatterns)
  @MainActor
  func nestedTransactionOutcomesMatchSnapshotsAtEveryScope(rollsBack: [Bool]) {
    let scopeCount = rollsBack.count
    let contexts = (0..<scopeCount).map { _ in WeakTransactionContext() }
    let initialValues = Array(repeating: 0, count: scopeCount + 1)
    let comparisonCounts = LockedBox(initialValues)
    let notificationCounts = LockedBox(initialValues)
    let computedNotificationCount = LockedBox(0)
    let nodes = initialValues.indices.map { index in
      Stored(
        wrappedValue: 0,
        shouldNotify: { oldValue, newValue in
          comparisonCounts.update { $0[index] += 1 }
          return oldValue != newValue
        }
      )
    }
    let computed = Computed { _ in
      nodes.map { $0.wrappedValue }
    }

    for (index, node) in nodes.enumerated() {
      withObservationTracking {
        _ = node.wrappedValue
      } onChange: {
        notificationCounts.update { $0[index] += 1 }
      }
    }
    withObservationTracking {
      _ = computed.wrappedValue
    } onChange: {
      computedNotificationCount.update { $0 += 1 }
    }

    // A plain value-semantic snapshot is an independent reference for savepoints;
    // it does not inspect the graph's participant lists or node-local undo history.
    var expectedValues = initialValues

    func expectSnapshot() {
      #expect(nodes.map { $0.wrappedValue } == expectedValues)
      #expect(computed.wrappedValue == expectedValues)
    }

    func enterScope(_ level: Int) throws(TransactionError) {
      let precedingValues = expectedValues
      do {
        try withGraphTransaction { () throws(TransactionError) -> Void in
          contexts[level - 1].value = ThreadLocal.graphTransaction.value
          #expect(contexts[level - 1].value != nil)
          expectSnapshot()

          // Every scope overwrites the shared node and introduces its own node.
          // Successful children therefore exercise both replacement and transfer
          // into parents that have never written the scope-specific nodes.
          nodes[0].wrappedValue = level
          nodes[level].wrappedValue = level
          expectedValues[0] = level
          expectedValues[level] = level
          expectSnapshot()

          if level < scopeCount {
            do {
              try enterScope(level + 1)
            } catch {
              #expect(rollsBack[level])
            }
            // Check immediately on return so a parent's later write cannot hide
            // an incorrect merge or a rollback to the wrong ancestor.
            expectSnapshot()
          }

          #expect(comparisonCounts.value == initialValues)
          #expect(notificationCounts.value == initialValues)
          #expect(computedNotificationCount.value == 0)
          if rollsBack[level - 1] {
            throw .rollback
          }
        }
      } catch {
        expectedValues = precedingValues
        expectSnapshot()
        throw error
      }
    }

    var didRollBackOutermostScope = false
    do {
      try enterScope(1)
    } catch {
      didRollBackOutermostScope = true
    }

    #expect(didRollBackOutermostScope == rollsBack[0])
    expectSnapshot()
    for (index, value) in expectedValues.enumerated() {
      if value == 0 {
        #expect(comparisonCounts.value[index] == 0)
        #expect(notificationCounts.value[index] == 0)
      } else {
        #expect(comparisonCounts.value[index] == 1)
        #expect(notificationCounts.value[index] == 1)
      }
    }
    if rollsBack[0] {
      #expect(computedNotificationCount.value == 0)
    } else {
      #expect(computedNotificationCount.value == 1)
    }

    // Live nodes must release the strong contexts in their staging and cleanup storage.
    withExtendedLifetime(nodes) {
      for context in contexts {
        #expect(context.value == nil)
      }
    }
  }

  @Test
  @MainActor
  func uncaughtInnermostErrorRollsBackAllEightScopesWithoutPublication() {
    let scopeCount = 8
    let contexts = (0..<scopeCount).map { _ in WeakTransactionContext() }
    let comparisonCount = LockedBox(0)
    let notificationCount = LockedBox(0)
    let nodes = (0..<scopeCount).map { _ in
      Stored(
        wrappedValue: 0,
        shouldNotify: { oldValue, newValue in
          comparisonCount.update { $0 += 1 }
          return oldValue != newValue
        }
      )
    }
    for node in nodes {
      withObservationTracking {
        _ = node.wrappedValue
      } onChange: {
        notificationCount.update { $0 += 1 }
      }
    }

    func enterScope(_ index: Int) throws(TransactionError) {
      try withGraphTransaction { () throws(TransactionError) -> Void in
        contexts[index].value = ThreadLocal.graphTransaction.value
        #expect(contexts[index].value != nil)
        nodes[index].wrappedValue = index + 1
        if index + 1 < scopeCount {
          try enterScope(index + 1)
        } else {
          throw .rollback
        }
      }
    }

    #expect(throws: TransactionError.self) {
      try enterScope(0)
    }
    #expect(nodes.map { $0.wrappedValue } == Array(repeating: 0, count: scopeCount))
    #expect(comparisonCount.value == 0)
    #expect(notificationCount.value == 0)

    withExtendedLifetime(nodes) {
      for context in contexts {
        #expect(context.value == nil)
      }
    }
  }

  @Test
  func nestedErrorEscapingTheOuterTransactionRollsBackEveryParticipant() {
    let first = Stored(wrappedValue: 0)
    let second = Stored(wrappedValue: 0)
    var didCatchRollback = false

    do {
      try withGraphTransaction { () throws(TransactionError) -> Void in
        first.wrappedValue = 1

        try withGraphTransaction { () throws(TransactionError) -> Void in
          second.wrappedValue = 2
          throw .rollback
        }
      }
    } catch let error {
      switch error {
      case .rollback:
        didCatchRollback = true
      }
    }

    #expect(didCatchRollback)
    #expect(first.wrappedValue == 0)
    #expect(second.wrappedValue == 0)
  }

#if DEBUG
  @Test(arguments: [true, false])
  func legacyNestedTransactionDiagnosticSettingDoesNotChangeSavepointBehavior(
    isEnabled: Bool
  ) {
    let previousValue = StateGraphDiagnostics.isNestedTransactionWarningEnabled
    defer {
      StateGraphDiagnostics.isNestedTransactionWarningEnabled = previousValue
    }

    StateGraphDiagnostics.isNestedTransactionWarningEnabled = isEnabled
    #expect(StateGraphDiagnostics.isNestedTransactionWarningEnabled == isEnabled)
    let node = Stored(wrappedValue: 0)

    withGraphTransaction {
      node.wrappedValue = 1

      #expect(throws: TransactionError.self) {
        try withGraphTransaction { () throws(TransactionError) -> Void in
          node.wrappedValue = 2
          throw .rollback
        }
      }

      #expect(node.wrappedValue == 1)
    }

    #expect(node.wrappedValue == 1)
  }
#endif

  @Test
  func onDidSetReadsTheSequentialTransactionSnapshot() {
    let first = Stored(wrappedValue: 0)
    let second = Stored(wrappedValue: 0)
    var secondValueObservedByFirstCallback: Int?

    first.onDidSet { _, _ in
      secondValueObservedByFirstCallback = second.wrappedValue
    }

    withGraphTransaction {
      first.wrappedValue = 1

      #expect(secondValueObservedByFirstCallback == 0)

      second.wrappedValue = 2
    }

    #expect(secondValueObservedByFirstCallback == 0)
  }

  @Test
  @MainActor
  func firstObservationCallbackReadsTheFinalComputedValue() async {
    let first = Stored(wrappedValue: 0)
    let second = Stored(wrappedValue: 0)
    let total = Computed { _ in
      first.wrappedValue + second.wrappedValue
    }
    let observedTotal = LockedBox<Int?>(nil)
    let callbackDelivered = TestSignal()

    #expect(total.wrappedValue == 0)

    withObservationTracking {
      _ = first.wrappedValue
    } onChange: {
      observedTotal.update { $0 = total.wrappedValue }
      callbackDelivered.signal()
    }

    withGraphTransaction {
      first.wrappedValue = 1
      second.wrappedValue = 2
    }

    #expect(await callbackDelivered.wait(for: .seconds(5)))
    #expect(observedTotal.value == 3)
  }

  @Test
  @MainActor
  func synchronousObservationMutationsDrainFollowingCommitBatches() {
    let first = Stored(wrappedValue: 0)
    let second = Stored(wrappedValue: 0)
    let third = Stored(wrappedValue: 0)
    let firstChangeCount = LockedBox(0)
    let secondChangeCount = LockedBox(0)

    withObservationTracking {
      _ = first.wrappedValue
    } onChange: {
      firstChangeCount.update { $0 += 1 }

      // `first` has not been published yet, but the committing thread reads its
      // pending value and stages this assignment in the following commit batch.
      #expect(first.wrappedValue == 1)
      second.wrappedValue = 2
    }

    withObservationTracking {
      _ = second.wrappedValue
    } onChange: {
      secondChangeCount.update { $0 += 1 }

      // Committing `second` proves that the batch drain must iterate rather than
      // handle only one callback-generated batch.
      #expect(second.wrappedValue == 2)
      third.wrappedValue = 3
    }

    withGraphTransaction {
      first.wrappedValue = 1
    }

    #expect(first.wrappedValue == 1)
    #expect(second.wrappedValue == 2)
    #expect(third.wrappedValue == 3)
    #expect(firstChangeCount.value == 1)
    #expect(secondChangeCount.value == 1)
  }

  @Test
  @MainActor
  func observationCallbackSavepointRestoresThePendingCommitAndFollowingBatch() {
    let first = Stored(wrappedValue: 0)
    let second = Stored(wrappedValue: 0)
    let third = Stored(wrappedValue: 0)
    let fourth = Stored(wrappedValue: 0)
    let secondChangeCount = LockedBox(0)
    let thirdChangeCount = LockedBox(0)
    let contexts = LockedBox(
      (
        parent: WeakTransactionContext(),
        failedChild: WeakTransactionContext(),
        successfulChild: WeakTransactionContext()
      )
    )

    withObservationTracking {
      _ = third.wrappedValue
    } onChange: {
      thirdChangeCount.update { $0 += 1 }
    }

    withObservationTracking {
      _ = second.wrappedValue
    } onChange: {
      secondChangeCount.update { $0 += 1 }
      #expect(second.wrappedValue == 12)
      fourth.wrappedValue = 4
    }

    withObservationTracking {
      _ = first.wrappedValue
    } onChange: {
      contexts.update { $0.parent.value = ThreadLocal.graphTransaction.value }
      #expect(contexts.value.parent.value != nil)
      second.wrappedValue = 10

      #expect(throws: TransactionError.self) {
        try withGraphTransaction { () throws(TransactionError) -> Void in
          contexts.update { $0.failedChild.value = ThreadLocal.graphTransaction.value }
          #expect(contexts.value.failedChild.value != nil)
          first.wrappedValue = 9
          second.wrappedValue = 20
          third.wrappedValue = 30
          throw .rollback
        }
      }

      // Reads fall back to the pending first commit and the parent callback batch.
      #expect(first.wrappedValue == 1)
      #expect(second.wrappedValue == 10)
      #expect(third.wrappedValue == 0)

      withGraphTransaction {
        contexts.update { $0.successfulChild.value = ThreadLocal.graphTransaction.value }
        #expect(contexts.value.successfulChild.value != nil)
        second.wrappedValue = 12
      }

      #expect(second.wrappedValue == 12)
      #expect(secondChangeCount.value == 0)
    }

    withGraphTransaction {
      first.wrappedValue = 1
    }

    #expect(first.wrappedValue == 1)
    #expect(second.wrappedValue == 12)
    #expect(third.wrappedValue == 0)
    #expect(fourth.wrappedValue == 4)
    #expect(secondChangeCount.value == 1)
    #expect(thirdChangeCount.value == 0)

    withExtendedLifetime((first, second, third, fourth)) {
      let capturedContexts = contexts.value
      #expect(capturedContexts.parent.value == nil)
      #expect(capturedContexts.failedChild.value == nil)
      #expect(capturedContexts.successfulChild.value == nil)
    }

    third.wrappedValue = 3
    #expect(thirdChangeCount.value == 1)
  }

  @Test
  @MainActor
  func observationCallbackSavepointPreservesDependencyRegistration() {
    let source = Stored(wrappedValue: 0)
    let second = Stored(wrappedValue: 0)
    let secondChangeCount = LockedBox(0)

    withObservationTracking {
      _ = source.wrappedValue
    } onChange: {
      withGraphTransaction {
        // A child scope must preserve its callback parent's ability to track reads.
        withObservationTracking {
          _ = second.wrappedValue
        } onChange: {
          secondChangeCount.update { $0 += 1 }
        }
      }
    }

    withGraphTransaction {
      source.wrappedValue = 1
    }

    #expect(secondChangeCount.value == 0)
    second.wrappedValue = 2
    #expect(secondChangeCount.value == 1)
  }

  @Test
  @MainActor
  func observationWillSetPrecedesCommittedPublication() {
    let source = Stored(wrappedValue: 0)
    let willSetStarted = TestThreadGate()
    let lateRegistrationFinished = TestThreadGate()
    let lateObservedValue = LockedBox<Int?>(nil)
    let lateChangeCount = LockedBox(0)
    let didCompleteLateRegistration = LockedBox(false)

    Thread {
      guard willSetStarted.wait(until: Date().addingTimeInterval(5)) else {
        lateRegistrationFinished.open()
        return
      }

      withObservationTracking {
        lateObservedValue.update { $0 = source.wrappedValue }
      } onChange: {
        lateChangeCount.update { $0 += 1 }
      }
      lateRegistrationFinished.open()
    }.start()

    withObservationTracking {
      _ = source.wrappedValue
    } onChange: {
      willSetStarted.open()

      // This synchronous gate is the behavior under test: the Observation
      // `willSet` callback must remain active while another OS thread registers
      // against the old committed snapshot.
      didCompleteLateRegistration.update {
        $0 = lateRegistrationFinished.wait(
          until: Date().addingTimeInterval(5)
        )
      }
    }

    withGraphTransaction {
      source.wrappedValue = 1
    }

    #expect(didCompleteLateRegistration.value)
    #expect(lateObservedValue.value == 0)
    #expect(lateChangeCount.value == 0)
    #expect(source.wrappedValue == 1)
  }

  @Test
  @MainActor
  func computedObservationWillSetPrecedesCommittedPublication() {
    let source = Stored(wrappedValue: 0)
    let computed = Computed { _ in source.wrappedValue }
    let willSetStarted = TestThreadGate()
    let lateRegistrationFinished = TestThreadGate()
    let lateObservedValue = LockedBox<Int?>(nil)
    let lateChangeCount = LockedBox(0)
    let didCompleteLateRegistration = LockedBox(false)

    #expect(computed.wrappedValue == 0)

    Thread {
      guard willSetStarted.wait(until: Date().addingTimeInterval(5)) else {
        lateRegistrationFinished.open()
        return
      }

      withObservationTracking {
        lateObservedValue.update { $0 = computed.wrappedValue }
      } onChange: {
        lateChangeCount.update { $0 += 1 }
      }
      lateRegistrationFinished.open()
    }.start()

    withObservationTracking {
      _ = computed.wrappedValue
    } onChange: {
      willSetStarted.open()

      // This synchronous gate is the behavior under test: the Observation
      // `willSet` callback must remain active while another OS thread registers
      // against the old committed snapshot.
      didCompleteLateRegistration.update {
        $0 = lateRegistrationFinished.wait(
          until: Date().addingTimeInterval(5)
        )
      }
    }

    withGraphTransaction {
      source.wrappedValue = 1
    }

    #expect(didCompleteLateRegistration.value)
    #expect(lateObservedValue.value == 0)
    #expect(lateChangeCount.value == 0)
    #expect(computed.wrappedValue == 1)
  }

#if DEBUG
  @Test
  @MainActor
  func observationSnapshotWaitsForAnInFlightComputedRead() async {
    let source = Stored(wrappedValue: 0)
    let descriptorStarted = TestSignal()
    let resumeDescriptor = TestThreadGate()
    let shouldPauseDescriptor = LockedBox(true)
    let initialObservedValue = LockedBox<Int?>(nil)
    let observationChangeCount = LockedBox(0)
    let observerReadFinished = TestSignal()
    let transactionFinished = TestSignal()
    let observationDelivered = TestSignal()

    let computed = Computed { _ in
      var shouldPause = false
      shouldPauseDescriptor.update {
        shouldPause = $0
        $0 = false
      }
      if shouldPause {
        descriptorStarted.signal()
        resumeDescriptor.wait(until: Date().addingTimeInterval(5))
      }
      return source.wrappedValue
    }

    Thread {
      withObservationTracking {
        initialObservedValue.update { $0 = computed.wrappedValue }
      } onChange: {
        observationChangeCount.update { $0 += 1 }
        observationDelivered.signal()
      }
      observerReadFinished.signal()
    }.start()

    #expect(await descriptorStarted.wait(for: .seconds(5)))

    Thread {
      withGraphTransaction {
        source.wrappedValue = 1
      }
      transactionFinished.signal()
    }.start()

    let publisherWaitFinished = TestSignal()
    let didObserveBlockedPublisher = LockedBox(false)
    Thread {
      let didBlock = GraphTransactionCoordinator.shared.__testing__waitForPublisherToBlock(
        until: Date().addingTimeInterval(1)
      )
      didObserveBlockedPublisher.update { $0 = didBlock }
      publisherWaitFinished.signal()
    }.start()

    #expect(await publisherWaitFinished.wait(for: .seconds(5)))
    #expect(didObserveBlockedPublisher.value)

    resumeDescriptor.open()

    #expect(await observerReadFinished.wait(for: .seconds(5)))
    #expect(await transactionFinished.wait(for: .seconds(5)))
    #expect(await observationDelivered.wait(for: .seconds(5)))
    #expect(initialObservedValue.value == 0)
    #expect(observationChangeCount.value == 1)
    #expect(computed.wrappedValue == 1)
  }
#endif

  @Test
  @MainActor
  func observationCallbackCanWaitForAnotherThreadToReadTheCommittedGraph() async {
    let first = Stored(wrappedValue: 0)
    let second = Stored(wrappedValue: 0)
    let callbackReadFinished = TestThreadGate()
    let callbackDidFinishWaiting = LockedBox(false)
    let callbackDelivered = TestSignal()

    withObservationTracking {
      _ = first.wrappedValue
    } onChange: {
      Thread {
        _ = second.wrappedValue
        callbackReadFinished.open()
      }.start()

      // Waiting is the behavior under test: this synchronous Observation
      // callback must be able to wait for an outside committed-graph reader.
      callbackDidFinishWaiting.update {
        $0 = callbackReadFinished.wait(
          until: Date().addingTimeInterval(5)
        )
      }
      callbackDelivered.signal()
    }

    withGraphTransaction {
      first.wrappedValue = 1
      second.wrappedValue = 2
    }

    #expect(await callbackDelivered.wait(for: .seconds(5)))
    #expect(callbackDidFinishWaiting.value)
  }

  @Test
  func computedReadsUseStagedDependenciesWithoutLeakingCommittedCacheOrEdges() {
    let toggle = Stored(wrappedValue: false)
    let first = Stored(wrappedValue: 1)
    let second = Stored(wrappedValue: 2)
    let computeCount = LockedBox(0)
    let selected = Computed { _ in
      computeCount.update { $0 += 1 }
      if toggle.wrappedValue {
        return second.wrappedValue
      }
      return first.wrappedValue
    }

    #expect(selected.wrappedValue == 1)
    #expect(computeCount.value == 1)

    var didRollBack = false
    do {
      try withGraphTransaction { () throws(TransactionError) -> Void in
        toggle.wrappedValue = true
        #expect(selected.wrappedValue == 2)
        second.wrappedValue = 3
        #expect(selected.wrappedValue == 3)
        throw .rollback
      }
    } catch {
      didRollBack = true
    }

    #expect(didRollBack)

    #expect(selected.wrappedValue == 1)
    #expect(computeCount.value == 3)

    second.wrappedValue = 4

    #expect(selected.wrappedValue == 1)
    #expect(computeCount.value == 3)

    first.wrappedValue = 5

    #expect(selected.wrappedValue == 5)
    #expect(computeCount.value == 4)
  }

  @Test
  func computedReadsReturnToParentDependenciesAfterNestedRollback() {
    let toggle = Stored(wrappedValue: false)
    let first = Stored(wrappedValue: 1)
    let second = Stored(wrappedValue: 2)
    let computeCount = LockedBox(0)
    let selected = Computed { _ in
      computeCount.update { $0 += 1 }
      if toggle.wrappedValue {
        return second.wrappedValue
      }
      return first.wrappedValue
    }

    #expect(selected.wrappedValue == 1)

    withGraphTransaction {
      first.wrappedValue = 10
      #expect(selected.wrappedValue == 10)

      #expect(throws: TransactionError.self) {
        try withGraphTransaction { () throws(TransactionError) -> Void in
          toggle.wrappedValue = true
          second.wrappedValue = 3
          #expect(selected.wrappedValue == 3)
          throw .rollback
        }
      }

      #expect(selected.wrappedValue == 10)
      #expect(second.wrappedValue == 2)
      first.wrappedValue = 11
    }

    #expect(selected.wrappedValue == 11)
    let countAfterCommit = computeCount.value

    // The failed child must not leave a dependency on the alternate branch.
    second.wrappedValue = 4
    #expect(selected.wrappedValue == 11)
    #expect(computeCount.value == countAfterCommit)

    first.wrappedValue = 12
    #expect(selected.wrappedValue == 12)
    #expect(computeCount.value == countAfterCommit + 1)
  }

  @Test
  func deallocatedNestedParticipantIsSkippedAtMergeAndCommit() {
    weak var weakNode: Stored<Int>?

    withGraphTransaction {
      withGraphTransaction {
        var node: Stored<Int>? = Stored(wrappedValue: 0)
        weakNode = node
        node?.wrappedValue = 1
        node = nil
        #expect(weakNode == nil)
      }

      #expect(weakNode == nil)
    }

    #expect(weakNode == nil)
  }

  @Test
  func callbackTriggeredMutationDoesNotDeadlock() async {
    let first = Stored(wrappedValue: 0)
    let second = Stored(wrappedValue: 0)
    let finished = TestSignal()

    first.onDidSet { _, _ in
      second.wrappedValue = 2
    }

    let thread = Thread {
      withGraphTransaction {
        first.wrappedValue = 1
      }
      finished.signal()
    }
    thread.start()

    #expect(await finished.wait(for: .seconds(5)))
    #expect(first.wrappedValue == 1)
    #expect(second.wrappedValue == 2)
  }

  @Test
  func onDidSetMutationJoinsTheCurrentTransactionInAssignmentOrder() {
    let first = Stored(wrappedValue: 0)
    let second = Stored(wrappedValue: 0)
    let third = Stored(wrappedValue: 0)
    let secondValueReadByFirstCallback = LockedBox<Int?>(nil)
    let secondTransitions = LockedBox<
      [(oldValue: Int, newValue: Int, observedSecond: Int, observedThird: Int)]
    >([])

    first.onDidSet { _, _ in
      second.wrappedValue = 2
      third.wrappedValue = 3
      secondValueReadByFirstCallback.update { $0 = second.wrappedValue }
    }
    second.onDidSet { oldValue, newValue in
      secondTransitions.update {
        $0.append(
          (
            oldValue,
            newValue,
            second.wrappedValue,
            third.wrappedValue
          )
        )
      }
    }

    withGraphTransaction {
      first.wrappedValue = 1

      #expect(second.wrappedValue == 2)
      #expect(third.wrappedValue == 3)

      second.wrappedValue = 1
      third.wrappedValue = 1
    }

    let transitions = secondTransitions.value
    #expect(secondValueReadByFirstCallback.value == 2)
    #expect(second.wrappedValue == 1)
    #expect(third.wrappedValue == 1)
    #expect(transitions.count == 2)
    #expect(transitions[0].oldValue == 0)
    #expect(transitions[0].newValue == 2)
    #expect(transitions[0].observedSecond == 2)
    #expect(transitions[0].observedThird == 0)
    #expect(transitions[1].oldValue == 2)
    #expect(transitions[1].newValue == 1)
    #expect(transitions[1].observedSecond == 1)
    #expect(transitions[1].observedThird == 3)
  }

  @Test
  func concurrentReadersObserveOnlyWholeComputedSnapshots() {
    let first = Stored(wrappedValue: 0)
    let second = Stored(wrappedValue: 0)
    let total = Computed { _ in first.wrappedValue + second.wrappedValue }
    let observedPartialCommit = LockedBox(false)

    DispatchQueue.concurrentPerform(iterations: 200) { index in
      if index.isMultiple(of: 3) {
        withGraphTransaction {
          first.wrappedValue = index
          second.wrappedValue = -index
        }
      } else {
        let value = total.wrappedValue
        if value != 0 {
          observedPartialCommit.update { $0 = true }
        }
      }
    }

    #expect(observedPartialCommit.value == false)
    #expect(total.wrappedValue == 0)
  }

  @Test
  func immediateComparatorDoesNotHoldThePhysicalNodeLock() async {
    let comparatorEntered = TestSignal()
    let releaseComparator = TestThreadGate()
    let writerFinished = TestSignal()
    let readerFinished = TestSignal()
    let readerValue = LockedBox<Int?>(nil)
    let source = Stored(
      wrappedValue: 0,
      shouldNotify: { oldValue, newValue in
        if newValue == 1 {
          comparatorEntered.signal()
          releaseComparator.wait(until: Date().addingTimeInterval(5))
        }
        return oldValue != newValue
      }
    )

    Thread {
      source.wrappedValue = 1
      writerFinished.signal()
    }.start()

    #expect(await comparatorEntered.wait(for: .seconds(5)))

    Thread {
      readerValue.update { $0 = source.wrappedValue }
      readerFinished.signal()
    }.start()

    // The logical writer reservation excludes only another writer. A reader can
    // acquire the physical lock and observe the old value while comparison pauses.
    #expect(await readerFinished.wait(for: .seconds(1)))
    #expect(readerValue.value == 0)

    releaseComparator.open()
    #expect(await writerFinished.wait(for: .seconds(5)))
    #expect(source.wrappedValue == 1)
  }

  @Test
  func sameNodeImmediateWriterWaitsForLogicalReservation() async {
    let firstComparatorEntered = TestSignal()
    let secondComparatorEntered = TestSignal()
    let releaseFirstComparator = TestThreadGate()
    let writersFinished = TestCountdown(count: 2)
    let comparisons = LockedBox<[(oldValue: Int, newValue: Int)]>([])
    let source = Stored(
      wrappedValue: 0,
      shouldNotify: { oldValue, newValue in
        comparisons.update { $0.append((oldValue, newValue)) }
        if newValue == 1 {
          firstComparatorEntered.signal()
          releaseFirstComparator.wait(until: Date().addingTimeInterval(5))
        } else if newValue == 2 {
          secondComparatorEntered.signal()
        }
        return oldValue != newValue
      }
    )

    Thread {
      source.wrappedValue = 1
      writersFinished.signal()
    }.start()
    #expect(await firstComparatorEntered.wait(for: .seconds(5)))

    Thread {
      source.wrappedValue = 2
      writersFinished.signal()
    }.start()

    #expect(await secondComparatorEntered.wait(for: .milliseconds(100)) == false)
    releaseFirstComparator.open()

    #expect(await secondComparatorEntered.wait(for: .seconds(5)))
    #expect(await writersFinished.wait(for: .seconds(5)))
    let recordedComparisons = comparisons.value
    #expect(recordedComparisons.count == 2)
    #expect(recordedComparisons[0].oldValue == 0)
    #expect(recordedComparisons[0].newValue == 1)
    #expect(recordedComparisons[1].oldValue == 1)
    #expect(recordedComparisons[1].newValue == 2)
    #expect(source.wrappedValue == 2)
  }

  @Test
  func differentNodeImmediateWriterProceedsDuringLogicalReservation() async {
    let firstComparatorEntered = TestSignal()
    let releaseFirstComparator = TestThreadGate()
    let firstWriterFinished = TestSignal()
    let secondWriterFinished = TestSignal()
    let first = Stored(
      wrappedValue: 0,
      shouldNotify: { oldValue, newValue in
        firstComparatorEntered.signal()
        releaseFirstComparator.wait(until: Date().addingTimeInterval(5))
        return oldValue != newValue
      }
    )
    let second = Stored(wrappedValue: 0)

    Thread {
      first.wrappedValue = 1
      firstWriterFinished.signal()
    }.start()
    #expect(await firstComparatorEntered.wait(for: .seconds(5)))

    Thread {
      second.wrappedValue = 1
      secondWriterFinished.signal()
    }.start()

    #expect(await secondWriterFinished.wait(for: .seconds(1)))
    #expect(second.wrappedValue == 1)

    releaseFirstComparator.open()
    #expect(await firstWriterFinished.wait(for: .seconds(5)))
    #expect(first.wrappedValue == 1)
  }

  @Test
  func ordinaryOnDidSetCanRunATransactionWithoutDeadlocking() async {
    let source = Stored(wrappedValue: 0)
    let nested = Stored(wrappedValue: 0)
    let finished = TestSignal()

    source.onDidSet { _, _ in
      withGraphTransaction {
        nested.wrappedValue = 1
      }
    }

    let thread = Thread {
      source.wrappedValue = 1
      finished.signal()
    }
    thread.start()

    #expect(await finished.wait(for: .seconds(5)))
    #expect(source.wrappedValue == 1)
    #expect(nested.wrappedValue == 1)
  }

  @Test
  func onDidSetTransactionWaitsForContendingWriterAfterNodeUnlock() async {
    let secondComparatorEntered = TestSignal()
    let releaseSecondComparator = TestThreadGate()
    let firstCallbackEntered = TestSignal()
    let allowFirstCallbackTransaction = TestThreadGate()
    let writersFinished = TestCountdown(count: 2)
    let nested = Stored(wrappedValue: 0)
    let source = Stored(
      wrappedValue: 0,
      shouldNotify: { oldValue, newValue in
        if newValue == 2 {
          secondComparatorEntered.signal()

          // Holding this comparator open is the behavior under test. Its setter
          // runs on an explicitly created OS thread.
          releaseSecondComparator.wait(
            until: Date().addingTimeInterval(5)
          )
        }
        return oldValue != newValue
      }
    )

    source.onDidSet { _, newValue in
      guard newValue == 1 else { return }
      firstCallbackEntered.signal()

      // Holding this callback open lets the second writer enter its comparator
      // before the callback begins its transaction.
      allowFirstCallbackTransaction.wait(
        until: Date().addingTimeInterval(5)
      )
      withGraphTransaction {
        nested.wrappedValue = 1
      }
    }

    Thread {
      source.wrappedValue = 1
      writersFinished.signal()
    }.start()

    #expect(await firstCallbackEntered.wait(for: .seconds(5)))

    Thread {
      source.wrappedValue = 2
      writersFinished.signal()
    }.start()

    #expect(await secondComparatorEntered.wait(for: .seconds(5)))
    allowFirstCallbackTransaction.open()
    releaseSecondComparator.open()

    #expect(await writersFinished.wait(for: .seconds(5)))
    #expect(source.wrappedValue == 2)
    #expect(nested.wrappedValue == 1)
  }

  @Test
  func callbackCanWaitForTransactionQueuedBehindItsCompletedTransaction() async {
    let firstTransactionStarted = TestSignal()
    let releaseFirstTransaction = TestThreadGate()
    let secondTransactionCallStarted = TestSignal()
    let secondTransactionFinished = TestThreadGate()
    let sourceWriterFinished = TestSignal()
    let callbackObservedSecondCompletion = LockedBox(false)
    let source = Stored(wrappedValue: 0)
    let firstTarget = Stored(wrappedValue: 0)
    let secondTarget = Stored(wrappedValue: 0)

    source.onDidSet { _, _ in
      withGraphTransaction {
        firstTransactionStarted.signal()

        // Keep the first transaction active until the competing transaction is
        // deterministically queued behind it.
        releaseFirstTransaction.wait(
          until: Date().addingTimeInterval(5)
        )
        firstTarget.wrappedValue = 1
      }

      // Waiting after the first transaction returns is the behavior under test:
      // the queued transaction must be able to complete while this callback remains
      // on its explicitly created OS thread.
      callbackObservedSecondCompletion.update {
        $0 = secondTransactionFinished.wait(
          until: Date().addingTimeInterval(5)
        )
      }
    }

    Thread {
      source.wrappedValue = 1
      sourceWriterFinished.signal()
    }.start()

    #expect(await firstTransactionStarted.wait(for: .seconds(5)))

    Thread {
      secondTransactionCallStarted.signal()
      withGraphTransaction {
        secondTarget.wrappedValue = 1
      }
      secondTransactionFinished.open()
    }.start()

    #expect(await secondTransactionCallStarted.wait(for: .seconds(5)))
#if DEBUG
    let transactionWaitFinished = TestSignal()
    let didObserveQueuedTransaction = LockedBox(false)
    Thread {
      let didBlock = GraphTransactionCoordinator.shared.__testing__waitForTransactionToBlock(
        until: Date().addingTimeInterval(1)
      )
      didObserveQueuedTransaction.update { $0 = didBlock }
      transactionWaitFinished.signal()
    }.start()
    #expect(await transactionWaitFinished.wait(for: .seconds(5)))
    #expect(didObserveQueuedTransaction.value)
#endif
    releaseFirstTransaction.open()

    #expect(await sourceWriterFinished.wait(for: .seconds(5)))
    #expect(callbackObservedSecondCompletion.value)
    #expect(firstTarget.wrappedValue == 1)
    #expect(secondTarget.wrappedValue == 1)
  }

  @Test
  func concurrentImmediateWriterCallbacksCanBothStartTransactions() async {
    let firstSource = Stored(wrappedValue: 0)
    let secondSource = Stored(wrappedValue: 0)
    let firstNested = Stored(wrappedValue: 0)
    let secondNested = Stored(wrappedValue: 0)
    let callbacksReady = TestCountdown(count: 2)
    let startTransactions = TestThreadGate()
    let writersFinished = TestCountdown(count: 2)

    firstSource.onDidSet { _, _ in
      callbacksReady.signal()

      // Both callbacks must remain active on their OS threads before either one
      // attempts to acquire the transaction writer slot.
      startTransactions.wait(until: Date().addingTimeInterval(5))
      withGraphTransaction {
        firstNested.wrappedValue = 1
      }
    }
    secondSource.onDidSet { _, _ in
      callbacksReady.signal()
      startTransactions.wait(until: Date().addingTimeInterval(5))
      withGraphTransaction {
        secondNested.wrappedValue = 1
      }
    }

    Thread {
      firstSource.wrappedValue = 1
      writersFinished.signal()
    }.start()
    Thread {
      secondSource.wrappedValue = 1
      writersFinished.signal()
    }.start()

    #expect(await callbacksReady.wait(for: .seconds(5)))
    startTransactions.open()

    #expect(await writersFinished.wait(for: .seconds(5)))
    #expect(firstNested.wrappedValue == 1)
    #expect(secondNested.wrappedValue == 1)
  }
}
