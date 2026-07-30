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

  private final class BlockingReadController: @unchecked Sendable {
    private let shouldBlock = OSAllocatedUnfairLock(initialState: false)
    let didStart = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)

    func blockNextRead() {
      shouldBlock.withLock { $0 = true }
    }

    func load(_ value: BlockingValue) -> BlockingValue {
      let shouldBlock = shouldBlock.withLock { shouldBlock in
        defer { shouldBlock = false }
        return shouldBlock
      }

      if shouldBlock {
        didStart.signal()
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
  func refreshesChangeMadeBetweenInitialReadAndObserverInstallation() {
    let key = makeTestKey()
    let userDefaults = makeTestUserDefaults()
    let userDefaultsReference = UserDefaultsReference(userDefaults)
    let initialValue = BlockingValue(rawValue: "initial")
    userDefaults.set(initialValue.rawValue, forKey: key)

    let controller = BlockingValue.readController
    controller.blockNextRead()

    let valueBox = ValueBox<GraphUserDefault<BlockingValue>>()
    let initializationFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      valueBox.store(
        GraphUserDefault(
          wrappedValue: initialValue,
          key,
          store: userDefaultsReference.value
        )
      )
      initializationFinished.signal()
    }

    #expect(controller.didStart.wait(timeout: .now() + 1) == .success)
    userDefaults.set("during-initialization", forKey: key)
    controller.resume.signal()

    #expect(initializationFinished.wait(timeout: .now() + 1) == .success)
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
