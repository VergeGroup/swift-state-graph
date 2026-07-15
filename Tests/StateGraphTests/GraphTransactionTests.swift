import Foundation
import Observation
import os
import Testing

@testable import StateGraph

@Suite("Graph transactions")
struct GraphTransactionTests {

  /// A deterministic failure used to verify rollback and savepoint behavior.
  private enum TestFailure: Error {
    case expected
  }

  /// Reference storage used to verify observers generated for a value type.
  private final class HistoryBox: @unchecked Sendable {
    var values: [(Int, Int)] = []
  }

  /// A custom storage that reports its setter synchronously.
  private final class SynchronouslyNotifyingStorage<Value>: Storage, @unchecked Sendable {
    private var context: StorageContext?

    var value: Value {
      didSet {
        context?.notifyStorageUpdated()
      }
    }

    init(_ value: Value) {
      self.value = value
    }

    func loaded(context: StorageContext) {
      self.context = context
    }

    func unloaded() {}
  }

  private struct StructObserverModel {
    @GraphStored
    var count: Int {
      didSet {
        history.values.append((oldValue, count))
      }
    }

    let history: HistoryBox

    init(history: HistoryBox) {
      self.history = history
      self.count = 0
    }
  }

  private actor ActorObserverModel {
    @GraphStored
    var count: Int = 0 {
      willSet {
        history.append(("will", count, newValue))
      }
      didSet {
        history.append(("did", oldValue, count))
      }
    }

    var history: [(String, Int, Int)] = []

    func commitBatch() {
      withGraphTransaction {
        count = 1
        count = 2
      }
    }

    func rollBackBatch() {
      do {
        try withGraphTransaction {
          count = 3
          throw TestFailure.expected
        }
      } catch {
        // Expected failure exercises actor-isolated observer rollback.
      }
    }

    func snapshot() -> (Int, [(String, Int, Int)]) {
      (count, history)
    }
  }

  @Test("Staged writes are readable and commit after a successful body")
  func stagedWritesAreReadableInsideTransaction() {
    let node = Stored(wrappedValue: 0)
    var changes: [(oldValue: Int, newValue: Int)] = []

    node.onDidSet { oldValue, newValue in
      changes.append((oldValue, newValue))
    }

    let result = withGraphTransaction {
      node.wrappedValue = 42

      #expect(node.wrappedValue == 42)
      #expect(changes.isEmpty)
      return "committed"
    }

    #expect(result == "committed")
    #expect(node.wrappedValue == 42)
    #expect(changes.count == 1)
    #expect(changes.first?.oldValue == 0)
    #expect(changes.first?.newValue == 42)
  }

  @Test("Repeated writes to one node coalesce into one commit")
  func sameNodeWritesCoalesceIntoOneCommit() {
    let node = Stored(wrappedValue: 0)
    var changes: [(oldValue: Int, newValue: Int)] = []

    node.onDidSet { oldValue, newValue in
      changes.append((oldValue, newValue))
    }

    withGraphTransaction {
      node.wrappedValue = 1
      #expect(node.wrappedValue == 1)

      node.wrappedValue = 2
      #expect(node.wrappedValue == 2)
      #expect(changes.isEmpty)
    }

    #expect(node.wrappedValue == 2)
    #expect(changes.count == 1)
    #expect(changes.first?.oldValue == 0)
    #expect(changes.first?.newValue == 2)
  }

  @MainActor
  @Test("A thrown body discards values and every observer side effect")
  func throwDiscardsStagedValueAndSideEffects() {
    let node = Stored(wrappedValue: 0)
    var changes: [(Int, Int)] = []
    let observationInvalidations = OSAllocatedUnfairLock(initialState: 0)

    node.onDidSet { oldValue, newValue in
      changes.append((oldValue, newValue))
    }

    withObservationTracking {
      _ = node.wrappedValue
    } onChange: {
      observationInvalidations.withLock { $0 += 1 }
    }

    #expect(throws: TestFailure.self) {
      try withGraphTransaction {
        node.wrappedValue = 1
        #expect(node.wrappedValue == 1)
        throw TestFailure.expected
      }
    }

    #expect(node.wrappedValue == 0)
    #expect(changes.isEmpty)
    #expect(observationInvalidations.withLock { $0 } == 0)

    // The thread-local transaction and node lock must both be restored after failure.
    node.wrappedValue = 2
    #expect(node.wrappedValue == 2)
    #expect(changes.count == 1)
  }

  @Test("Every staged node is applied before commit callbacks run")
  func commitCallbacksSeeFinalSnapshot() {
    let first = Stored(wrappedValue: 0)
    let second = Stored(wrappedValue: 0)
    var snapshots: [(first: Int, second: Int)] = []

    first.onDidSet { _, _ in
      snapshots.append((first.wrappedValue, second.wrappedValue))
    }
    second.onDidSet { _, _ in
      snapshots.append((first.wrappedValue, second.wrappedValue))
    }

    withGraphTransaction {
      first.wrappedValue = 1
      second.wrappedValue = 2
    }

    #expect(snapshots.count == 2)
    #expect(snapshots.allSatisfy { $0.first == 1 && $0.second == 2 })
  }

  @Test("A successful nested transaction joins the outer commit")
  func nestedSuccessMergesWithoutEarlyCommit() {
    let first = Stored(wrappedValue: 0)
    let second = Stored(wrappedValue: 0)
    var callbackCount = 0

    first.onDidSet { _, _ in callbackCount += 1 }
    second.onDidSet { _, _ in callbackCount += 1 }

    withGraphTransaction {
      first.wrappedValue = 1

      withGraphTransaction {
        second.wrappedValue = 2
        #expect(first.wrappedValue == 1)
        #expect(second.wrappedValue == 2)
      }

      #expect(first.wrappedValue == 1)
      #expect(second.wrappedValue == 2)
      #expect(callbackCount == 0)
    }

    #expect(first.wrappedValue == 1)
    #expect(second.wrappedValue == 2)
    #expect(callbackCount == 2)
  }

  @Test("A caught nested failure restores its savepoint")
  func nestedThrowRestoresSavepoint() {
    let first = Stored(wrappedValue: 0)
    let second = Stored(wrappedValue: 0)
    let doubled = Computed { _ in first.wrappedValue * 2 }
    var firstChanges: [(Int, Int)] = []
    var secondChanges: [(Int, Int)] = []

    first.onDidSet { firstChanges.append(($0, $1)) }
    second.onDidSet { secondChanges.append(($0, $1)) }
    #expect(doubled.wrappedValue == 0)

    withGraphTransaction {
      first.wrappedValue = 1
      #expect(doubled.wrappedValue == 2)

      #expect(throws: TestFailure.self) {
        try withGraphTransaction {
          first.wrappedValue = 2
          second.wrappedValue = 3
          #expect(doubled.wrappedValue == 4)
          throw TestFailure.expected
        }
      }

      #expect(first.wrappedValue == 1)
      #expect(second.wrappedValue == 0)
      #expect(doubled.wrappedValue == 2)
      #expect(firstChanges.isEmpty)
      #expect(secondChanges.isEmpty)
    }

    #expect(first.wrappedValue == 1)
    #expect(second.wrappedValue == 0)
    #expect(doubled.wrappedValue == 2)
    #expect(firstChanges.count == 1)
    #expect(firstChanges.first?.0 == 0)
    #expect(firstChanges.first?.1 == 1)
    #expect(secondChanges.isEmpty)
  }

  @Test("An outer failure discards a successful nested transaction")
  func outerThrowRollsBackSuccessfulInnerTransaction() {
    let first = Stored(wrappedValue: 0)
    let second = Stored(wrappedValue: 0)
    var callbackCount = 0

    first.onDidSet { _, _ in callbackCount += 1 }
    second.onDidSet { _, _ in callbackCount += 1 }

    #expect(throws: TestFailure.self) {
      try withGraphTransaction {
        first.wrappedValue = 1

        withGraphTransaction {
          second.wrappedValue = 2
        }

        #expect(first.wrappedValue == 1)
        #expect(second.wrappedValue == 2)
        throw TestFailure.expected
      }
    }

    #expect(first.wrappedValue == 0)
    #expect(second.wrappedValue == 0)
    #expect(callbackCount == 0)
  }

  @Test("@GraphStored observers run once only for a successful commit")
  func graphStoredObserversAreCommitOnlyAndCoalesced() {
    final class Model {
      @GraphStored
      var count: Int = 0 {
        willSet {
          history.append(("will", count, newValue))
        }
        didSet {
          history.append(("did", oldValue, count))
        }
      }

      var history: [(phase: String, oldOrCurrent: Int, newOrCurrent: Int)] = []
    }

    let model = Model()

    withGraphTransaction {
      model.count = 1
      model.count = 2

      #expect(model.count == 2)
      #expect(model.history.isEmpty)
    }

    #expect(model.history.count == 2)
    #expect(model.history[0].phase == "will")
    #expect(model.history[0].oldOrCurrent == 0)
    #expect(model.history[0].newOrCurrent == 2)
    #expect(model.history[1].phase == "did")
    #expect(model.history[1].oldOrCurrent == 0)
    #expect(model.history[1].newOrCurrent == 2)

    model.history.removeAll()

    #expect(throws: TestFailure.self) {
      try withGraphTransaction {
        model.count = 3
        throw TestFailure.expected
      }
    }

    #expect(model.count == 2)
    #expect(model.history.isEmpty)
  }

  @Test("@GraphStored transaction observers preserve struct semantics")
  func graphStoredObserversWorkInStructs() {
    let history = HistoryBox()
    let model = StructObserverModel(history: history)

    withGraphTransaction {
      model.count = 1
      model.count = 2
      #expect(model.count == 2)
      #expect(history.values.isEmpty)
    }

    #expect(model.count == 2)
    #expect(history.values.count == 1)
    #expect(history.values.first?.0 == 0)
    #expect(history.values.first?.1 == 2)
  }

  @Test("@GraphStored transaction observers preserve actor isolation")
  func graphStoredObserversWorkInActors() async {
    let model = ActorObserverModel()

    await model.commitBatch()
    var snapshot = await model.snapshot()

    #expect(snapshot.0 == 2)
    #expect(snapshot.1.count == 2)
    #expect(snapshot.1[0].0 == "will")
    #expect(snapshot.1[1].0 == "did")

    await model.rollBackBatch()
    snapshot = await model.snapshot()

    #expect(snapshot.0 == 2)
    #expect(snapshot.1.count == 2)
  }

  @MainActor
  @Test("Observation invalidates once after the final snapshot is applied")
  func observationInvalidatesOnceWithFinalSnapshot() {
    let first = Stored(wrappedValue: 0)
    let second = Stored(wrappedValue: 0)
    let invalidationCount = OSAllocatedUnfairLock(initialState: 0)
    let snapshot = OSAllocatedUnfairLock<(Int, Int)?>(initialState: nil)

    withObservationTracking {
      _ = first.wrappedValue
      _ = second.wrappedValue
    } onChange: {
      snapshot.withLock { $0 = (first.wrappedValue, second.wrappedValue) }
      invalidationCount.withLock { $0 += 1 }
    }

    withGraphTransaction {
      first.wrappedValue = 1
      second.wrappedValue = 2

      #expect(invalidationCount.withLock { $0 } == 0)
    }

    #expect(invalidationCount.withLock { $0 } == 1)
    #expect(snapshot.withLock { $0?.0 } == 1)
    #expect(snapshot.withLock { $0?.1 } == 2)
  }

  @MainActor
  @Test("Observation callbacks see recomputed values from the final snapshot")
  func observationCallbacksDoNotReadStaleComputedValues() {
    let observedSource = Stored(wrappedValue: 0)
    let computedSource = Stored(wrappedValue: 1)
    let doubled = Computed { _ in computedSource.wrappedValue * 2 }
    let observedValue = OSAllocatedUnfairLock<Int?>(initialState: nil)

    #expect(doubled.wrappedValue == 2)

    withObservationTracking {
      _ = observedSource.wrappedValue
    } onChange: {
      observedValue.withLock { $0 = doubled.wrappedValue }
    }

    withGraphTransaction {
      observedSource.wrappedValue = 1
      computedSource.wrappedValue = 2
    }

    #expect(observedValue.withLock { $0 } == 4)
  }

  @MainActor
  @Test("A synchronous custom-storage callback cannot publish a partial batch")
  func synchronousStorageNotificationIsDeferredToBatchPublication() {
    let first = _Stored(storage: SynchronouslyNotifyingStorage(0))
    let second = Stored(wrappedValue: 0)
    let snapshot = OSAllocatedUnfairLock<(Int, Int)?>(initialState: nil)

    withObservationTracking {
      _ = first.wrappedValue
    } onChange: {
      snapshot.withLock { $0 = (first.wrappedValue, second.wrappedValue) }
    }

    withGraphTransaction {
      first.wrappedValue = 1
      second.wrappedValue = 2
    }

    #expect(snapshot.withLock { $0?.0 } == 1)
    #expect(snapshot.withLock { $0?.1 } == 2)
  }

  @Test("Computed values read staged values without leaking them on rollback")
  func computedValuesUseTransactionLocalCache() {
    let source = Stored(wrappedValue: 1)
    let doubled = Computed { _ in source.wrappedValue * 2 }

    #expect(doubled.wrappedValue == 2)

    withGraphTransaction {
      source.wrappedValue = 2
      #expect(doubled.wrappedValue == 4)

      source.wrappedValue = 3
      #expect(doubled.wrappedValue == 6)
    }

    #expect(source.wrappedValue == 3)
    #expect(doubled.wrappedValue == 6)

    #expect(throws: TestFailure.self) {
      try withGraphTransaction {
        source.wrappedValue = 4
        #expect(doubled.wrappedValue == 8)
        throw TestFailure.expected
      }
    }

    #expect(source.wrappedValue == 3)
    #expect(doubled.wrappedValue == 6)
  }

  @Test("A staged optional nil remains distinguishable from no staged value")
  func optionalNilIsReadableAndCommits() {
    let node = Stored<Int?>(wrappedValue: 1)

    withGraphTransaction {
      node.wrappedValue = nil
      #expect(node.wrappedValue == nil)
    }

    #expect(node.wrappedValue == nil)
  }

  @MainActor
  @Test("A net-zero batch runs assignment callbacks without invalidating observers")
  func netZeroBatchPreservesAssignmentSemantics() {
    let node = Stored(wrappedValue: 0)
    var changes: [(Int, Int)] = []
    let observationInvalidations = OSAllocatedUnfairLock(initialState: 0)

    node.onDidSet { changes.append(($0, $1)) }

    withObservationTracking {
      _ = node.wrappedValue
    } onChange: {
      observationInvalidations.withLock { $0 += 1 }
    }

    withGraphTransaction {
      node.wrappedValue = 1
      node.wrappedValue = 0
    }

    #expect(node.wrappedValue == 0)
    #expect(changes.count == 1)
    #expect(changes.first?.0 == 0)
    #expect(changes.first?.1 == 0)
    #expect(observationInvalidations.withLock { $0 } == 0)
  }

  @Test("UserDefaults storage is written only by a successful commit")
  func userDefaultsStorageCommitsOnlyAfterSuccess() {
    let suite = "GraphTransactionTests.\(UUID().uuidString)"
    let key = "value"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }

    let node = UserDefaultsStored<Int>(suite: suite, key: key, defaultValue: 0)

    #expect(throws: TestFailure.self) {
      try withGraphTransaction {
        node.wrappedValue = 1
        #expect(node.wrappedValue == 1)
        #expect(defaults.object(forKey: key) == nil)
        throw TestFailure.expected
      }
    }

    #expect(node.wrappedValue == 0)
    #expect(defaults.object(forKey: key) == nil)

    withGraphTransaction {
      node.wrappedValue = 2
      #expect(defaults.object(forKey: key) == nil)
    }

    #expect(node.wrappedValue == 2)
    #expect(defaults.integer(forKey: key) == 2)
  }

  @MainActor
  @Test("A shared-storage alias publishes only after the final batch is applied")
  func sharedStorageAliasCannotPublishAPartialBatch() {
    let suite = "GraphTransactionTests.\(UUID().uuidString)"
    let key = "shared-value"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }

    let writer = UserDefaultsStored<Int>(
      storage: UserDefaultsStorage(userDefaults: defaults, key: key, defaultValue: 0)
    )
    let alias = UserDefaultsStored<Int>(
      storage: UserDefaultsStorage(userDefaults: defaults, key: key, defaultValue: 0)
    )
    let other = Stored(wrappedValue: 0)
    let doubledAlias = Computed { _ in alias.wrappedValue * 2 }
    let snapshots = OSAllocatedUnfairLock(
      initialState: [(alias: Int, other: Int, doubledAlias: Int)]()
    )

    #expect(doubledAlias.wrappedValue == 0)

    withObservationTracking {
      _ = alias.wrappedValue
    } onChange: {
      snapshots.withLock {
        $0.append((alias.wrappedValue, other.wrappedValue, doubledAlias.wrappedValue))
      }
    }

    withGraphTransaction {
      writer.wrappedValue = 1
      other.wrappedValue = 2
    }

    #expect(alias.wrappedValue == 1)
    #expect(other.wrappedValue == 2)
    #expect(snapshots.withLock { $0.count } == 1)
    #expect(snapshots.withLock { $0.first?.alias } == 1)
    #expect(snapshots.withLock { $0.first?.other } == 2)
    #expect(snapshots.withLock { $0.first?.doubledAlias } == 2)
  }

  @Test("A commit observer can start a new transaction")
  func commitObserverCanStartANewTransaction() {
    final class Model {
      @GraphStored
      var first: Int = 0 {
        didSet {
          withGraphTransaction {
            second = first
          }
        }
      }

      @GraphStored
      var second: Int = 0
    }

    let model = Model()

    withGraphTransaction {
      model.first = 1
    }

    #expect(model.first == 1)
    #expect(model.second == 1)
  }

  @Test("A commit observer write waits for every staged observer to finish")
  func reentrantWriteToStagedNodeHasConsistentObserverHistory() {
    final class Model {
      @GraphStored
      var first: Int = 0 {
        didSet {
          withGraphTransaction {
            second = 3
          }
          secondReadDuringFirstObserver = second
        }
      }

      @GraphStored
      var second: Int = 0 {
        didSet {
          secondHistory.append((oldValue, second))
        }
      }

      var secondHistory: [(Int, Int)] = []
      var secondReadDuringFirstObserver: Int?
    }

    let model = Model()

    withGraphTransaction {
      model.first = 1
      model.second = 2
    }

    #expect(model.second == 3)
    #expect(model.secondReadDuringFirstObserver == 3)
    #expect(model.secondHistory.count == 2)
    #expect(model.secondHistory[0].0 == 0)
    #expect(model.secondHistory[0].1 == 2)
    #expect(model.secondHistory[1].0 == 2)
    #expect(model.secondHistory[1].1 == 3)
  }

  @Test("A transaction started by willSet rebases before its deferred commit")
  func willSetTransactionRebasesItsOriginalValue() {
    final class Model {
      @GraphStored
      var first: Int = 0 {
        willSet {
          withGraphTransaction {
            second = 3
          }
          secondReadDuringWillSet = second
        }
      }

      @GraphStored
      var second: Int = 0 {
        didSet {
          secondHistory.append((oldValue, second))
        }
      }

      var secondHistory: [(Int, Int)] = []
      var secondReadDuringWillSet: Int?
    }

    let model = Model()

    withGraphTransaction {
      model.first = 1
      model.second = 2
    }

    #expect(model.second == 3)
    #expect(model.secondReadDuringWillSet == 3)
    #expect(model.secondHistory.count == 2)
    #expect(model.secondHistory[0].0 == 0)
    #expect(model.secondHistory[0].1 == 2)
    #expect(model.secondHistory[1].0 == 2)
    #expect(model.secondHistory[1].1 == 3)
  }

  @Test("Deferred callback batches rebase in serialization order")
  func deferredCallbackBatchesRebaseInSerializationOrder() {
    final class Model {
      @GraphStored
      var firstTrigger: Int = 0 {
        didSet {
          withGraphTransaction {
            target = 1
          }
        }
      }

      @GraphStored
      var secondTrigger: Int = 0 {
        didSet {
          withGraphTransaction {
            target = 0
          }
        }
      }

      @GraphStored
      var target: Int = 0 {
        didSet {
          targetHistory.append((oldValue, target))
        }
      }

      var targetHistory: [(Int, Int)] = []
    }

    let model = Model()

    withGraphTransaction {
      model.firstTrigger = 1
      model.secondTrigger = 1
    }

    #expect(model.target == 0)
    #expect(model.targetHistory.count == 2)
    #expect(model.targetHistory[0].0 == 0)
    #expect(model.targetHistory[0].1 == 1)
    #expect(model.targetHistory[1].0 == 1)
    #expect(model.targetHistory[1].1 == 0)
  }

  @Test("Nested follow-up batches preserve FIFO scheduling order")
  func nestedFollowUpBatchesPreserveFIFOOrder() {
    let firstTrigger = Stored(wrappedValue: 0)
    let secondTrigger = Stored(wrappedValue: 0)
    let target = Stored(wrappedValue: 0)
    var targetHistory: [Int] = []

    firstTrigger.onDidSet { _, _ in
      target.wrappedValue = 1
    }
    secondTrigger.onDidSet { _, _ in
      target.wrappedValue = 2
    }
    target.onDidSet { _, newValue in
      targetHistory.append(newValue)
      if newValue == 1 {
        target.wrappedValue = 3
      }
    }

    withGraphTransaction {
      firstTrigger.wrappedValue = 1
      secondTrigger.wrappedValue = 1
    }

    #expect(targetHistory == [1, 2, 3])
    #expect(target.wrappedValue == 3)
  }

  @Test("Explicit transactions in one callback coalesce into one follow-up batch")
  func explicitTransactionsInOneCallbackCoalesce() {
    let trigger = Stored(wrappedValue: 0)
    let target = Stored(wrappedValue: 0)
    var callbackRead: Int?
    var targetHistory: [(Int, Int)] = []

    trigger.onDidSet { _, _ in
      withGraphTransaction {
        target.wrappedValue = 1
      }
      withGraphTransaction {
        target.wrappedValue = 2
      }
      callbackRead = target.wrappedValue
    }
    target.onDidSet { oldValue, newValue in
      targetHistory.append((oldValue, newValue))
    }

    withGraphTransaction {
      trigger.wrappedValue = 1
    }

    #expect(callbackRead == 2)
    #expect(target.wrappedValue == 2)
    #expect(targetHistory.count == 1)
    #expect(targetHistory.first?.0 == 0)
    #expect(targetHistory.first?.1 == 2)
  }

  @Test("Direct callback writes are immediately readable from one follow-up batch")
  func directCallbackWritesAreImmediatelyReadable() {
    let trigger = Stored(wrappedValue: 0)
    let source = Stored(wrappedValue: 0)
    let doubled = Computed { _ in source.wrappedValue * 2 }
    var sourceReads: [Int] = []
    var computedReads: [Int] = []

    #expect(doubled.wrappedValue == 0)

    trigger.onDidSet { _, _ in
      source.wrappedValue = 1
      sourceReads.append(source.wrappedValue)
      computedReads.append(doubled.wrappedValue)

      source.wrappedValue += 1
      sourceReads.append(source.wrappedValue)
      computedReads.append(doubled.wrappedValue)
    }

    withGraphTransaction {
      trigger.wrappedValue = 1
    }

    #expect(sourceReads == [1, 2])
    #expect(computedReads == [2, 4])
    #expect(source.wrappedValue == 2)
    #expect(doubled.wrappedValue == 4)
  }

  @Test("Direct writes from one callback publish as one atomic follow-up batch")
  func directCallbackWritesPublishAsOneBatch() {
    let trigger = Stored(wrappedValue: 0)
    let first = Stored(wrappedValue: 0)
    let second = Stored(wrappedValue: 0)
    var snapshots: [(first: Int, second: Int)] = []

    trigger.onDidSet { _, _ in
      first.wrappedValue = 1
      second.wrappedValue = first.wrappedValue
    }
    first.onDidSet { _, _ in
      snapshots.append((first.wrappedValue, second.wrappedValue))
    }
    second.onDidSet { _, _ in
      snapshots.append((first.wrappedValue, second.wrappedValue))
    }

    withGraphTransaction {
      trigger.wrappedValue = 1
    }

    #expect(first.wrappedValue == 1)
    #expect(second.wrappedValue == 1)
    #expect(snapshots.count == 2)
    #expect(snapshots.allSatisfy { $0.first == 1 && $0.second == 1 })
  }

  @Test("A nested failure restores the callback follow-up batch savepoint")
  func nestedFailureRestoresCallbackFollowUpBatch() {
    let trigger = Stored(wrappedValue: 0)
    let target = Stored(wrappedValue: 0)
    var callbackRead: Int?

    trigger.onDidSet { _, _ in
      target.wrappedValue = 1

      #expect(throws: TestFailure.self) {
        try withGraphTransaction {
          target.wrappedValue = 2
          throw TestFailure.expected
        }
      }

      callbackRead = target.wrappedValue
    }

    withGraphTransaction {
      trigger.wrappedValue = 1
    }

    #expect(callbackRead == 1)
    #expect(target.wrappedValue == 1)
  }

  @Test("A callback follow-up batch is hidden from later callbacks in the current batch")
  func callbackFollowUpBatchDoesNotLeakIntoLaterCallbacks() {
    let firstTrigger = Stored(wrappedValue: 0)
    let target = Stored(wrappedValue: 0)
    let secondTrigger = Stored(wrappedValue: 0)
    var firstCallbackRead: Int?
    var secondCallbackRead: Int?

    firstTrigger.onDidSet { _, _ in
      target.wrappedValue = 3
      firstCallbackRead = target.wrappedValue
    }
    secondTrigger.onDidSet { _, _ in
      secondCallbackRead = target.wrappedValue
    }

    withGraphTransaction {
      firstTrigger.wrappedValue = 1
      target.wrappedValue = 2
      secondTrigger.wrappedValue = 1
    }

    #expect(firstCallbackRead == 3)
    #expect(secondCallbackRead == 2)
    #expect(target.wrappedValue == 3)
  }

  @MainActor
  @Test("Observation callback writes are immediately readable")
  func observationCallbackWritesAreImmediatelyReadable() {
    let trigger = Stored(wrappedValue: 0)
    let target = Stored(wrappedValue: 0)
    let callbackRead = OSAllocatedUnfairLock<Int?>(initialState: nil)

    withObservationTracking {
      _ = trigger.wrappedValue
    } onChange: {
      target.wrappedValue = 3
      callbackRead.withLock { $0 = target.wrappedValue }
    }

    withGraphTransaction {
      trigger.wrappedValue = 1
      target.wrappedValue = 2
    }

    #expect(callbackRead.withLock { $0 } == 3)
    #expect(target.wrappedValue == 3)
  }

  @MainActor
  @Test("Observation subscribers in one publication share a follow-up batch")
  func observationSubscribersShareOneFollowUpBatch() {
    let trigger = Stored(wrappedValue: 0)
    let target = Stored(wrappedValue: 0)
    let records = OSAllocatedUnfairLock<[(label: String, before: Int, after: Int)]>(
      initialState: []
    )

    withObservationTracking {
      _ = trigger.wrappedValue
    } onChange: {
      let before = target.wrappedValue
      target.wrappedValue = 11
      let after = target.wrappedValue
      records.withLock { $0.append(("first", before, after)) }
    }

    withObservationTracking {
      _ = trigger.wrappedValue
    } onChange: {
      let before = target.wrappedValue
      target.wrappedValue = 12
      let after = target.wrappedValue
      records.withLock { $0.append(("second", before, after)) }
    }

    withGraphTransaction {
      trigger.wrappedValue = 1
      target.wrappedValue = 10
    }

    let snapshot = records.withLock { $0 }
    let beforeValues = Set(snapshot.map(\.before))
    let afterValues = Set(snapshot.map(\.after))

    #expect(snapshot.count == 2)
    #expect(beforeValues.contains(10))
    #expect(beforeValues.count == 2)
    #expect(beforeValues.isSubset(of: [10, 11, 12]))
    #expect(afterValues == [11, 12])
    #expect(target.wrappedValue == snapshot.last?.after)
  }

  @Test("A completion callback mutation still invalidates StateGraph tracking")
  func completionCallbackMutationIsNotLost() async {
    let trigger = Stored(wrappedValue: 0)
    let source = Stored(wrappedValue: 0)
    let doubled = Computed { _ in source.wrappedValue * 2 }

    trigger.onDidSet { _, _ in
      source.wrappedValue = 1
    }

    await confirmation("Receives the reentrant mutation", expectedCount: 1) { confirmation in
      let cancellable = withGraphTracking {
        withGraphTrackingMap {
          doubled.wrappedValue
        } onChange: { value in
          if value == 2 {
            confirmation.confirm()
          }
        }
      }

      withGraphTransaction {
        trigger.wrappedValue = 1
      }

      try? await Task.sleep(for: .milliseconds(50))
      withExtendedLifetime(cancellable) {}
    }
  }

  @Test("One StateGraph tracking registration runs once for a multi-node batch")
  func trackingRegistrationIsDeduplicatedAcrossNodes() async {
    let first = Stored(wrappedValue: 0)
    let second = Stored(wrappedValue: 0)

    await confirmation("Receives one batched invalidation", expectedCount: 1) { confirmation in
      let cancellable = withGraphTracking {
        withGraphTrackingMap {
          first.wrappedValue + second.wrappedValue
        } onChange: { value in
          if value == 3 {
            confirmation.confirm()
          }
        }
      }

      withGraphTransaction {
        first.wrappedValue = 1
        second.wrappedValue = 2
      }

      try? await Task.sleep(for: .milliseconds(50))
      withExtendedLifetime(cancellable) {}
    }
  }

  @Test("A thrown transaction releases the node lock")
  func releasesStoredNodeLockAfterThrow() {
    let node = Stored(wrappedValue: 0)

    #expect(throws: TestFailure.self) {
      try withGraphTransaction {
        node.wrappedValue = 1
        throw TestFailure.expected
      }
    }

    let acquiredFromAnotherThread = OSAllocatedUnfairLock<Bool?>(initialState: nil)
    let finished = DispatchSemaphore(value: 0)

    Thread.detachNewThread {
      let didAcquire = node.lock.try()
      if didAcquire {
        node.lock.unlock()
      }
      acquiredFromAnotherThread.withLock { $0 = didAcquire }
      finished.signal()
    }

    finished.wait()

    #expect(acquiredFromAnotherThread.withLock { $0 } == true)
  }
}
