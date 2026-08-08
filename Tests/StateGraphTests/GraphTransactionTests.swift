import Foundation
import Observation
import Testing

@testable import StateGraph

@Suite("Graph transactions", .serialized)
struct GraphTransactionTests {

  /// The typed failure used to verify outer transaction rollback.
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

  /// A one-shot gate for deliberately pausing synchronous graph work on an OS thread.
  ///
  /// Use this only when a synchronous transaction body, comparator, or callback must
  /// remain active while another thread reaches a deterministic state. Async test
  /// control flow must use `TestSignal` or `TestCountdown` so it suspends instead of
  /// blocking a cooperative-executor thread.
  private final class TestThreadGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpen = false

    /// Releases every current or future waiter.
    func open() {
      condition.lock()
      isOpen = true
      condition.broadcast()
      condition.unlock()
    }

    /// Blocks the current OS thread until the gate opens or the deadline expires.
    @discardableResult
    func wait(until deadline: Date) -> Bool {
      condition.lock()
      defer { condition.unlock() }

      while !isOpen {
        guard condition.wait(until: deadline) else { return isOpen }
      }
      return true
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
  func outsideReaderSeesCommittedValueWhileTransactionBodyIsPaused() async {
    let node = Stored(wrappedValue: 0)
    let transactionStarted = TestSignal()
    let resumeTransaction = TestThreadGate()
    let transactionFinished = TestSignal()

    let thread = Thread {
      withGraphTransaction {
        node.wrappedValue = 1
        transactionStarted.signal()
        resumeTransaction.wait(until: Date().addingTimeInterval(5))
      }
      transactionFinished.signal()
    }
    thread.start()

    #expect(await transactionStarted.wait(for: .seconds(5)))
    #expect(node.wrappedValue == 0)

    resumeTransaction.open()
    #expect(await transactionFinished.wait(for: .seconds(5)))
    #expect(node.wrappedValue == 1)
  }

  @Test
  func outsideWriterWaitsForTransactionCompletion() async {
    let node = Stored(wrappedValue: 0)
    let transactionStarted = TestSignal()
    let resumeTransaction = TestThreadGate()
    let transactionFinished = TestSignal()
    let writerStarted = TestSignal()
    let writerFinished = TestSignal()
    let writerDidFinish = LockedBox(false)

    let transactionThread = Thread {
      withGraphTransaction {
        node.wrappedValue = 1
        transactionStarted.signal()
        resumeTransaction.wait(until: Date().addingTimeInterval(5))
      }
      transactionFinished.signal()
    }
    transactionThread.start()

    #expect(await transactionStarted.wait(for: .seconds(5)))

    Thread {
      writerStarted.signal()
      node.wrappedValue = 2
      writerDidFinish.update { $0 = true }
      writerFinished.signal()
    }.start()

    #expect(await writerStarted.wait(for: .seconds(5)))
#if DEBUG
    let writerBlocked = TestSignal()
    let didObserveBlockedWriter = LockedBox(false)
    Thread {
      let didBlock = GraphTransactionCoordinator.shared.__testing__waitForImmediateWriterToBlock(
        until: Date().addingTimeInterval(1)
      )
      didObserveBlockedWriter.update { $0 = didBlock }
      writerBlocked.signal()
    }.start()
    #expect(await writerBlocked.wait(for: .seconds(5)))
    #expect(didObserveBlockedWriter.value)
#endif
    #expect(!writerDidFinish.value)

    resumeTransaction.open()
    #expect(await transactionFinished.wait(for: .seconds(5)))
    #expect(await writerFinished.wait(for: .seconds(5)))
    #expect(node.wrappedValue == 2)
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
  func nestedTransactionHasNoSavepointAndCaughtErrorKeepsItsStagedValue() {
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

      #expect(node.wrappedValue == 2)
    }

    #expect(node.wrappedValue == 2)
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
  @Test
  func nestedTransactionDiagnosticCanBeDisabled() {
    let previousValue = StateGraphDiagnostics.isNestedTransactionWarningEnabled
    defer {
      StateGraphDiagnostics.isNestedTransactionWarningEnabled = previousValue
    }

    let warningCount = LockedBox(0)

    Log.$nestedTransactionWarningObserver.withValue({
      warningCount.update { $0 += 1 }
    }) {
      StateGraphDiagnostics.isNestedTransactionWarningEnabled = true
      withGraphTransaction {
        withGraphTransaction {}
      }

      StateGraphDiagnostics.isNestedTransactionWarningEnabled = false
      withGraphTransaction {
        withGraphTransaction {}
      }
    }

    #expect(warningCount.value == 1)
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
  func deallocatedParticipantIsSkippedAtCommit() {
    weak var weakNode: Stored<Int>?

    withGraphTransaction {
      var node: Stored<Int>? = Stored(wrappedValue: 0)
      weakNode = node
      node?.wrappedValue = 1
      node = nil
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
