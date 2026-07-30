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

  @Test
  func equatableNodesAcceptNonSendableValues() {
    let stored = makeEquatableStored(NonSendableEquatableValue(rawValue: 1))
    let computed = makeEquatableComputed { _ in
      NonSendableEquatableValue(rawValue: stored.wrappedValue.rawValue + 1)
    }

    #expect(computed.wrappedValue.rawValue == 2)
  }
}
