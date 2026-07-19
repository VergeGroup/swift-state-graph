import Foundation
import StateGraph
import Testing
@testable import StateGraphUbiquitousKeyValue

@Suite("@GraphUbiquitousKeyValue", .serialized)
struct GraphUbiquitousKeyValueTests {

  /// A deterministic, in-memory boundary for the process-wide iCloud store.
  ///
  /// The fake deliberately invokes synchronization hooks and observers after
  /// releasing its state lock. This matches the production requirement that
  /// Foundation callbacks may synchronously reenter the graph coordinator.
  private final class FakeClient: UbiquitousKeyValueStoreClient, @unchecked Sendable {
    enum Operation: Equatable, Sendable {
      case read(String)
      case set(String)
      case remove(String)
      case observe
      case cancelObservation
      case synchronize
    }

    private struct State {
      var values: [String: Any] = [:]
      var observers: [
        UUID: @Sendable (UbiquitousKeyValueStoreChange) -> Void
      ] = [:]
      var operations: [Operation] = []
      var observationCount = 0
      var cancellationCount = 0
      var synchronizationCount = 0
      var synchronizationResult = true
      var synchronizationAction: (@Sendable () -> Void)?
      var nextReadBarrier: BlockingRead?
    }

    private let lock = NSLock()
    private var state = State()

    /// Protects the fake's intentionally type-erased property-list storage.
    ///
    /// `OSAllocatedUnfairLock` requires a `Sendable` protected value, while the
    /// Foundation client contract necessarily carries `Any`. The fake owns the
    /// unchecked boundary and never accesses `state` outside this method.
    private func withState<Result>(
      _ body: (inout State) throws -> Result
    ) rethrows -> Result {
      lock.lock()
      defer { lock.unlock() }
      return try body(&state)
    }

    var operations: [Operation] {
      withState { $0.operations }
    }

    var observationCount: Int {
      withState { $0.observationCount }
    }

    var cancellationCount: Int {
      withState { $0.cancellationCount }
    }

    var synchronizationCount: Int {
      withState { $0.synchronizationCount }
    }

    var currentObserverCount: Int {
      withState { $0.observers.count }
    }

    func readCount(forKey key: String) -> Int {
      operations.reduce(into: 0) { count, operation in
        if case .read(let operationKey) = operation, operationKey == key {
          count += 1
        }
      }
    }

    func setCount(forKey key: String) -> Int {
      operations.reduce(into: 0) { count, operation in
        if case .set(let operationKey) = operation, operationKey == key {
          count += 1
        }
      }
    }

    func string(forKey key: String) -> String? {
      withState { $0.values[key] as? String }
    }

    /// Changes the fake store without generating a local or external event.
    func setValue(_ value: Any, forKey key: String) {
      withState { $0.values[key] = value }
    }

    /// Removes a fake store value without generating an event.
    func removeValue(forKey key: String) {
      withState { $0.values[key] = nil }
    }

    func setSynchronizationAction(
      _ action: @escaping @Sendable () -> Void
    ) {
      withState { $0.synchronizationAction = action }
    }

    func blockNextRead(with barrier: BlockingRead) {
      withState { $0.nextReadBarrier = barrier }
    }

    /// Delivers one normalized iCloud event to the active observation.
    func send(
      reason: UbiquitousKeyValueStoreChangeReason,
      changedKeys: Set<String>?
    ) {
      let observers = withState { Array($0.observers.values) }
      let change = UbiquitousKeyValueStoreChange(
        reason: reason,
        changedKeys: changedKeys
      )

      for observer in observers {
        observer(change)
      }
    }

    func object(forKey key: String) -> Any? {
      let snapshot: (value: Any?, barrier: BlockingRead?) = withState { state in
        state.operations.append(.read(key))
        let barrier = state.nextReadBarrier
        state.nextReadBarrier = nil
        return (state.values[key], barrier)
      }

      snapshot.barrier?.wait()
      return snapshot.value
    }

    func set(_ object: Any, forKey key: String) {
      withState { state in
        state.operations.append(.set(key))
        state.values[key] = object
      }
    }

    func removeObject(forKey key: String) {
      withState { state in
        state.operations.append(.remove(key))
        state.values[key] = nil
      }
    }

    func synchronize() -> Bool {
      let snapshot: (result: Bool, action: (@Sendable () -> Void)?) =
        withState { state in
          state.operations.append(.synchronize)
          state.synchronizationCount += 1
          return (state.synchronizationResult, state.synchronizationAction)
        }

      snapshot.action?()
      return snapshot.result
    }

    func observe(
      _ receiveChange: @escaping @Sendable (UbiquitousKeyValueStoreChange) -> Void
    ) -> UbiquitousKeyValueStoreObservation {
      let id = UUID()
      withState { state in
        state.operations.append(.observe)
        state.observationCount += 1
        state.observers[id] = receiveChange
      }

      return UbiquitousKeyValueStoreObservation { [weak self] in
        self?.cancelObservation(id: id)
      }
    }

    private func cancelObservation(id: UUID) {
      withState { state in
        guard state.observers.removeValue(forKey: id) != nil else { return }
        state.operations.append(.cancelObservation)
        state.cancellationCount += 1
      }
    }
  }

  /// Suspends one fake read after it captures its return value.
  private final class BlockingRead: @unchecked Sendable {
    let didStart = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)

    func wait() {
      didStart.signal()
      resume.wait()
    }
  }

  private final class Counter: @unchecked Sendable {
    private let value = OSAllocatedUnfairLock(initialState: 0)

    var current: Int {
      value.withLock { $0 }
    }

    func increment() {
      value.withLock { $0 += 1 }
    }
  }

  /// Allows exactly one reentrant callback to claim the nested mutation.
  private final class OnceFlag: @unchecked Sendable {
    private let value = OSAllocatedUnfairLock(initialState: false)

    var isClaimed: Bool {
      value.withLock { $0 }
    }

    func claim() -> Bool {
      value.withLock { isClaimed in
        guard !isClaimed else { return false }
        isClaimed = true
        return true
      }
    }
  }

  private final class ValueBox<Value: Sendable>: @unchecked Sendable {
    private let value = OSAllocatedUnfairLock<Value?>(initialState: nil)

    var current: Value? {
      value.withLock { $0 }
    }

    func store(_ newValue: Value) {
      value.withLock { $0 = newValue }
    }
  }

  private final class PublicationLockProbe: @unchecked Sendable {
    private struct State {
      var didRun = false
      var concurrentOperationCompleted = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var result: (didRun: Bool, concurrentOperationCompleted: Bool) {
      state.withLock { ($0.didRun, $0.concurrentOperationCompleted) }
    }

    func verifyConcurrentOperation(
      _ operation: @escaping @Sendable () -> Void
    ) {
      let operationFinished = DispatchSemaphore(value: 0)
      DispatchQueue.global().async {
        operation()
        operationFinished.signal()
      }

      let didComplete = operationFinished.wait(timeout: .now() + 1) == .success
      state.withLock {
        $0.didRun = true
        $0.concurrentOperationCompleted = didComplete
      }
    }
  }

  private final class Model<
    Value: UbiquitousKeyValueStorable & SendableMetatype
  > {
    @GraphUbiquitousKeyValue var value: Value

    init(
      key: String,
      defaultValue: Value,
      coordinator: UbiquitousKeyValueAccessCoordinator
    ) {
      _value = GraphUbiquitousKeyValue(
        wrappedValue: defaultValue,
        key,
        coordinator: coordinator
      )
    }

    var projection: GraphUbiquitousKeyValue<Value> {
      $value
    }
  }

  private struct CodableValue:
    Codable,
    Equatable,
    Sendable,
    UbiquitousKeyValueStorable
  {
    var name: String
    var count: Int
  }

  private func makeCoordinator(
    client: FakeClient
  ) -> UbiquitousKeyValueAccessCoordinator {
    UbiquitousKeyValueAccessCoordinator(client: client)
  }

  @Test
  func foundationNotificationMetadataIsNormalized() {
    let reasons: [(Int, UbiquitousKeyValueStoreChangeReason)] = [
      (NSUbiquitousKeyValueStoreServerChange, .server),
      (NSUbiquitousKeyValueStoreInitialSyncChange, .initialSync),
      (NSUbiquitousKeyValueStoreQuotaViolationChange, .quotaViolation),
      (NSUbiquitousKeyValueStoreAccountChange, .account),
    ]

    for (rawReason, expectedReason) in reasons {
      let userInfo: [AnyHashable: Any] = [
        NSUbiquitousKeyValueStoreChangeReasonKey: NSNumber(value: rawReason)
      ]
      #expect(
        FoundationUbiquitousKeyValueStoreClient.change(from: userInfo).reason
          == expectedReason
      )
    }

    let userInfo: [AnyHashable: Any] = [
      NSUbiquitousKeyValueStoreChangeReasonKey:
        NSNumber(value: NSUbiquitousKeyValueStoreServerChange),
      NSUbiquitousKeyValueStoreChangedKeysKey: ["value", "value", "other"],
    ]
    #expect(
      FoundationUbiquitousKeyValueStoreClient.change(from: userInfo)
        == UbiquitousKeyValueStoreChange(
          reason: .server,
          changedKeys: ["value", "other"]
        )
    )
    #expect(
      FoundationUbiquitousKeyValueStoreClient.change(from: nil)
        == UbiquitousKeyValueStoreChange(
          reason: .unknown(nil),
          changedKeys: nil
        )
    )
  }

  @Test
  func observesBeforeRequestingInitialSynchronizationAndRequestsItOnce() {
    let key = "value"
    let client = FakeClient()
    let coordinator = makeCoordinator(client: client)
    client.setSynchronizationAction { [weak client] in
      guard let client else { return }
      client.setValue("synchronized", forKey: key)
      client.send(reason: .initialSync, changedKeys: [key])
    }

    let first = GraphUbiquitousKeyValue(
      wrappedValue: "default",
      key,
      coordinator: coordinator
    )
    let second = GraphUbiquitousKeyValue(
      wrappedValue: "default",
      key,
      coordinator: coordinator
    )

    #expect(first.wrappedValue == "synchronized")
    #expect(second.wrappedValue == "synchronized")
    #expect(client.observationCount == 1)
    #expect(client.synchronizationCount == 1)

    let operations = client.operations
    let observationIndex = operations.firstIndex(of: .observe)
    let synchronizationIndex = operations.firstIndex(of: .synchronize)
    #expect(observationIndex != nil)
    #expect(synchronizationIndex != nil)
    if let observationIndex, let synchronizationIndex {
      #expect(observationIndex < synchronizationIndex)
    }
  }

  @Test
  func assigningDefaultValuePersistsAnAbsentKey() {
    let key = "value"
    let client = FakeClient()
    let value = GraphUbiquitousKeyValue(
      wrappedValue: "default",
      key,
      coordinator: makeCoordinator(client: client)
    )
    let counter = Counter()
    value.onDidSet { _, _ in counter.increment() }

    value.wrappedValue = "default"

    #expect(client.string(forKey: key) == "default")
    #expect(client.setCount(forKey: key) == 1)
    #expect(value.wrappedValue == "default")
    #expect(counter.current == 0)
  }

  @Test
  func propertyListAndOptionalValuesRoundTrip() {
    let client = FakeClient()
    let coordinator = makeCoordinator(client: client)
    let integer = GraphUbiquitousKeyValue(
      wrappedValue: 0,
      "integer",
      coordinator: coordinator
    )
    let float = GraphUbiquitousKeyValue(
      wrappedValue: Float.zero,
      "float",
      coordinator: coordinator
    )
    let data = GraphUbiquitousKeyValue(
      wrappedValue: Data(),
      "data",
      coordinator: coordinator
    )
    let date = GraphUbiquitousKeyValue(
      wrappedValue: Date(timeIntervalSince1970: 0),
      "date",
      coordinator: coordinator
    )
    let array = GraphUbiquitousKeyValue(
      wrappedValue: [Int](),
      "array",
      coordinator: coordinator
    )
    let dictionary = GraphUbiquitousKeyValue(
      wrappedValue: [String: Bool](),
      "dictionary",
      coordinator: coordinator
    )
    let optional = GraphUbiquitousKeyValue<String?>(
      wrappedValue: nil,
      "optional",
      coordinator: coordinator
    )

    integer.wrappedValue = 42
    float.wrappedValue = 1.25
    data.wrappedValue = Data([1, 2, 3])
    date.wrappedValue = Date(timeIntervalSince1970: 1_234)
    array.wrappedValue = [1, 2, 3]
    dictionary.wrappedValue = ["enabled": true]
    optional.wrappedValue = "present"

    #expect(integer.wrappedValue == 42)
    #expect(client.object(forKey: "integer") as? Int64 == 42)
    #expect(float.wrappedValue == 1.25)
    #expect(client.object(forKey: "float") as? Double == 1.25)
    #expect(data.wrappedValue == Data([1, 2, 3]))
    #expect(date.wrappedValue == Date(timeIntervalSince1970: 1_234))
    #expect(array.wrappedValue == [1, 2, 3])
    #expect(dictionary.wrappedValue == ["enabled": true])
    #expect(optional.wrappedValue == "present")

    optional.wrappedValue = nil

    #expect(client.object(forKey: "optional") == nil)
    #expect(optional.wrappedValue == nil)
  }

  @Test
  func codableValueRoundTripsThroughDataRepresentation() {
    let key = "codable"
    let client = FakeClient()
    let coordinator = makeCoordinator(client: client)
    let value = GraphUbiquitousKeyValue(
      wrappedValue: CodableValue(name: "default", count: 0),
      key,
      coordinator: coordinator
    )

    value.wrappedValue = CodableValue(name: "saved", count: 42)

    let restored = GraphUbiquitousKeyValue(
      wrappedValue: CodableValue(name: "fallback", count: -1),
      key,
      coordinator: coordinator
    )
    #expect(client.object(forKey: key) is Data)
    #expect(restored.wrappedValue == CodableValue(name: "saved", count: 42))
  }

  @Test
  func invalidCollectionRepresentationRestoresDeclaredDefault() {
    let key = "array"
    let client = FakeClient()
    client.setValue([Int64(1)], forKey: key)
    let value = GraphUbiquitousKeyValue(
      wrappedValue: [9],
      key,
      coordinator: makeCoordinator(client: client)
    )

    #expect(value.wrappedValue == [1])

    client.setValue(["invalid"], forKey: key)
    client.send(reason: .server, changedKeys: [key])

    #expect(value.wrappedValue == [9])
  }

  @Test
  func localWriteConvergesPeerWrappersWithoutExternalNotification() {
    let key = "value"
    let client = FakeClient()
    let coordinator = makeCoordinator(client: client)
    let first = GraphUbiquitousKeyValue(
      wrappedValue: "initial",
      key,
      coordinator: coordinator
    )
    let second = GraphUbiquitousKeyValue(
      wrappedValue: "initial",
      key,
      coordinator: coordinator
    )
    let firstCounter = Counter()
    let secondCounter = Counter()
    first.onDidSet { _, _ in firstCounter.increment() }
    second.onDidSet { _, _ in secondCounter.increment() }

    first.wrappedValue = "shared"

    #expect(client.string(forKey: key) == "shared")
    #expect(first.wrappedValue == "shared")
    #expect(second.wrappedValue == "shared")
    #expect(firstCounter.current == 1)
    #expect(secondCounter.current == 1)
  }

  @Test
  func externalReasonsRefreshOnlyTheirIntendedKeys() {
    let key = "value"
    let client = FakeClient()
    let value = GraphUbiquitousKeyValue(
      wrappedValue: "initial",
      key,
      coordinator: makeCoordinator(client: client)
    )
    let counter = Counter()
    value.onDidSet { _, _ in counter.increment() }

    let readsBeforeUnrelatedChange = client.readCount(forKey: key)
    client.setValue("server", forKey: key)
    client.send(reason: .server, changedKeys: ["other"])

    #expect(value.wrappedValue == "initial")
    #expect(client.readCount(forKey: key) == readsBeforeUnrelatedChange)

    client.send(reason: .server, changedKeys: [key])
    #expect(value.wrappedValue == "server")

    client.setValue("initial-sync", forKey: key)
    client.send(reason: .initialSync, changedKeys: nil)
    #expect(value.wrappedValue == "initial-sync")
    #expect(counter.current == 2)

    let readsBeforeIgnoredReasons = client.readCount(forKey: key)
    client.setValue("ignored", forKey: key)
    client.send(reason: .quotaViolation, changedKeys: [key])
    client.send(reason: .unknown(nil), changedKeys: [key])

    #expect(value.wrappedValue == "initial-sync")
    #expect(client.readCount(forKey: key) == readsBeforeIgnoredReasons)
    #expect(counter.current == 2)
  }

  @Test
  func accountChangeRefreshesAllKeysAndRemovalRestoresDefault() {
    let key = "value"
    let client = FakeClient()
    client.setValue("persisted", forKey: key)
    let value = GraphUbiquitousKeyValue(
      wrappedValue: "default",
      key,
      coordinator: makeCoordinator(client: client)
    )
    let counter = Counter()
    value.onDidSet { _, _ in counter.increment() }

    client.removeValue(forKey: key)
    client.send(reason: .account, changedKeys: ["other"])

    #expect(value.wrappedValue == "default")
    #expect(counter.current == 1)
  }

  @Test
  func duplicateExternalNotificationsPublishOnlyOnce() {
    let key = "value"
    let client = FakeClient()
    let value = GraphUbiquitousKeyValue(
      wrappedValue: "initial",
      key,
      coordinator: makeCoordinator(client: client)
    )
    let counter = Counter()
    value.onDidSet { _, _ in counter.increment() }

    client.setValue("external", forKey: key)
    client.send(reason: .server, changedKeys: [key])
    client.send(reason: .server, changedKeys: [key])

    #expect(value.wrappedValue == "external")
    #expect(counter.current == 1)
  }

  @Test
  func externalChangeInvalidatesGraphDependencies() async {
    let key = "value"
    let client = FakeClient()
    let value = GraphUbiquitousKeyValue(
      wrappedValue: "initial",
      key,
      coordinator: makeCoordinator(client: client)
    )
    let projection = value.projectedValue
    let computed = Computed<String>(name: "dependent") { _ in
      "computed_\(projection.wrappedValue)"
    }

    #expect(computed.wrappedValue == "computed_initial")

    await confirmation(expectedCount: 1) { confirmation in
      let cancellable = withGraphTracking {
        withGraphTrackingMap {
          computed.wrappedValue
        } onChange: { value in
          guard value == "computed_external" else { return }
          confirmation.confirm()
        }
      }

      client.setValue("external", forKey: key)
      client.send(reason: .server, changedKeys: [key])

      try? await Task.sleep(for: .milliseconds(20))
      withExtendedLifetime(cancellable) {}
    }
  }

  @Test
  func retainedProjectionKeepsSynchronizationAlive() {
    let key = "value"
    let client = FakeClient()
    let coordinator = makeCoordinator(client: client)
    var model: Model<String>? = Model(
      key: key,
      defaultValue: "initial",
      coordinator: coordinator
    )
    var projection: GraphUbiquitousKeyValue<String>? = model!.projection

    #expect(model!.projection === projection!)

    model = nil
    client.setValue("external", forKey: key)
    client.send(reason: .server, changedKeys: [key])

    #expect(projection?.wrappedValue == "external")
    projection?.wrappedValue = "projected"
    #expect(client.string(forKey: key) == "projected")
    #expect(client.currentObserverCount == 1)

    projection = nil
    #expect(client.currentObserverCount == 0)
    #expect(client.cancellationCount == 1)

    let restarted = GraphUbiquitousKeyValue(
      wrappedValue: "initial",
      key,
      coordinator: coordinator
    )
    #expect(restarted.wrappedValue == "projected")
    #expect(client.observationCount == 2)
    #expect(client.synchronizationCount == 1)
  }

  @Test
  func finalRefreshClosesInitialReadObservationGap() {
    let key = "value"
    let client = FakeClient()
    client.setValue("initial", forKey: key)
    let coordinator = makeCoordinator(client: client)
    let barrier = BlockingRead()
    client.blockNextRead(with: barrier)
    let valueBox = ValueBox<GraphUbiquitousKeyValue<String>>()
    let initializationFinished = DispatchSemaphore(value: 0)

    DispatchQueue.global().async {
      valueBox.store(
        GraphUbiquitousKeyValue(
          wrappedValue: "default",
          key,
          coordinator: coordinator
        )
      )
      initializationFinished.signal()
    }

    #expect(barrier.didStart.wait(timeout: .now() + 1) == .success)
    client.setValue("during-initialization", forKey: key)
    barrier.resume.signal()

    #expect(initializationFinished.wait(timeout: .now() + 1) == .success)
    #expect(valueBox.current?.wrappedValue == "during-initialization")
  }

  @Test
  func publicationRunsAfterCoordinatorUnlocks() {
    let client = FakeClient()
    let coordinator = makeCoordinator(client: client)
    let observed = GraphUbiquitousKeyValue(
      wrappedValue: "initial",
      "observed",
      coordinator: coordinator
    )
    let concurrent = GraphUbiquitousKeyValue(
      wrappedValue: "initial",
      "concurrent",
      coordinator: coordinator
    )
    let probe = PublicationLockProbe()

    observed.onDidSet { _, _ in
      probe.verifyConcurrentOperation {
        // Equal assignment exercises the coordinator without queuing another
        // graph publication behind the callback that is currently running.
        concurrent.wrappedValue = "initial"
      }
    }

    observed.wrappedValue = "updated"

    let result = probe.result
    #expect(result.didRun)
    #expect(result.concurrentOperationCompleted)
  }

  @Test
  func nestedCoordinatorPublicationPreservesOuterReentrancy() {
    let firstClient = FakeClient()
    let secondClient = FakeClient()
    let first = GraphUbiquitousKeyValue(
      wrappedValue: "initial",
      "first",
      coordinator: makeCoordinator(client: firstClient)
    )
    let second = GraphUbiquitousKeyValue(
      wrappedValue: "initial",
      "second",
      coordinator: makeCoordinator(client: secondClient)
    )

    first.onDidSet { _, newValue in
      guard newValue == "first" else { return }
      second.wrappedValue = "nested"
      first.wrappedValue = "second"
    }

    let mutationFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      first.wrappedValue = "first"
      mutationFinished.signal()
    }

    #expect(mutationFinished.wait(timeout: .now() + 1) == .success)
    #expect(first.wrappedValue == "second")
    #expect(second.wrappedValue == "nested")
  }

  @Test
  func reentrantWriteConvergesAllPeerWrappers() {
    let key = "value"
    let client = FakeClient()
    let coordinator = makeCoordinator(client: client)
    let first = GraphUbiquitousKeyValue(
      wrappedValue: "initial",
      key,
      coordinator: coordinator
    )
    let second = GraphUbiquitousKeyValue(
      wrappedValue: "initial",
      key,
      coordinator: coordinator
    )
    let nestedWrite = OnceFlag()

    let handler: (String, String) -> Void = { _, newValue in
      guard newValue == "first", nestedWrite.claim() else { return }
      first.wrappedValue = "second"
    }
    first.onDidSet(handler)
    second.onDidSet(handler)

    client.setValue("first", forKey: key)
    client.send(reason: .server, changedKeys: [key])

    #expect(nestedWrite.isClaimed)
    #expect(client.string(forKey: key) == "second")
    #expect(first.wrappedValue == "second")
    #expect(second.wrappedValue == "second")
  }
}
