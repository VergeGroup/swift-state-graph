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

    #expect(storedDescription.contains("NodeObservationRoot<_Stored<Int, InMemoryStorage<Int>>>.wrappedValue"))
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
}
