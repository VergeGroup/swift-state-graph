import StateGraphAsyncDataStore
import Testing

@testable import StateGraph

/// A reference value that intentionally does not conform to `Sendable`.
private final class NonSendableEquatableValue: Equatable {

  let rawValue: Int

  init(rawValue: Int) {
    self.rawValue = rawValue
  }

  static func == (lhs: NonSendableEquatableValue, rhs: NonSendableEquatableValue) -> Bool {
    lhs.rawValue == rhs.rawValue
  }
}

private func makeEquatableStored<Value: Equatable & SendableMetatype>(
  _ value: Value
) -> Stored<Value> {
  Stored(wrappedValue: value)
}

private func makeEquatableComputed<Value: Equatable & SendableMetatype>(
  _ rule: @escaping @Sendable (inout Computed<Value>.Context) -> Value
) -> Computed<Value> {
  Computed(rule: rule)
}

@Suite
struct SendableMetatypeTests {

  private final class ReferenceValueHeader: AsyncDataStoreHeader {
    typealias Value = NonSendableEquatableValue
    typealias Store = AsyncDataStore<ReferenceValueHeader>

    enum Action {
      case increment
    }

    private var increment = 1

    static func receive(
      action: Action,
      header: ReferenceValueHeader,
      context: Store.Context,
      on store: isolated Store
    ) async {
      #expect(store.header === header)
      let next = context.value.rawValue + header.increment
      header.increment += 1
      context.update(on: store) { $0 = NonSendableEquatableValue(rawValue: next) }
    }
  }

  @Test
  func equatableNodesAcceptNonSendableValues() {
    let stored = makeEquatableStored(NonSendableEquatableValue(rawValue: 1))
    let computed = makeEquatableComputed { _ in
      NonSendableEquatableValue(rawValue: stored.wrappedValue.rawValue + 1)
    }

    #expect(computed.wrappedValue.rawValue == 2)
  }

  @Test
  @MainActor
  func asyncDataStoreAcceptsNonSendableHeaderAndValue() async {
    let store = AsyncDataStore(
      header: ReferenceValueHeader(),
      initial: NonSendableEquatableValue(rawValue: 1)
    )
    store.setReduce { $0 = NonSendableEquatableValue(rawValue: $0.rawValue * 10) }

    #expect(store.value.rawValue == 10)
    await store.sendAndWait(action: .increment)
    #expect(store.sourceValue.rawValue == 2)
    #expect(store.value.rawValue == 20)

    await store.sendAndWait(action: .increment)
    #expect(store.sourceValue.rawValue == 4)
    #expect(store.value.rawValue == 40)
  }
}
