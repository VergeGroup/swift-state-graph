import Testing
import Foundation
@testable import StateGraph

@Suite
struct UserDefaultsStoredTests {
  
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
    defaultValue: T,
    name: String = "test_node"
  ) -> UserDefaultsStored<T> {
    let storage = UserDefaultsStorage(
      userDefaults: userDefaults,
      key: key,
      defaultValue: defaultValue
    )
    return _StoredNode(
      name: name,
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
      defaultValue: "default",
      name: "test_string"
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
      defaultValue: 42,
      name: "test_int"
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
      defaultValue: "initial",
      name: "test_external"
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
      defaultValue: "default",
      name: "node1"
    )
    
    let node2 = makeUserDefaultsStoredNode(
      userDefaults: userDefaults,
      key: key,
      defaultValue: "default",
      name: "node2"
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
      defaultValue: "default",
      name: "string"
    )
    
    let intNode = makeUserDefaultsStoredNode(
      userDefaults: userDefaults,
      key: "\(baseKey)_int",
      defaultValue: 0,
      name: "int"
    )
    
    let boolNode = makeUserDefaultsStoredNode(
      userDefaults: userDefaults,
      key: "\(baseKey)_bool",
      defaultValue: false,
      name: "bool"
    )
    
    let doubleNode = makeUserDefaultsStoredNode(
      userDefaults: userDefaults,
      key: "\(baseKey)_double",
      defaultValue: 0.0,
      name: "double"
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
  
  @Test
  func userDefaultsStored_cleanup_on_deinit() {
    let key = makeTestKey()
    let userDefaults = makeTestUserDefaults()
    
    var node: UserDefaultsStored<String>? = makeUserDefaultsStoredNode(
      userDefaults: userDefaults,
      key: key,
      defaultValue: "test",
      name: "cleanup_test"
    )
    
    weak var weakNode = node
    
    #expect(node!.wrappedValue == "test")
    
    node = nil
    
    #expect(weakNode == nil)
  }
} 
