import Foundation
@preconcurrency import Testing
@testable import StateGraph

@Suite("Node Observation KeyPath Tests")
struct KeyPathTests {

  @Test("Node wrapped-value KeyPaths include the concrete node type and property name")
  func nodeWrappedValueKeyPathDescriptionsAreReadable() {
    let storedDescription = String(
      describing: \NodeObservationRoot<Stored<Int>>.wrappedValue
    )
    let computedDescription = String(
      describing: \NodeObservationRoot<Computed<Int>>.wrappedValue
    )

    #expect(storedDescription.contains("NodeObservationRoot<Stored<Int>>.wrappedValue"))
    #expect(computedDescription.contains("NodeObservationRoot<Computed<Int>>.wrappedValue"))
    #expect(!storedDescription.contains("0x"))
    #expect(!computedDescription.contains("0x"))
  }

  @Test("Node wrapped-value KeyPath is Sendable")
  func nodeWrappedValueKeyPathIsSendable() {
    let keyPath = \NodeObservationRoot<Stored<Int>>.wrappedValue
    let sendableKeyPath:
      any KeyPath<NodeObservationRoot<Stored<Int>>, Void> & Sendable = keyPath

    #expect(sendableKeyPath == keyPath)
  }

  @Test("Nodes observe through a cached KeyPath equal to the readable literal")
  func nodesUseCachedKeyPathEqualToReadableLiteral() {
    let storedLiteral = \NodeObservationRoot<Stored<Int>>.wrappedValue
    let computedLiteral = \NodeObservationRoot<Computed<Int>>.wrappedValue
    let stored = Stored(wrappedValue: 0)
    let computed = Computed { _ in 0 }

    #expect(stored.observationKeyPath == storedLiteral)
    #expect(stored.observationKeyPath.hashValue == storedLiteral.hashValue)
    #expect(String(describing: stored.observationKeyPath) == String(describing: storedLiteral))
    #expect(computed.observationKeyPath == computedLiteral)
    #expect(String(describing: computed.observationKeyPath) == String(describing: computedLiteral))
    // Nothing suspends here, so both nodes were given this thread's cached instance.
    #expect(stored.observationKeyPath === Stored(wrappedValue: 1).observationKeyPath)
  }

  @Test("Cached node KeyPaths from another thread equal the readable literal")
  func cachedKeyPathFromAnotherThreadEqualsReadableLiteral() async {
    let literal = \NodeObservationRoot<Stored<Int>>.wrappedValue

    let keyPathOnAnotherThread = await withCheckedContinuation { continuation in
      Thread {
        continuation.resume(returning: Stored(wrappedValue: 0).observationKeyPath)
      }.start()
    }

    #expect(keyPathOnAnotherThread == literal)
    #expect(keyPathOnAnotherThread.hashValue == literal.hashValue)
  }
}
