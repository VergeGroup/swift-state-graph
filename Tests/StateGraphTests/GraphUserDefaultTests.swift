import Foundation
import Testing
@testable import StateGraph

@Suite("@GraphUserDefault", .serialized)
struct GraphUserDefaultTests {

  private final class Counter: @unchecked Sendable {
    private let value = OSAllocatedUnfairLock(initialState: 0)

    var current: Int {
      value.withLock { $0 }
    }

    func increment() {
      value.withLock { $0 += 1 }
    }
  }

  private final class UserDefaultsReference: @unchecked Sendable {
    let value: UserDefaults

    init(_ value: UserDefaults) {
      self.value = value
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

  private final class WeakReference<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value?) {
      self.value = value
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

    func verifyConcurrentOperation(_ operation: @escaping @Sendable () -> Void) {
      let operationFinished = TestThreadSignal()
      Thread {
        operation()
        operationFinished.signal()
      }.start()

      let didComplete = operationFinished.wait(until: Date().addingTimeInterval(5))
      state.withLock {
        $0.didRun = true
        $0.concurrentOperationCompleted = didComplete
      }
    }
  }

  private final class BlockingReadController: @unchecked Sendable {
    /// One requested read suspension and the async signal that observes its entry, if any.
    private struct BlockRequest: Sendable {
      let startedSignal: TestSignal?
    }

    private let nextRequest = OSAllocatedUnfairLock<BlockRequest?>(initialState: nil)
    let didStart = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)

    func blockNextRead(started: TestSignal? = nil) {
      nextRequest.withLock { $0 = BlockRequest(startedSignal: started) }
    }

    func load(_ value: BlockingValue) -> BlockingValue {
      let request = nextRequest.withLock { request in
        defer { request = nil }
        return request
      }

      if let request {
        if let started = request.startedSignal {
          started.signal()
        } else {
          didStart.signal()
        }
        resume.wait()
      }

      return value
    }
  }

  private struct BlockingValue: Equatable, Sendable, UserDefaultsStorable {
    static let readController = BlockingReadController()

    let rawValue: String

    static func _getValue(
      from userDefaults: UserDefaults,
      forKey key: String,
      defaultValue: Self
    ) -> Self {
      readController.load(
        .init(rawValue: userDefaults.string(forKey: key) ?? defaultValue.rawValue)
      )
    }

    func _setValue(to userDefaults: UserDefaults, forKey key: String) {
      userDefaults.set(rawValue, forKey: key)
    }
  }

  private struct CodableValue: Codable, Equatable, Sendable, UserDefaultsStorable {
    var name: String
    var count: Int
  }

  private final class Model<Value: UserDefaultsStorable & SendableMetatype> {
    @GraphUserDefault var value: Value

    init(
      key: String,
      defaultValue: Value,
      userDefaults: UserDefaults
    ) {
      _value = GraphUserDefault(
        wrappedValue: defaultValue,
        key,
        store: userDefaults
      )
    }

    var projection: GraphUserDefault<Value> {
      $value
    }
  }

  private final class ReentrantModel {
    @GraphUserDefault var value: String
    var valueAfterNestedSet: String?

    init(
      key: String,
      userDefaults: UserDefaults
    ) {
      _value = GraphUserDefault(
        wrappedValue: "initial",
        key,
        store: userDefaults
      )

      $value.onDidSet { [weak self] _, newValue in
        guard let self, newValue == "first" else { return }
        value = "second"
        valueAfterNestedSet = $value.wrappedValue
      }
    }
  }

  private func makeTestKey() -> String {
    "GraphUserDefaultTests.\(UUID().uuidString)"
  }

  private func makeTestUserDefaults() -> UserDefaults {
    let suiteName = "GraphUserDefaultTests.\(UUID().uuidString)"
    let userDefaults = UserDefaults(suiteName: suiteName)!
    userDefaults.removePersistentDomain(forName: suiteName)
    return userDefaults
  }

  private func expectRoundTrip<Value: UserDefaultsStorable & SendableMetatype>(
    _ value: Value,
    defaultValue: Value,
    storedValue: (UserDefaults, String) -> Value?,
    sourceLocation: Testing.SourceLocation = #_sourceLocation
  ) {
    let key = makeTestKey()
    let userDefaults = makeTestUserDefaults()
    let writer = GraphUserDefault(wrappedValue: defaultValue, key, store: userDefaults)

    writer.wrappedValue = value

    let restored = GraphUserDefault(wrappedValue: defaultValue, key, store: userDefaults)
    #expect(writer.wrappedValue == value, sourceLocation: sourceLocation)
    #expect(restored.wrappedValue == value, sourceLocation: sourceLocation)
    #expect(storedValue(userDefaults, key) == value, sourceLocation: sourceLocation)
  }

  private func expectOptionalRoundTrip<Wrapped: UserDefaultsStorable & SendableMetatype>(
    _ value: Wrapped,
    storedValue: (UserDefaults, String) -> Wrapped?,
    sourceLocation: Testing.SourceLocation = #_sourceLocation
  ) {
    let key = makeTestKey()
    let userDefaults = makeTestUserDefaults()
    let writer = GraphUserDefault<Wrapped?>(wrappedValue: nil, key, store: userDefaults)

    writer.wrappedValue = value

    let restored = GraphUserDefault<Wrapped?>(wrappedValue: nil, key, store: userDefaults)
    #expect(writer.wrappedValue == value, sourceLocation: sourceLocation)
    #expect(restored.wrappedValue == value, sourceLocation: sourceLocation)
    #expect(storedValue(userDefaults, key) == value, sourceLocation: sourceLocation)

    writer.wrappedValue = nil

    let restoredAfterRemoval = GraphUserDefault<Wrapped?>(
      wrappedValue: nil,
      key,
      store: userDefaults
    )
    #expect(writer.wrappedValue == nil, sourceLocation: sourceLocation)
    #expect(restoredAfterRemoval.wrappedValue == nil, sourceLocation: sourceLocation)
    #expect(userDefaults.object(forKey: key) == nil, sourceLocation: sourceLocation)
  }

  private static func decodedCodableValue(
    from userDefaults: UserDefaults,
    forKey key: String
  ) -> CodableValue? {
    userDefaults.data(forKey: key).flatMap {
      try? JSONDecoder().decode(CodableValue.self, from: $0)
    }
  }

  @Test
  func projectionSharesIdentityAndPersistsWrites() {
    let key = makeTestKey()
    let userDefaults = makeTestUserDefaults()
    let value = GraphUserDefault(
      wrappedValue: "default",
      key,
      store: userDefaults
    )
    let projection: GraphUserDefault<String> = value.projectedValue

    #expect(value.wrappedValue == "default")
    #expect(projection === value)
    #expect(projection.wrappedValue == "default")

    projection.wrappedValue = "updated"

    #expect(value.wrappedValue == "updated")
    #expect(userDefaults.string(forKey: key) == "updated")
  }

  @Test
  func retainedProjectionKeepsUserDefaultsSynchronizationAlive() {
    let key = makeTestKey()
    let userDefaults = makeTestUserDefaults()
    var model: Model<String>? = Model(
      key: key,
      defaultValue: "initial",
      userDefaults: userDefaults
    )
    let projection = model!.projection

    model = nil

    userDefaults.set("external", forKey: key)
    NotificationCenter.default.post(
      name: UserDefaults.didChangeNotification,
      object: userDefaults
    )

    #expect(projection.wrappedValue == "external")

    projection.wrappedValue = "projected"
    #expect(userDefaults.string(forKey: key) == "projected")
  }

  @Test
  func supportsNamedSuite() {
    let suiteName = "GraphUserDefaultTests.\(UUID().uuidString)"
    defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

    let value = GraphUserDefault(
      wrappedValue: 42,
      "answer",
      suiteName: suiteName
    )

    value.wrappedValue = 100

    #expect(value.wrappedValue == 100)
    #expect(UserDefaults(suiteName: suiteName)?.integer(forKey: "answer") == 100)
  }

  @Test
  func supportsPrimitiveAndOptionalValues() {
    let userDefaults = makeTestUserDefaults()
    let baseKey = makeTestKey()
    let integer = GraphUserDefault(wrappedValue: 0, "\(baseKey).int", store: userDefaults)
    let boolean = GraphUserDefault(wrappedValue: false, "\(baseKey).bool", store: userDefaults)
    let double = GraphUserDefault(wrappedValue: 0.0, "\(baseKey).double", store: userDefaults)
    let optional = GraphUserDefault<String?>(
      wrappedValue: nil,
      "\(baseKey).optional",
      store: userDefaults
    )

    integer.wrappedValue = 42
    boolean.wrappedValue = true
    double.wrappedValue = 3.14
    optional.wrappedValue = "value"

    #expect(integer.wrappedValue == 42)
    #expect(boolean.wrappedValue)
    #expect(double.wrappedValue == 3.14)
    #expect(optional.wrappedValue == "value")

    optional.wrappedValue = nil
    #expect(userDefaults.object(forKey: "\(baseKey).optional") == nil)
  }

  @Test
  func codableValueRoundTripsThroughDefaultImplementation() {
    let key = makeTestKey()
    let userDefaults = makeTestUserDefaults()
    let value = GraphUserDefault(
      wrappedValue: CodableValue(name: "default", count: 0),
      key,
      store: userDefaults
    )

    value.wrappedValue = CodableValue(name: "saved", count: 42)

    let restored = GraphUserDefault(
      wrappedValue: CodableValue(name: "fallback", count: -1),
      key,
      store: userDefaults
    )
    #expect(restored.wrappedValue == CodableValue(name: "saved", count: 42))
  }

  @Test
  func optionalCodableValueRoundTripsAndNilRemovesKey() {
    expectOptionalRoundTrip(
      CodableValue(name: "saved", count: 42),
      storedValue: Self.decodedCodableValue
    )
  }

  @Test
  func optionalURLRoundTripsAndNilRemovesKey() {
    // UserDefaults archives a web URL as Data but stores a file URL as its path string.
    expectOptionalRoundTrip(URL(string: "https://example.com/path?query=1")!) {
      $0.url(forKey: $1)
    }
    expectOptionalRoundTrip(URL(fileURLWithPath: "/path/to/file.txt")) {
      $0.url(forKey: $1)
    }
  }

  @Test
  func supportedValuesRoundTripInFoundationRepresentation() {
    expectRoundTrip(true, defaultValue: false) { $0.object(forKey: $1) as? Bool }
    expectRoundTrip(42, defaultValue: 0) { $0.object(forKey: $1) as? Int }
    expectRoundTrip(Float(1.5), defaultValue: 0) { $0.object(forKey: $1) as? Float }
    expectRoundTrip(3.14, defaultValue: 0) { $0.object(forKey: $1) as? Double }
    expectRoundTrip("value", defaultValue: "default") { $0.string(forKey: $1) }
    expectRoundTrip(Data([0x01, 0x02]), defaultValue: Data()) { $0.data(forKey: $1) }
    expectRoundTrip(
      Date(timeIntervalSince1970: 1_700_000_000),
      defaultValue: Date(timeIntervalSince1970: 0)
    ) { $0.object(forKey: $1) as? Date }
    expectRoundTrip(
      URL(string: "https://example.com/path")!,
      defaultValue: URL(string: "https://example.com/default")!
    ) { $0.url(forKey: $1) }
    expectRoundTrip(
      CodableValue(name: "saved", count: 42),
      defaultValue: CodableValue(name: "default", count: 0),
      storedValue: Self.decodedCodableValue
    )
  }

  @Test
  func optionalPropertyListValuesRoundTripAndNilRemovesKey() {
    expectOptionalRoundTrip(true) { $0.object(forKey: $1) as? Bool }
    expectOptionalRoundTrip(42) { $0.object(forKey: $1) as? Int }
    expectOptionalRoundTrip(Float(1.5)) { $0.object(forKey: $1) as? Float }
    expectOptionalRoundTrip(3.14) { $0.object(forKey: $1) as? Double }
    expectOptionalRoundTrip("value") { $0.string(forKey: $1) }
    expectOptionalRoundTrip(Data([0x01, 0x02])) { $0.data(forKey: $1) }
    expectOptionalRoundTrip(Date(timeIntervalSince1970: 1_700_000_000)) {
      $0.object(forKey: $1) as? Date
    }
  }

  @Test
  func optionalValueUsesDefaultWithoutRestorableWrappedValue() {
    let userDefaults = makeTestUserDefaults()
    let unreadableKey = makeTestKey()
    userDefaults.set(Data("not json".utf8), forKey: unreadableKey)
    let fallback = CodableValue(name: "fallback", count: -1)

    let absent = GraphUserDefault<CodableValue?>(
      wrappedValue: fallback,
      makeTestKey(),
      store: userDefaults
    )
    let unreadable = GraphUserDefault<CodableValue?>(
      wrappedValue: fallback,
      unreadableKey,
      store: userDefaults
    )

    #expect(absent.wrappedValue == fallback)
    #expect(unreadable.wrappedValue == fallback)
  }

  @Test
  func localWritePublishesSynchronouslyAndSuppressesNotificationEcho() {
    let key = makeTestKey()
    let userDefaults = makeTestUserDefaults()
    let value = GraphUserDefault(
      wrappedValue: "initial",
      key,
      store: userDefaults
    )
    let counter = Counter()
    value.projectedValue.onDidSet { _, _ in counter.increment() }

    value.wrappedValue = "local"

    #expect(value.projectedValue.wrappedValue == "local")
    #expect(counter.current == 1)

    NotificationCenter.default.post(
      name: UserDefaults.didChangeNotification,
      object: userDefaults
    )

    #expect(counter.current == 1)
  }

  @Test
  func externalWritePublishesOnlyOnceForDuplicateNotifications() {
    let key = makeTestKey()
    let userDefaults = makeTestUserDefaults()
    let value = GraphUserDefault(
      wrappedValue: "initial",
      key,
      store: userDefaults
    )
    let counter = Counter()
    value.projectedValue.onDidSet { _, _ in counter.increment() }

    userDefaults.set("external", forKey: key)
    NotificationCenter.default.post(
      name: UserDefaults.didChangeNotification,
      object: userDefaults
    )
    NotificationCenter.default.post(
      name: UserDefaults.didChangeNotification,
      object: userDefaults
    )

    #expect(value.wrappedValue == "external")
    #expect(counter.current == 1)
  }

  @Test
  func multipleInstancesForSameKeyConverge() {
    let key = makeTestKey()
    let userDefaults = makeTestUserDefaults()
    let first = GraphUserDefault(
      wrappedValue: "initial",
      key,
      store: userDefaults
    )
    let second = GraphUserDefault(
      wrappedValue: "initial",
      key,
      store: userDefaults
    )

    first.wrappedValue = "shared"
    NotificationCenter.default.post(
      name: UserDefaults.didChangeNotification,
      object: userDefaults
    )

    #expect(first.wrappedValue == "shared")
    #expect(second.wrappedValue == "shared")
  }

  @Test
  func externalWriteInvalidatesGraphDependencies() async {
    let key = makeTestKey()
    let userDefaults = makeTestUserDefaults()
    let value = GraphUserDefault(
      wrappedValue: "initial",
      key,
      store: userDefaults
    )
    let projection = value.projectedValue
    let computed = Computed<String>(name: "dependent") { _ in
      "computed_\(projection.wrappedValue)"
    }

    #expect(computed.wrappedValue == "computed_initial")

    await confirmation(expectedCount: 1) { confirmation in
      withStateGraphTracking {
        _ = computed.wrappedValue
      } didChange: {
        #expect(computed.wrappedValue == "computed_external")
        confirmation.confirm()
      }

      userDefaults.set("external", forKey: key)
      NotificationCenter.default.post(
        name: UserDefaults.didChangeNotification,
        object: userDefaults
      )

      try? await Task.sleep(for: .milliseconds(20))
    }
  }

  @Test
  func refreshesChangeMadeBetweenInitialReadAndObserverInstallation() async {
    let key = makeTestKey()
    let userDefaults = makeTestUserDefaults()
    let userDefaultsReference = UserDefaultsReference(userDefaults)
    let initialValue = BlockingValue(rawValue: "initial")
    userDefaults.set(initialValue.rawValue, forKey: key)

    let controller = BlockingValue.readController
    let initialReadStarted = TestSignal()
    controller.blockNextRead(started: initialReadStarted)

    let valueBox = ValueBox<GraphUserDefault<BlockingValue>>()
    let initializationFinished = TestSignal()
    Thread {
      valueBox.store(
        GraphUserDefault(
          wrappedValue: initialValue,
          key,
          store: userDefaultsReference.value
        )
      )
      initializationFinished.signal()
    }.start()

    #expect(await initialReadStarted.wait(for: .seconds(5)))
    userDefaultsReference.value.set("during-initialization", forKey: key)
    controller.resume.signal()

    #expect(await initializationFinished.wait(for: .seconds(5)))
    #expect(valueBox.current?.wrappedValue == .init(rawValue: "during-initialization"))
  }

  @Test
  func serializesNotificationReadWithLocalWrite() {
    let key = makeTestKey()
    let userDefaults = makeTestUserDefaults()
    let userDefaultsReference = UserDefaultsReference(userDefaults)
    let initialValue = BlockingValue(rawValue: "persisted")
    userDefaults.set(initialValue.rawValue, forKey: key)
    let value = GraphUserDefault(
      wrappedValue: initialValue,
      key,
      store: userDefaults
    )

    let controller = BlockingValue.readController
    controller.blockNextRead()

    let notificationFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      NotificationCenter.default.post(
        name: UserDefaults.didChangeNotification,
        object: userDefaultsReference.value
      )
      notificationFinished.signal()
    }

    #expect(controller.didStart.wait(timeout: .now() + 1) == .success)

    let setterStarted = DispatchSemaphore(value: 0)
    let setterFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      setterStarted.signal()
      value.wrappedValue = .init(rawValue: "local")
      setterFinished.signal()
    }

    #expect(setterStarted.wait(timeout: .now() + 1) == .success)
    #expect(setterFinished.wait(timeout: .now() + 0.05) == .timedOut)

    controller.resume.signal()

    #expect(notificationFinished.wait(timeout: .now() + 1) == .success)
    #expect(setterFinished.wait(timeout: .now() + 1) == .success)
    #expect(value.wrappedValue == .init(rawValue: "local"))
  }

  @Test
  func publicationRunsAfterCoordinatorUnlocks() {
    let key = makeTestKey()
    let userDefaults = makeTestUserDefaults()
    let observed = GraphUserDefault(
      wrappedValue: "initial",
      key,
      store: userDefaults
    )
    let concurrent = GraphUserDefault(
      wrappedValue: "initial",
      "\(key).concurrent",
      store: userDefaults
    )
    let probe = PublicationLockProbe()

    observed.projectedValue.onDidSet { _, _ in
      probe.verifyConcurrentOperation {
        // Exercise the Foundation coordinator without creating a second
        // publication that must be ordered after this callback.
        concurrent.wrappedValue = "initial"
      }
    }

    userDefaults.set("external", forKey: key)
    NotificationCenter.default.post(
      name: UserDefaults.didChangeNotification,
      object: userDefaults
    )

    let result = probe.result
    #expect(result.didRun)
    #expect(result.concurrentOperationCompleted)
  }

  @Test
  func concurrentSetterWaitsForItsSynchronousPublication() {
    let key = makeTestKey()
    let userDefaults = makeTestUserDefaults()
    let userDefaultsReference = UserDefaultsReference(userDefaults)
    let blocking = GraphUserDefault(
      wrappedValue: "initial",
      key,
      store: userDefaults
    )
    let concurrent = GraphUserDefault(
      wrappedValue: "initial",
      "\(key).concurrent",
      store: userDefaults
    )

    let publicationStarted = DispatchSemaphore(value: 0)
    let resumePublication = DispatchSemaphore(value: 0)
    blocking.projectedValue.onDidSet { _, _ in
      publicationStarted.signal()
      resumePublication.wait()
    }

    let notificationFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      userDefaultsReference.value.set("external", forKey: key)
      NotificationCenter.default.post(
        name: UserDefaults.didChangeNotification,
        object: userDefaultsReference.value
      )
      notificationFinished.signal()
    }

    #expect(publicationStarted.wait(timeout: .now() + 1) == .success)

    let setterFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      concurrent.wrappedValue = "updated"
      setterFinished.signal()
    }

    #expect(setterFinished.wait(timeout: .now() + 0.05) == .timedOut)

    resumePublication.signal()

    #expect(setterFinished.wait(timeout: .now() + 1) == .success)
    #expect(concurrent.projectedValue.wrappedValue == "updated")
    #expect(notificationFinished.wait(timeout: .now() + 1) == .success)
  }

  @Test
  func reentrantSetterPublishesBeforeReturningToCallback() {
    let model = ReentrantModel(
      key: makeTestKey(),
      userDefaults: makeTestUserDefaults()
    )

    model.value = "first"

    #expect(model.valueAfterNestedSet == "second")
    #expect(model.value == "second")
  }

  @Test
  func publicationRunsAfterStoredNodeUnlocks() {
    let key = makeTestKey()
    let userDefaults = makeTestUserDefaults()
    let value = GraphUserDefault(
      wrappedValue: "initial",
      key,
      store: userDefaults
    )
    let projection = value.projectedValue
    let probe = PublicationLockProbe()

    projection.onDidSet { _, _ in
      probe.verifyConcurrentOperation {
        _ = projection.wrappedValue
      }
    }

    value.wrappedValue = "updated"

    let result = probe.result
    #expect(result.didRun)
    #expect(result.concurrentOperationCompleted)
  }

  @Test
  func inFlightNotificationKeepsProjectionAliveUntilCallbackFinishes() {
    let key = makeTestKey()
    let userDefaults = makeTestUserDefaults()
    let userDefaultsReference = UserDefaultsReference(userDefaults)
    var model: Model<BlockingValue>? = Model(
      key: key,
      defaultValue: .init(rawValue: "initial"),
      userDefaults: userDefaults
    )
    let projection = WeakReference(model?.projection)

    userDefaults.set("external", forKey: key)
    let controller = BlockingValue.readController
    controller.blockNextRead()

    let notificationFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      NotificationCenter.default.post(
        name: UserDefaults.didChangeNotification,
        object: userDefaultsReference.value
      )
      notificationFinished.signal()
    }

    #expect(controller.didStart.wait(timeout: .now() + 1) == .success)

    model = nil
    #expect(projection.value != nil)

    controller.resume.signal()
    #expect(notificationFinished.wait(timeout: .now() + 1) == .success)

    #expect(projection.value == nil)
  }
}
