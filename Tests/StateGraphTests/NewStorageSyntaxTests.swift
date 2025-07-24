import Testing
import Foundation
@testable import StateGraph

@Suite
struct NewStorageSyntaxTests {
  
  @Test("Can create Stored with memory marker")
  func testMemoryStorageCreation() {
    // Test creating with the new syntax
    let memoryStored = _Stored(storage: .memory, value: "Hello, World!")
    
    #expect(memoryStored.wrappedValue == "Hello, World!")
    
    // Test mutating the value
    memoryStored.wrappedValue = "Updated Value"
    #expect(memoryStored.wrappedValue == "Updated Value")
  }
  
  @Test("Can create Stored with userDefaults marker")
  func testUserDefaultsStorageCreation() {
    let key = "test_key_\(UUID().uuidString)"
    let userDefaults = UserDefaults.standard
    
    // Clear any existing value
    userDefaults.removeObject(forKey: key)
    
    // Test creating with the new syntax
    let defaultsStored = _Stored(storage: .userDefaults(key: key), value: "Default Value")
    
    #expect(defaultsStored.wrappedValue == "Default Value")
    
    // Test persistence
    defaultsStored.wrappedValue = "Persisted Value"
    #expect(userDefaults.string(forKey: key) == "Persisted Value")
    
    // Create another instance with the same key - should load persisted value
    let anotherStored = _Stored(storage: .userDefaults(key: key), value: "Another Default")
    #expect(anotherStored.wrappedValue == "Persisted Value")
    
    // Cleanup
    userDefaults.removeObject(forKey: key)
  }
  
  @Test("Can create Stored with custom suite")
  func testUserDefaultsWithSuite() {
    let suite = "com.test.suite"
    let key = "test_key_\(UUID().uuidString)"
    
    // Note: Creating a UserDefaults with a custom suite may not work in tests
    // but we can at least verify the syntax compiles
    let defaultsStored = _Stored(
      storage: .userDefaults(key: key, suite: suite),
      value: "Suite Value"
    )
    
    #expect(defaultsStored.wrappedValue == "Suite Value")
  }
  
  @Test("Type information is preserved")
  func testTypeInformation() {
    let memoryStored = _Stored(storage: .memory, value: 42)
    let defaultsStored = _Stored(storage: .userDefaults(key: "number_key"), value: 100)
    
    // These should have different types
    #expect(type(of: memoryStored) != type(of: defaultsStored) as Any.Type)
    
    // The storage types should be correct
    #expect(memoryStored is _Stored<Int, InMemoryStorage<Int>>)
    #expect(defaultsStored is _Stored<Int, UserDefaultsStorage<Int>>)
  }
  
  @Test("Works with Computed nodes")
  func testComputedCompatibility() {
    let stored = _Stored(storage: .memory, value: 10)
    let computed = Computed(stored)
    
    #expect(computed.wrappedValue == 10)
    
    stored.wrappedValue = 20
    #expect(computed.wrappedValue == 20)
  }
}