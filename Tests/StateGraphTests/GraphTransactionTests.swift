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
  func outsideReaderSeesCommittedValueWhileTransactionBodyIsPaused() {
    let node = Stored(wrappedValue: 0)
    let transactionStarted = DispatchSemaphore(value: 0)
    let resumeTransaction = DispatchSemaphore(value: 0)
    let transactionFinished = DispatchSemaphore(value: 0)

    let thread = Thread {
      withGraphTransaction {
        node.wrappedValue = 1
        transactionStarted.signal()
        resumeTransaction.wait()
      }
      transactionFinished.signal()
    }
    thread.start()

    #expect(transactionStarted.wait(timeout: .now() + .seconds(1)) == .success)
    #expect(node.wrappedValue == 0)

    resumeTransaction.signal()
    #expect(transactionFinished.wait(timeout: .now() + .seconds(1)) == .success)
    #expect(node.wrappedValue == 1)
  }

  @Test
  func outsideWriterWaitsForTransactionCompletion() {
    let node = Stored(wrappedValue: 0)
    let transactionStarted = DispatchSemaphore(value: 0)
    let resumeTransaction = DispatchSemaphore(value: 0)
    let transactionFinished = DispatchSemaphore(value: 0)
    let writerStarted = DispatchSemaphore(value: 0)
    let writerFinished = DispatchSemaphore(value: 0)

    let transactionThread = Thread {
      withGraphTransaction {
        node.wrappedValue = 1
        transactionStarted.signal()
        resumeTransaction.wait()
      }
      transactionFinished.signal()
    }
    transactionThread.start()

    #expect(transactionStarted.wait(timeout: .now() + .seconds(1)) == .success)

    DispatchQueue.global().async {
      writerStarted.signal()
      node.wrappedValue = 2
      writerFinished.signal()
    }

    #expect(writerStarted.wait(timeout: .now() + .seconds(1)) == .success)
#if DEBUG
    #expect(
      GraphTransactionCoordinator.shared.waitForImmediateWriterToBlock(
        until: Date().addingTimeInterval(1)
      )
    )
#endif
    #expect(writerFinished.wait(timeout: .now()) == .timedOut)

    resumeTransaction.signal()
    #expect(transactionFinished.wait(timeout: .now() + .seconds(1)) == .success)
    #expect(writerFinished.wait(timeout: .now() + .seconds(1)) == .success)
    #expect(node.wrappedValue == 2)
  }

  @Test
  func thrownTransactionRollsBackWithoutNotificationsOrInvalidation() {
    let source = Stored(wrappedValue: 0)
    let computed = Computed { _ in source.wrappedValue * 2 }
    let didSetCount = LockedBox(0)
    let trackingCallbackCount = LockedBox(0)
    let observationCallbackCount = LockedBox(0)

    source.onDidSet { _, _ in
      didSetCount.update { $0 += 1 }
    }

    let registration = TrackingRegistration(
      didChange: {
        trackingCallbackCount.update { $0 += 1 }
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
    }

    #expect(computed.wrappedValue == 0)

    var didRollBack = false
    do {
      try withGraphTransaction { () throws(TransactionError) -> Void in
        source.wrappedValue = 1
        throw .rollback
      }
    } catch {
      didRollBack = true
    }

    #expect(didRollBack)

    #expect(source.wrappedValue == 0)
    #expect(computed.wrappedValue == 0)
    #expect(didSetCount.value == 0)
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
  func overlappingRollbacksKeepEachContextsTypedValuesDistinct() {
    let first = Stored(wrappedValue: DeinitAction())
    let second = Stored(wrappedValue: DeinitAction())
    let firstCleanupStarted = DispatchSemaphore(value: 0)
    let resumeFirstCleanup = DispatchSemaphore(value: 0)
    let outerFinished = DispatchSemaphore(value: 0)
    let innerFinished = DispatchSemaphore(value: 0)
    let outerSecondCleanupCount = LockedBox(0)
    let innerCleanupCount = LockedBox(0)

    Thread {
      do {
        try withGraphTransaction { () throws(TransactionError) -> Void in
          first.wrappedValue = DeinitAction {
            firstCleanupStarted.signal()
            _ = resumeFirstCleanup.wait(
              timeout: .now() + .seconds(2)
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

    #expect(
      firstCleanupStarted.wait(timeout: .now() + .seconds(1)) == .success
    )

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

    #expect(innerFinished.wait(timeout: .now() + .seconds(1)) == .success)
    #expect(innerCleanupCount.value == 1)
    #expect(outerSecondCleanupCount.value == 0)

    resumeFirstCleanup.signal()
    #expect(outerFinished.wait(timeout: .now() + .seconds(1)) == .success)
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
  func commitDefersCallbacksUntilTheTransactionBodyReturns() {
    let source = Stored(wrappedValue: 0)
    let didSetCount = LockedBox(0)
    let trackingCallbackCount = LockedBox(0)
    let observationCallbackCount = LockedBox(0)
    let trackingDelivered = DispatchSemaphore(value: 0)
    let observationDelivered = DispatchSemaphore(value: 0)

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

      #expect(didSetCount.value == 0)
      #expect(trackingCallbackCount.value == 0)
      #expect(observationCallbackCount.value == 0)
    }

    #expect(source.wrappedValue == 1)
    #expect(didSetCount.value == 1)
    #expect(trackingDelivered.wait(timeout: .now() + .seconds(1)) == .success)
    #expect(trackingCallbackCount.value == 1)
    #expect(observationDelivered.wait(timeout: .now() + .seconds(1)) == .success)
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
  func multipleWritesCommitOnlyTheFinalValueWithTheExistingComparator() {
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
    #expect(didSetValues.count == 1)
    #expect(didSetValues[0].0 == 0)
    #expect(didSetValues[0].1 == 2)
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
  func comparatorCanWaitForAnotherThreadToReadCommittedGraph() {
    let unrelated = Stored(wrappedValue: 42)
    let readerFinished = DispatchSemaphore(value: 0)
    let readerCompletedBeforeComparatorReturned = LockedBox(false)
    let node = Stored(
      wrappedValue: 0,
      shouldNotify: { oldValue, newValue in
        DispatchQueue.global().async {
          _ = unrelated.wrappedValue
          readerFinished.signal()
        }
        readerCompletedBeforeComparatorReturned.update {
          $0 = readerFinished.wait(timeout: .now() + .seconds(1)) == .success
        }
        return oldValue != newValue
      }
    )

    withGraphTransaction {
      node.wrappedValue = 1
    }

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
  func firstSynchronousCallbackSeesEveryFinalCommittedValue() {
    let first = Stored(wrappedValue: 0)
    let second = Stored(wrappedValue: 0)
    var secondValueObservedByFirstCallback: Int?

    first.onDidSet { _, _ in
      secondValueObservedByFirstCallback = second.wrappedValue
    }

    withGraphTransaction {
      first.wrappedValue = 1
      second.wrappedValue = 2
    }

    #expect(secondValueObservedByFirstCallback == 2)
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
  func observationWillSetPrecedesCommittedPublication() {
    let source = Stored(wrappedValue: 0)
    let willSetStarted = DispatchSemaphore(value: 0)
    let lateRegistrationFinished = DispatchSemaphore(value: 0)
    let lateObservedValue = LockedBox<Int?>(nil)
    let lateChangeCount = LockedBox(0)
    let didCompleteLateRegistration = LockedBox(false)

    DispatchQueue.global().async {
      guard willSetStarted.wait(timeout: .now() + .seconds(1)) == .success else {
        lateRegistrationFinished.signal()
        return
      }

      withObservationTracking {
        lateObservedValue.update { $0 = source.wrappedValue }
      } onChange: {
        lateChangeCount.update { $0 += 1 }
      }
      lateRegistrationFinished.signal()
    }

    withObservationTracking {
      _ = source.wrappedValue
    } onChange: {
      willSetStarted.signal()
      didCompleteLateRegistration.update {
        $0 = lateRegistrationFinished.wait(
          timeout: .now() + .seconds(1)
        ) == .success
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
    let willSetStarted = DispatchSemaphore(value: 0)
    let lateRegistrationFinished = DispatchSemaphore(value: 0)
    let lateObservedValue = LockedBox<Int?>(nil)
    let lateChangeCount = LockedBox(0)
    let didCompleteLateRegistration = LockedBox(false)

    #expect(computed.wrappedValue == 0)

    DispatchQueue.global().async {
      guard willSetStarted.wait(timeout: .now() + .seconds(1)) == .success else {
        lateRegistrationFinished.signal()
        return
      }

      withObservationTracking {
        lateObservedValue.update { $0 = computed.wrappedValue }
      } onChange: {
        lateChangeCount.update { $0 += 1 }
      }
      lateRegistrationFinished.signal()
    }

    withObservationTracking {
      _ = computed.wrappedValue
    } onChange: {
      willSetStarted.signal()
      didCompleteLateRegistration.update {
        $0 = lateRegistrationFinished.wait(
          timeout: .now() + .seconds(1)
        ) == .success
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
    let resumeDescriptor = DispatchSemaphore(value: 0)
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
        _ = resumeDescriptor.wait(timeout: .now() + .seconds(2))
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

    #expect(
      GraphTransactionCoordinator.shared.waitForPublisherToBlock(
        until: Date().addingTimeInterval(1)
      )
    )

    resumeDescriptor.signal()

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
    let callbackReadFinished = DispatchSemaphore(value: 0)
    let callbackDidFinishWaiting = LockedBox(false)
    let callbackDelivered = TestSignal()

    withObservationTracking {
      _ = first.wrappedValue
    } onChange: {
      DispatchQueue.global().async {
        _ = second.wrappedValue
        callbackReadFinished.signal()
      }
      callbackDidFinishWaiting.update {
        $0 = callbackReadFinished.wait(
          timeout: .now() + .seconds(1)
        ) == .success
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
  func callbackTriggeredMutationDoesNotDeadlock() {
    let first = Stored(wrappedValue: 0)
    let second = Stored(wrappedValue: 0)
    let finished = DispatchSemaphore(value: 0)

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

    #expect(finished.wait(timeout: .now() + .seconds(1)) == .success)
    #expect(first.wrappedValue == 1)
    #expect(second.wrappedValue == 2)
  }

  @Test
  func callbackMutationUsesOneLatestTransactionSnapshot() {
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
      second.wrappedValue = 1
      third.wrappedValue = 1
    }

    let transitions = secondTransitions.value
    #expect(secondValueReadByFirstCallback.value == 2)
    #expect(second.wrappedValue == 2)
    #expect(transitions.count == 2)
    #expect(transitions[0].oldValue == 0)
    #expect(transitions[0].newValue == 1)
    #expect(transitions[0].observedSecond == 2)
    #expect(transitions[0].observedThird == 3)
    #expect(transitions[1].oldValue == 1)
    #expect(transitions[1].newValue == 2)
    #expect(transitions[1].observedSecond == 2)
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
  func ordinaryOnDidSetCanRunATransactionWithoutDeadlocking() {
    let source = Stored(wrappedValue: 0)
    let nested = Stored(wrappedValue: 0)
    let finished = DispatchSemaphore(value: 0)

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

    #expect(finished.wait(timeout: .now() + .seconds(5)) == .success)
    #expect(source.wrappedValue == 1)
    #expect(nested.wrappedValue == 1)
  }

  @Test
  func onDidSetTransactionWaitsForContendingWriterAfterNodeUnlock() {
    let secondComparatorEntered = DispatchSemaphore(value: 0)
    let releaseSecondComparator = DispatchSemaphore(value: 0)
    let firstCallbackEntered = DispatchSemaphore(value: 0)
    let allowFirstCallbackTransaction = DispatchSemaphore(value: 0)
    let writersFinished = DispatchSemaphore(value: 0)
    let nested = Stored(wrappedValue: 0)
    let source = Stored(
      wrappedValue: 0,
      shouldNotify: { oldValue, newValue in
        if newValue == 2 {
          secondComparatorEntered.signal()
          releaseSecondComparator.wait()
        }
        return oldValue != newValue
      }
    )

    source.onDidSet { _, newValue in
      guard newValue == 1 else { return }
      firstCallbackEntered.signal()
      allowFirstCallbackTransaction.wait()
      withGraphTransaction {
        nested.wrappedValue = 1
      }
    }

    DispatchQueue.global().async {
      source.wrappedValue = 1
      writersFinished.signal()
    }

    #expect(firstCallbackEntered.wait(timeout: .now() + .seconds(1)) == .success)

    DispatchQueue.global().async {
      source.wrappedValue = 2
      writersFinished.signal()
    }

    #expect(secondComparatorEntered.wait(timeout: .now() + .seconds(1)) == .success)
    allowFirstCallbackTransaction.signal()
    releaseSecondComparator.signal()

    #expect(writersFinished.wait(timeout: .now() + .seconds(1)) == .success)
    #expect(writersFinished.wait(timeout: .now() + .seconds(1)) == .success)
    #expect(source.wrappedValue == 2)
    #expect(nested.wrappedValue == 1)
  }

  @Test
  func callbackCanWaitForTransactionQueuedBehindItsCompletedTransaction() {
    let firstTransactionStarted = DispatchSemaphore(value: 0)
    let releaseFirstTransaction = DispatchSemaphore(value: 0)
    let secondTransactionCallStarted = DispatchSemaphore(value: 0)
    let secondTransactionFinished = DispatchSemaphore(value: 0)
    let sourceWriterFinished = DispatchSemaphore(value: 0)
    let callbackObservedSecondCompletion = LockedBox(false)
    let source = Stored(wrappedValue: 0)
    let firstTarget = Stored(wrappedValue: 0)
    let secondTarget = Stored(wrappedValue: 0)

    source.onDidSet { _, _ in
      withGraphTransaction {
        firstTransactionStarted.signal()
        releaseFirstTransaction.wait()
        firstTarget.wrappedValue = 1
      }

      callbackObservedSecondCompletion.update {
        $0 = secondTransactionFinished.wait(
          timeout: .now() + .seconds(1)
        ) == .success
      }
    }

    DispatchQueue.global().async {
      source.wrappedValue = 1
      sourceWriterFinished.signal()
    }

    #expect(firstTransactionStarted.wait(timeout: .now() + .seconds(1)) == .success)

    DispatchQueue.global().async {
      secondTransactionCallStarted.signal()
      withGraphTransaction {
        secondTarget.wrappedValue = 1
      }
      secondTransactionFinished.signal()
    }

    #expect(
      secondTransactionCallStarted.wait(timeout: .now() + .seconds(1)) == .success
    )
#if DEBUG
    #expect(
      GraphTransactionCoordinator.shared.waitForTransactionToBlock(
        until: Date().addingTimeInterval(1)
      )
    )
#endif
    releaseFirstTransaction.signal()

    #expect(sourceWriterFinished.wait(timeout: .now() + .seconds(2)) == .success)
    #expect(callbackObservedSecondCompletion.value)
    #expect(firstTarget.wrappedValue == 1)
    #expect(secondTarget.wrappedValue == 1)
  }

  @Test
  func concurrentImmediateWriterCallbacksCanBothStartTransactions() {
    let firstSource = Stored(wrappedValue: 0)
    let secondSource = Stored(wrappedValue: 0)
    let firstNested = Stored(wrappedValue: 0)
    let secondNested = Stored(wrappedValue: 0)
    let callbacksReady = DispatchSemaphore(value: 0)
    let startTransactions = DispatchSemaphore(value: 0)
    let writersFinished = DispatchSemaphore(value: 0)

    firstSource.onDidSet { _, _ in
      callbacksReady.signal()
      startTransactions.wait()
      withGraphTransaction {
        firstNested.wrappedValue = 1
      }
    }
    secondSource.onDidSet { _, _ in
      callbacksReady.signal()
      startTransactions.wait()
      withGraphTransaction {
        secondNested.wrappedValue = 1
      }
    }

    DispatchQueue.global().async {
      firstSource.wrappedValue = 1
      writersFinished.signal()
    }
    DispatchQueue.global().async {
      secondSource.wrappedValue = 1
      writersFinished.signal()
    }

    #expect(callbacksReady.wait(timeout: .now() + .seconds(1)) == .success)
    #expect(callbacksReady.wait(timeout: .now() + .seconds(1)) == .success)
    startTransactions.signal()
    startTransactions.signal()

    #expect(writersFinished.wait(timeout: .now() + .seconds(1)) == .success)
    #expect(writersFinished.wait(timeout: .now() + .seconds(1)) == .success)
    #expect(firstNested.wrappedValue == 1)
    #expect(secondNested.wrappedValue == 1)
  }
}
