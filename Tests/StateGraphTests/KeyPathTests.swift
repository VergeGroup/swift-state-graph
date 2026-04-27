@preconcurrency import Foundation
@preconcurrency import Testing
@testable import StateGraph

@Suite("KeyPath Tests")
struct KeyPathTests {

  @Test("Same object generates consistent KeyPaths")
  func sameObjectKeyPathConsistency() {
    let object = NSObject()

    let keyPath1 = _keyPath(object)
    let keyPath2 = _keyPath(object)

    #expect(keyPath1 == keyPath2)
  }

  @Test("Same-type different objects generate different KeyPaths")
  func sameTypeDifferentObjectsGenerateDifferentKeyPaths() {
    let object1 = NSObject()
    let object2 = NSObject()

    let keyPath1 = _keyPath(object1)
    let keyPath2 = _keyPath(object2)

    #expect(keyPath1 != keyPath2)
  }

  @Test("Same-type KeyPaths remain unique across many live objects")
  func sameTypeKeyPathsRemainUniqueAcrossManyLiveObjects() {
    let objects = (0..<100).map { _ in NSObject() }
    let keyPaths = objects.map { _keyPath($0) }

    for i in 0..<keyPaths.count {
      for j in (i + 1)..<keyPaths.count {
        #expect(keyPaths[i] != keyPaths[j])
      }
    }
  }

  @Test("KeyPath remains stable while object is alive")
  func keyPathRemainsStableWhileObjectIsAlive() {
    let object = NSObject()
    let initialKeyPath = _keyPath(object)

    for _ in 0..<10 {
      #expect(_keyPath(object) == initialKeyPath)
    }
  }

  @Test("KeyPath remains valid after object is released")
  func keyPathRemainsValidAfterObjectIsReleased() {
    var keyPath: (any KeyPath<PointerKeyPathRoot<NSObject>, Never> & Sendable)?

    autoreleasepool {
      let object = NSObject()
      keyPath = _keyPath(object)
    }

    #expect(keyPath != nil)
  }

  @Test("KeyPath is Sendable")
  func keyPathSendableConformance() {
    let object = NSObject()
    let keyPath = _keyPath(object)

    let sendableKeyPath: any KeyPath<PointerKeyPathRoot<NSObject>, Never> & Sendable = keyPath

    #expect(sendableKeyPath == keyPath)
  }

  @Test("Concurrent KeyPath generation")
  func concurrentKeyPathGeneration() async {
    let keyPaths = OSAllocatedUnfairLock<
      [any KeyPath<PointerKeyPathRoot<NSObject>, Never> & Sendable]
    >(initialState: [])
    let objects = OSAllocatedUnfairLock<[NSObject]>(initialState: [])

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<10 {
        group.addTask {
          let object = NSObject()
          let keyPath = _keyPath(object)

          objects.withLock { objects in
            objects.append(object)
          }

          keyPaths.withLock { keyPaths in
            keyPaths.append(keyPath)
          }
        }
      }
    }

    let finalKeyPaths = keyPaths.withLock { $0 }
    let finalObjects = objects.withLock { $0 }

    #expect(finalKeyPaths.count == 10)
    #expect(finalObjects.count == 10)

    for i in 0..<finalKeyPaths.count {
      for j in (i + 1)..<finalKeyPaths.count {
        #expect(finalKeyPaths[i] != finalKeyPaths[j])
      }
    }
  }

  @Test("KeyPath description includes generic root type")
  func keyPathDescriptionIncludesGenericRootType() {
    let stored = Stored(wrappedValue: 1)
    let computed = Computed<Int>(constant: 1)

    let storedDescription = String(describing: _keyPath(stored))
    let computedDescription = String(describing: _keyPath(computed))

    #expect(storedDescription.contains("PointerKeyPathRoot"))
    #expect(storedDescription.contains("_Stored<Int, InMemoryStorage<Int>>"))
    #expect(computedDescription.contains("PointerKeyPathRoot"))
    #expect(computedDescription.contains("Computed<Int>"))
    #expect(storedDescription != computedDescription)
  }

  @Test("Expected pointer KeyPath matches generated KeyPath")
  func expectedPointerKeyPathMatchesGeneratedKeyPath() {
    let object = NSObject()
    let objectPointer = Unmanaged.passUnretained(object).toOpaque()

    let keyPath = _keyPath(object)
    let expectedKeyPath = \PointerKeyPathRoot<NSObject>[pointer: objectPointer]

    #expect(keyPath == expectedKeyPath)
  }
}
