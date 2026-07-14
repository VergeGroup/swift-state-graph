import Testing
import Foundation
@testable import StateGraph

@Suite
struct UserDefaultsStoredTests {

  private final class NotificationCounter: @unchecked Sendable {
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

  private final class PublicationLockProbe: @unchecked Sendable {
    private struct State {
      var didRun = false
      var concurrentReadCompleted = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var result: (didRun: Bool, concurrentReadCompleted: Bool) {
      state.withLock { ($0.didRun, $0.concurrentReadCompleted) }
    }

    func verifyConcurrentOperation(_ operation: @escaping @Sendable () -> Void) {
      let readFinished = DispatchSemaphore(value: 0)
      DispatchQueue.global().async {
        operation()
        readFinished.signal()
      }

      let didComplete = readFinished.wait(timeout: .now() + 1) == .success
      state.withLock {
        $0.didRun = true
        $0.concurrentReadCompleted = didComplete
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

    func load(_ value: BlockingUserDefaultsValue) -> BlockingUserDefaultsValue {
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

  private struct BlockingUserDefaultsValue: Equatable, Sendable, UserDefaultsStorable {
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
  
  // テスト用のユニークなキーを生成するヘルパー
  private func makeTestKey() -> String {
    return "test_key_\(UUID().uuidString)"
  }
  
  // テスト用のUserDefaultsスイートを作成するヘルパー
  private func makeTestUserDefaults() -> UserDefaults {
    let suiteName = "test_suite_\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
  }
  
  // UserDefaultsStoredノードを作成するヘルパー
  private func makeUserDefaultsStoredNode<T: UserDefaultsStorable>(
    userDefaults: UserDefaults,
    key: String,
    defaultValue: T
  ) -> UserDefaultsStored<T> {
    let storage = UserDefaultsStorage(
      userDefaults: userDefaults,
      key: key,
      defaultValue: defaultValue
    )
    return _Stored(
      storage: storage
    )
  }

  @Test
  func userDefaultsStored_basic_functionality() {
    let key = makeTestKey()
    let userDefaults = makeTestUserDefaults()
    
    let node = makeUserDefaultsStoredNode(
      userDefaults: userDefaults,
      key: key,
      defaultValue: "default"
    )
    
    // 初期値のテスト
    #expect(node.wrappedValue == "default")
    
    // 値の設定と取得のテスト
    node.wrappedValue = "updated"
    #expect(node.wrappedValue == "updated")
    #expect(userDefaults.string(forKey: key) == "updated")
  }
  
  @Test
  func userDefaultsStored_with_suite() {
    let key = makeTestKey()
    let userDefaults = makeTestUserDefaults()
    
    let node = makeUserDefaultsStoredNode(
      userDefaults: userDefaults,
      key: key,
      defaultValue: 42
    )
    
    // 初期値のテスト
    #expect(node.wrappedValue == 42)
    
    // 値の設定と取得のテスト
    node.wrappedValue = 100
    #expect(node.wrappedValue == 100)
    #expect(userDefaults.integer(forKey: key) == 100)
  }
  
  @Test
  func userDefaultsStored_external_updates_trigger_notifications() async {
    let key = makeTestKey()
    let userDefaults = makeTestUserDefaults()
    
    let node = makeUserDefaultsStoredNode(
      userDefaults: userDefaults,
      key: key,
      defaultValue: "initial"
    )
    
    // 依存するComputedノードを作成
    let computedNode = Computed<String>(name: "dependent") { _ in
      return "computed_\(node.wrappedValue)"
    }
    
    // 初期値の確認
    #expect(computedNode.wrappedValue == "computed_initial")
    
    await confirmation(expectedCount: 1) { confirmation in
      // グラフの変更を追跡
      withStateGraphTracking {
        _ = computedNode.wrappedValue
      } didChange: {
        #expect(computedNode.wrappedValue == "computed_external_update")
        confirmation.confirm()
      }
      
      // UserDefaultsを外部から直接更新
      userDefaults.set("external_update", forKey: key)
            
      try? await Task.sleep(for: .milliseconds(100))
    }
  }
  
  @Test
  func userDefaultsStored_multiple_nodes_same_key() async {
    let key = makeTestKey()
    let userDefaults = makeTestUserDefaults()
    
    // 同じキーで複数のノードを作成
    let node1 = makeUserDefaultsStoredNode(
      userDefaults: userDefaults,
      key: key,
      defaultValue: "default"
    )
    
    let node2 = makeUserDefaultsStoredNode(
      userDefaults: userDefaults,
      key: key,
      defaultValue: "default"
    )
    
    // 初期値の確認
    #expect(node1.wrappedValue == "default")
    #expect(node2.wrappedValue == "default")
    
    await confirmation(expectedCount: 2) { confirmation in
      // 両方のノードの変更を追跡
      withStateGraphTracking {
        _ = node1.wrappedValue
      } didChange: {
        #expect(node1.wrappedValue == "shared_update")
        confirmation.confirm()
      }
      
      withStateGraphTracking {
        _ = node2.wrappedValue
      } didChange: {
        #expect(node2.wrappedValue == "shared_update")
        confirmation.confirm()
      }
      
      // UserDefaultsを外部から更新
      userDefaults.set("shared_update", forKey: key)
      NotificationCenter.default.post(
        name: UserDefaults.didChangeNotification,
        object: userDefaults
      )
      
      try? await Task.sleep(for: .milliseconds(100))
    }
  }
  
  @Test
  func userDefaultsStored_different_types() {
    let baseKey = makeTestKey()
    let userDefaults = makeTestUserDefaults()
    
    // 異なる型のテスト
    let stringNode = makeUserDefaultsStoredNode(
      userDefaults: userDefaults,
      key: "\(baseKey)_string",
      defaultValue: "default"
    )
    
    let intNode = makeUserDefaultsStoredNode(
      userDefaults: userDefaults,
      key: "\(baseKey)_int",
      defaultValue: 0
    )
    
    let boolNode = makeUserDefaultsStoredNode(
      userDefaults: userDefaults,
      key: "\(baseKey)_bool",
      defaultValue: false
    )
    
    let doubleNode = makeUserDefaultsStoredNode(
      userDefaults: userDefaults,
      key: "\(baseKey)_double",
      defaultValue: 0.0
    )
    
    // 初期値のテスト
    #expect(stringNode.wrappedValue == "default")
    #expect(intNode.wrappedValue == 0)
    #expect(boolNode.wrappedValue == false)
    #expect(doubleNode.wrappedValue == 0.0)
    
    // 値の設定と取得のテスト
    stringNode.wrappedValue = "test"
    intNode.wrappedValue = 42
    boolNode.wrappedValue = true
    doubleNode.wrappedValue = 3.14
    
    #expect(stringNode.wrappedValue == "test")
    #expect(intNode.wrappedValue == 42)
    #expect(boolNode.wrappedValue == true)
    #expect(doubleNode.wrappedValue == 3.14)
    
    // UserDefaultsに直接保存されているかの確認
    #expect(userDefaults.string(forKey: "\(baseKey)_string") == "test")
    #expect(userDefaults.integer(forKey: "\(baseKey)_int") == 42)
    #expect(userDefaults.bool(forKey: "\(baseKey)_bool") == true)
    #expect(userDefaults.double(forKey: "\(baseKey)_double") == 3.14)
  }
  
  @MainActor
  @Test  
  func userDefaultsStored_cleanup_on_deinit() async {
    
    let key = makeTestKey()
    let userDefaults = makeTestUserDefaults()
    
    var node: UserDefaultsStored<String>? = makeUserDefaultsStoredNode(
      userDefaults: userDefaults,
      key: key,
      defaultValue: "test"
    )
    
    weak var weakNode = node
    
    #expect(node!.wrappedValue == "test")
    
    node = nil
    
    await Task.yield()
    
    if weakNode != nil {
      print("")
    }
    
    try? await Task.sleep(for: .milliseconds(100))
    
    #expect(weakNode == nil)
    

  }

  @Test
  func userDefaultsStorage_suppressesLocalWriteNotification() async throws {
    let key = makeTestKey()
    let userDefaults = makeTestUserDefaults()
    let counter = NotificationCounter()
    let storage = UserDefaultsStorage(
      userDefaults: userDefaults,
      key: key,
      defaultValue: "initial"
    )
    storage.loaded(context: .init(onStorageUpdated: counter.increment))
    defer { storage.unloaded() }

    storage.value = "local"
    NotificationCenter.default.post(
      name: UserDefaults.didChangeNotification,
      object: userDefaults
    )
    try await Task.sleep(for: .milliseconds(50))

    #expect(storage.value == "local")
    #expect(counter.current == 0)
  }

  @Test
  func userDefaultsStorage_publishesExternalWriteOnce() async throws {
    let key = makeTestKey()
    let userDefaults = makeTestUserDefaults()
    let counter = NotificationCounter()
    let storage = UserDefaultsStorage(
      userDefaults: userDefaults,
      key: key,
      defaultValue: "initial"
    )
    storage.loaded(context: .init(onStorageUpdated: counter.increment))
    defer { storage.unloaded() }

    userDefaults.set("external", forKey: key)
    NotificationCenter.default.post(
      name: UserDefaults.didChangeNotification,
      object: userDefaults
    )
    NotificationCenter.default.post(
      name: UserDefaults.didChangeNotification,
      object: userDefaults
    )
    try await Task.sleep(for: .milliseconds(50))

    #expect(storage.value == "external")
    #expect(counter.current == 1)
  }

  @Test
  func userDefaultsStorage_doesNotPublishAfterUnload() async throws {
    let key = makeTestKey()
    let userDefaults = makeTestUserDefaults()
    let counter = NotificationCounter()
    let storage = UserDefaultsStorage(
      userDefaults: userDefaults,
      key: key,
      defaultValue: "initial"
    )
    storage.loaded(context: .init(onStorageUpdated: counter.increment))
    storage.unloaded()

    userDefaults.set("external", forKey: key)
    NotificationCenter.default.post(
      name: UserDefaults.didChangeNotification,
      object: userDefaults
    )
    try await Task.sleep(for: .milliseconds(50))

    #expect(counter.current == 0)
  }

  @Test
  func userDefaultsStorage_serializesNotificationReadWithLocalWrite() {
    let key = makeTestKey()
    let userDefaults = makeTestUserDefaults()
    let counter = NotificationCounter()
    let initialValue = BlockingUserDefaultsValue(rawValue: "persisted")
    userDefaults.set(initialValue.rawValue, forKey: key)

    let storage = UserDefaultsStorage(
      userDefaults: userDefaults,
      key: key,
      defaultValue: initialValue
    )
    storage.loaded(context: .init(onStorageUpdated: counter.increment))
    defer { storage.unloaded() }

    let controller = BlockingUserDefaultsValue.readController
    controller.blockNextRead()

    let notificationFinished = DispatchSemaphore(value: 0)
    let userDefaultsReference = UserDefaultsReference(userDefaults)
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
      storage.value = .init(rawValue: "local")
      setterFinished.signal()
    }

    #expect(setterStarted.wait(timeout: .now() + 1) == .success)
    #expect(setterFinished.wait(timeout: .now() + 0.05) == .timedOut)

    controller.resume.signal()

    #expect(notificationFinished.wait(timeout: .now() + 1) == .success)
    #expect(setterFinished.wait(timeout: .now() + 1) == .success)
    #expect(storage.value == .init(rawValue: "local"))
    #expect(counter.current == 0)
  }

  @Test
  func userDefaultsStorage_publishesAfterCoordinatorUnlocks() {
    let key = makeTestKey()
    let userDefaults = makeTestUserDefaults()
    let writer = UserDefaultsStorage(
      userDefaults: userDefaults,
      key: key,
      defaultValue: "initial"
    )
    let observer = UserDefaultsStorage(
      userDefaults: userDefaults,
      key: key,
      defaultValue: "initial"
    )
    let probe = PublicationLockProbe()

    writer.loaded(context: .init(onStorageUpdated: {}))
    observer.loaded(
      context: .init {
        probe.verifyConcurrentOperation {
          _ = writer.value
        }
      }
    )
    defer {
      writer.unloaded()
      observer.unloaded()
    }

    writer.value = "updated"

    let result = probe.result
    #expect(result.didRun)
    #expect(result.concurrentReadCompleted)
  }

  @Test
  func userDefaultsStored_publishesAfterSourceNodeUnlocks() {
    let key = makeTestKey()
    let userDefaults = makeTestUserDefaults()
    let writer = makeUserDefaultsStoredNode(
      userDefaults: userDefaults,
      key: key,
      defaultValue: "initial"
    )
    let observer = UserDefaultsStorage(
      userDefaults: userDefaults,
      key: key,
      defaultValue: "initial"
    )
    let probe = PublicationLockProbe()

    observer.loaded(
      context: .init {
        probe.verifyConcurrentOperation {
          _ = writer.wrappedValue
        }
      }
    )
    defer { observer.unloaded() }

    writer.wrappedValue = "updated"

    let result = probe.result
    #expect(result.didRun)
    #expect(result.concurrentReadCompleted)
  }
  
  
} 
