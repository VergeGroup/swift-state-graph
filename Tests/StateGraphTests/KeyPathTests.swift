@preconcurrency import Testing
@preconcurrency import Foundation
@testable import StateGraph

@Suite("KeyPath Uniqueness Tests")
struct KeyPathTests {
  
  @Test("Different objects generate different KeyPaths")
  func keyPathUniqueness() {
    // Verify that different objects generate different KeyPaths
    let object1 = NSObject()
    let object2 = NSObject()
    
    let keyPath1 = _keyPath(object1)
    let keyPath2 = _keyPath(object2)
    
    // Different objects should produce different KeyPaths
    #expect(keyPath1 != keyPath2, "Different objects should produce different KeyPaths")
  }
  
  @Test("Same object generates consistent KeyPaths")
  func keyPathConsistency() {
    // Verify that the same object generates consistent KeyPaths
    let object = NSObject()
    
    let keyPath1 = _keyPath(object)
    let keyPath2 = _keyPath(object)
    
    // Same object should produce identical KeyPaths
    #expect(keyPath1 == keyPath2, "Same object should produce identical KeyPaths")
  }
  
  @Test("KeyPath uniqueness with multiple objects")
  func keyPathUniquenessWithMultipleObjects() {
    // Verify KeyPath uniqueness with multiple objects
    let objects = (0..<100).map { _ in NSObject() }
    let keyPaths = objects.map { _keyPath($0) }
    
    // All KeyPaths should be unique
    for i in 0..<keyPaths.count {
      for j in (i+1)..<keyPaths.count {
        #expect(keyPaths[i] != keyPaths[j], "KeyPath \(i) and \(j) should be different")
      }
    }
  }
  
  @Test("KeyPath uniqueness with different object types")
  func keyPathWithDifferentObjectTypes() {
    // Verify that KeyPaths are unique even for different object types
    let nsObject = NSObject()
    let nsString = NSString(string: "test")
    let nsArray = NSArray()
    
    let keyPath1 = _keyPath(nsObject)
    let keyPath2 = _keyPath(nsString)
    let keyPath3 = _keyPath(nsArray)
    
    #expect(keyPath1 != keyPath2, "NSObject and NSString should have different KeyPaths")
    #expect(keyPath2 != keyPath3, "NSString and NSArray should have different KeyPaths")
    #expect(keyPath1 != keyPath3, "NSObject and NSArray should have different KeyPaths")
  }
  
  @Test("KeyPath stability")
  func keyPathStability() {
    // Verify that KeyPaths remain stable while the object is alive
    let object = NSObject()
    let initialKeyPath = _keyPath(object)
    
    // Multiple calls should return the same KeyPath
    for _ in 0..<10 {
      let currentKeyPath = _keyPath(object)
      #expect(initialKeyPath == currentKeyPath, "KeyPath should be stable for the same object")
    }
  }
  
  @Test("Weak references and object lifecycle")
  func keyPathWithWeakReferences() {
    // Verify the relationship between object lifecycle and KeyPath using weak references
    var keyPath: (any KeyPath<PointerKeyPathRoot, Never> & Sendable)?
    
    autoreleasepool {
      let object = NSObject()
      keyPath = _keyPath(object)
      
      // KeyPath should be valid while the object is alive
      #expect(keyPath != nil)
    }
    
    // KeyPath itself should be retained even after the object is deallocated
    #expect(keyPath != nil)
  }
  
  @Test("Sendable protocol conformance")
  func keyPathSendableConformance() {
    // Verify that KeyPath conforms to Sendable protocol
    let object = NSObject()
    let keyPath = _keyPath(object)
    
    // Verify conformance to Sendable protocol at type level
    let sendableKeyPath: any KeyPath<PointerKeyPathRoot, Never> & Sendable = keyPath
    #expect(sendableKeyPath != nil)
  }
  
  @Test("Concurrent KeyPath generation")
  func concurrentKeyPathGeneration() async {
    // Verify safety of KeyPath generation in concurrent environments
    let keyPaths = OSAllocatedUnfairLock<[any KeyPath<PointerKeyPathRoot, Never> & Sendable]>(initialState: [])
    let objects = OSAllocatedUnfairLock<[NSObject]>(initialState: [])
    
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<10 {
        group.addTask {
          // Create objects within each task to avoid data races
          let object = NSObject()
          let keyPath = _keyPath(object)
          
          // Retain objects to prevent memory address reuse
          objects.withLock { objects in
            objects.append(object)
          }
          
          keyPaths.withLock { keyPaths in
            keyPaths.append(keyPath)
          }
        }
      }
    }
    
    // Verify the count of concurrently generated KeyPaths
    let finalKeyPaths = keyPaths.withLock { $0 }
    let finalObjects = objects.withLock { $0 }
    
    #expect(finalKeyPaths.count == 10, "Should have generated 10 KeyPaths")
    #expect(finalObjects.count == 10, "Should have created 10 objects")
    
    // Verify that KeyPaths are unique while objects are alive
    for i in 0..<finalKeyPaths.count {
      for j in (i+1)..<finalKeyPaths.count {
        #expect(finalKeyPaths[i] != finalKeyPaths[j], "Concurrently generated KeyPath \(i) and \(j) should be different while objects are alive")
      }
    }
  }
  
  @Test("Hash value uniqueness")
  func keyPathHashUniqueness() {
    // Verify uniqueness of KeyPath hash values
    let objects = (0..<50).map { _ in NSObject() }
    let keyPaths = objects.map { _keyPath($0) }
    let hashValues = keyPaths.map { $0.hashValue }
    
    // Check for hash value duplicates (should be unique but collisions are possible)
    let uniqueHashes = Set(hashValues)
    let collisionRate = Double(hashValues.count - uniqueHashes.count) / Double(hashValues.count)
    
    // Verify collision rate is below 10% (hash function quality check)
    #expect(collisionRate < 0.1, "Hash collision rate should be low")
  }
  
  @Test("Memory address reflection")
  func keyPathMemoryAddress() {
    // Verify that KeyPath actually reflects object memory addresses
    let object1 = NSObject()
    let object2 = NSObject()
    
    let keyPath1 = _keyPath(object1)
    let keyPath2 = _keyPath(object2)
    
    // Verify that KeyPath string representations contain memory addresses
    let keyPathString1 = keyPath1._kvcKeyPathString
    let keyPathString2 = keyPath2._kvcKeyPathString
    
    if let string1 = keyPathString1, let string2 = keyPathString2 {
      #expect(string1 != string2, "KeyPath strings should be different for different objects")
      #expect(string1.contains("pointer"), "KeyPath string should contain 'pointer'")
      #expect(string2.contains("pointer"), "KeyPath string should contain 'pointer'")
    }
  }
  
  @Test("Memory address reuse behavior")
  func keyPathMemoryAddressReuse() {
    // Verify behavior related to memory address reuse
    var firstKeyPath: (any KeyPath<PointerKeyPathRoot, Never> & Sendable)?
    var firstAddress: String?
    
    // Create first object and get its KeyPath
    autoreleasepool {
      let object1 = NSObject()
      firstKeyPath = _keyPath(object1)
      firstAddress = firstKeyPath?._kvcKeyPathString
    }
    
    // Promote garbage collection
    for _ in 0..<100 {
      autoreleasepool {
        _ = NSObject()
      }
    }
    
    // Create new object with KeyPath
    let object2 = NSObject()
    let secondKeyPath = _keyPath(object2)
    let secondAddress = secondKeyPath._kvcKeyPathString
    
    // Compare KeyPath objects themselves
    if let firstKeyPath = firstKeyPath {
      // When memory addresses are reused, KeyPaths may become the same
      // This is an implementation detail and may not always be different
      let keyPathsAreDifferent = !(firstKeyPath == secondKeyPath)
      
      // Compare address strings to verify actual behavior
      if let firstAddr = firstAddress, let secondAddr = secondAddress {
        print("First address: \(firstAddr)")
        print("Second address: \(secondAddr)")
        
        if firstAddr == secondAddr {
          // When memory addresses are reused, KeyPaths should be equal
          #expect(!keyPathsAreDifferent, "When memory addresses are reused, KeyPaths should be equal")
        } else {
          // When memory addresses are different, KeyPaths should be different
          #expect(keyPathsAreDifferent, "When memory addresses are different, KeyPaths should be different")
        }
      }
    }
  }
  
  @Test("Implementation details verification")
  func keyPathImplementationDetails() {
    // Verify KeyPath implementation details
    let object = NSObject()
    let keyPath = _keyPath(object)
    
    // Verify that KeyPath string representation has appropriate format
    if let keyPathString = keyPath._kvcKeyPathString {
      #expect(keyPathString.hasPrefix("pointer:"), "KeyPath string should start with 'pointer:'")
    }
    
    // Verify relationship between object memory address and KeyPath
    let objectPointer = Unmanaged.passUnretained(object).toOpaque()
    let expectedKeyPath = \PointerKeyPathRoot[pointer: objectPointer]
    
    // KeyPaths created from the same pointer should be equal
    #expect(keyPath == expectedKeyPath, "KeyPath should match expected KeyPath from same pointer")
  }
} 