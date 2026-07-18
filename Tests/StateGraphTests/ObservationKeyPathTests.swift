import Observation
@preconcurrency import Testing
@testable import StateGraph

@Suite("Observation KeyPath Tests")
@MainActor
struct ObservationKeyPathTests {

  @Test("Stored creates its Observation registrar on first read")
  func storedCreatesObservationRegistrarLazily() {
    let node = Stored(wrappedValue: 0)

    #expect(!node._isObservationRegistrarInitialized)

    node.wrappedValue = 1

    #expect(!node._isObservationRegistrarInitialized)

    _ = node.wrappedValue

    #expect(node._isObservationRegistrarInitialized)
  }

  @Test("Computed creates its Observation registrar on first read")
  func computedCreatesObservationRegistrarLazily() {
    let node = Computed<Int>(constant: 0)

    #expect(!node._isObservationRegistrarInitialized)

    _ = node.wrappedValue

    #expect(node._isObservationRegistrarInitialized)
  }

  @Test("Separate registrars isolate an identical key path")
  func separateRegistrarsIsolateIdenticalKeyPath() async {
    final class Identity: Sendable {}

    let identity = Identity()
    let keyPath = _keyPath(identity)
    let root = PointerKeyPathRoot<Identity>.shared
    var firstStorage = NodeObservationRegistrar()
    var secondStorage = NodeObservationRegistrar()
    let firstRegistrar = firstStorage.initializeIfNeeded()
    let secondRegistrar = secondStorage.initializeIfNeeded()

    await confirmation(expectedCount: 1) { confirmation in
      withObservationTracking {
        firstRegistrar.access(root, keyPath: keyPath)
      } onChange: {
        confirmation.confirm()
      }

      secondRegistrar.willSet(root, keyPath: keyPath)
      try? await Task.sleep(for: .milliseconds(10))

      firstRegistrar.willSet(root, keyPath: keyPath)
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

#if compiler(>=6.4)
  @Test("Node deinit ends its Observation lifetime")
  @available(macOS 27.0, iOS 27.0, watchOS 27.0, tvOS 27.0, *)
  func nodeDeinitEndsObservationLifetime() async {
    var node: Stored<Int>? = Stored(wrappedValue: 0)

    await confirmation(expectedCount: 1) { confirmation in
      withObservationTracking(options: [.deinit]) {
        _ = node?.wrappedValue
      } onChange: { event in
        if event.kind == .deinit {
          confirmation.confirm()
        }
      }

      node = nil
      try? await Task.sleep(for: .milliseconds(10))
    }
  }
#endif

  @Test("Direct Stored observation ignores another same-type instance")
  func directStoredObservationIgnoresAnotherSameTypeInstance() async {
    let observed = Stored(wrappedValue: 0)
    let other = Stored(wrappedValue: 0)

    await confirmation(expectedCount: 1) { confirmation in
      withObservationTracking {
        _ = observed.wrappedValue
      } onChange: {
        confirmation.confirm()
      }

      other.wrappedValue = 1
      try? await Task.sleep(for: .milliseconds(10))

      observed.wrappedValue = 1
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  @Test("Direct Stored observation invalidates when the observed node changes")
  func directStoredObservationInvalidatesWhenObservedNodeChanges() async {
    let node = Stored(wrappedValue: 0)

    await confirmation(expectedCount: 1) { confirmation in
      withObservationTracking {
        _ = node.wrappedValue
      } onChange: {
        confirmation.confirm()
      }

      node.wrappedValue = 1
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  @Test("Computed observation invalidates when a dependency changes")
  func computedObservationInvalidatesWhenDependencyChanges() async {
    let source = Stored(wrappedValue: 1)
    let computed = Computed<Int> { _ in
      source.wrappedValue * 2
    }

    await confirmation(expectedCount: 1) { confirmation in
      withObservationTracking {
        _ = computed.wrappedValue
      } onChange: {
        confirmation.confirm()
      }

      source.wrappedValue = 2
      try? await Task.sleep(for: .milliseconds(10))
    }
  }
}
