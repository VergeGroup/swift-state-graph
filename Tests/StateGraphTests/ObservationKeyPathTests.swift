import Observation
@preconcurrency import Testing
@testable import StateGraph

@Suite("Observation KeyPath Tests")
@MainActor
struct ObservationKeyPathTests {

  @Test("Separate registrars isolate the shared node wrapped-value key path")
  func separateRegistrarsIsolateSharedNodeWrappedValueKeyPath() async {
    let root = NodeObservationRoot<Stored<Int>>()
    let keyPath = \NodeObservationRoot<Stored<Int>>.wrappedValue
    let firstRegistrar = ObservationRegistrar()
    let secondRegistrar = ObservationRegistrar()

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
