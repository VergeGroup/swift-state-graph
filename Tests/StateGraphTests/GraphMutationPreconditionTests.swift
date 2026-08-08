#if DEBUG
import Testing

@testable import StateGraph

@Suite("Graph mutation debug assertions")
struct GraphMutationPreconditionTests {

  @Test
  func committedComputedDescriptorCannotMutateStored() async {
    let result = await #expect(
      processExitsWith: .failure,
      observing: [\.standardErrorContent]
    ) {
      let source = Stored(wrappedValue: 0)
      let computed = Computed<Int> { _ in
        source.wrappedValue = 1
        return source.wrappedValue
      }

      _ = computed.wrappedValue
    }

    expectMutationDiagnostic(result, operation: "Stored.wrappedValue mutation")
  }

  @Test
  func transactionComputedDescriptorCannotMutateStored() async {
    let result = await #expect(
      processExitsWith: .failure,
      observing: [\.standardErrorContent]
    ) {
      let source = Stored(wrappedValue: 0)
      let computed = Computed<Int> { _ in
        source.wrappedValue = 1
        return source.wrappedValue
      }

      withGraphTransaction {
        _ = computed.wrappedValue
      }
    }

    expectMutationDiagnostic(result, operation: "Stored.wrappedValue mutation")
  }

  @Test
  func computedDescriptorCannotStartTransaction() async {
    let result = await #expect(
      processExitsWith: .failure,
      observing: [\.standardErrorContent]
    ) {
      let computed = Computed<Int> { _ in
        withGraphTransaction {}
        return 0
      }

      _ = computed.wrappedValue
    }

    expectMutationDiagnostic(result, operation: "withGraphTransaction")
  }

  @Test
  func computedEqualityCannotMutateStored() async {
    let result = await #expect(
      processExitsWith: .failure,
      observing: [\.standardErrorContent]
    ) {
      let source = Stored(wrappedValue: 0)
      let sideEffect = Stored(wrappedValue: 0)
      let descriptor = AnyComputedDescriptor<Int>(
        compute: { _ in source.wrappedValue },
        isEqual: { _, _ in
          sideEffect.wrappedValue = 1
          return true
        }
      )
      let computed = Computed(descriptor: descriptor)

      _ = computed.wrappedValue
      source.wrappedValue = 1
      _ = computed.wrappedValue
    }

    expectMutationDiagnostic(result, operation: "Stored.wrappedValue mutation")
  }

  @Test
  func computedDescriptorCannotMutateGraphUserDefault() async {
    let result = await #expect(
      processExitsWith: .failure,
      observing: [\.standardErrorContent]
    ) {
      let source = GraphUserDefault(
        wrappedValue: 0,
        "computed-mutation",
        suiteName: "StateGraph.GraphMutationPreconditionTests"
      )
      let computed = Computed<Int> { _ in
        source.wrappedValue = 1
        return source.wrappedValue
      }

      _ = computed.wrappedValue
    }

    expectMutationDiagnostic(result, operation: "GraphUserDefault.wrappedValue mutation")
  }

  @Test
  func immediateComparatorCannotMutateStored() async {
    let result = await #expect(
      processExitsWith: .failure,
      observing: [\.standardErrorContent]
    ) {
      let sideEffect = Stored(wrappedValue: 0)
      let source = Stored(wrappedValue: 0) { _, _ in
        sideEffect.wrappedValue += 1
        return true
      }

      source.wrappedValue = 1
    }

    expectMutationDiagnostic(result, operation: "Stored.wrappedValue mutation")
  }

  @Test
  func transactionComparatorCannotMutateStored() async {
    let result = await #expect(
      processExitsWith: .failure,
      observing: [\.standardErrorContent]
    ) {
      let sideEffect = Stored(wrappedValue: 0)
      let source = Stored(wrappedValue: 0) { _, _ in
        sideEffect.wrappedValue += 1
        return true
      }

      withGraphTransaction {
        source.wrappedValue = 1
      }
    }

    expectMutationDiagnostic(result, operation: "Stored.wrappedValue mutation")
  }

  @Test
  func unsafeModifyCannotEnterGraphMutation() async {
    let result = await #expect(
      processExitsWith: .failure,
      observing: [\.standardErrorContent]
    ) {
      let source = Stored(wrappedValue: 0)
      let sideEffect = Stored(wrappedValue: 0)

      source.unsafeModify { value in
        value = 1
        sideEffect.wrappedValue = 1
      }
    }

    expectMutationDiagnostic(result, operation: "Stored.wrappedValue mutation")
  }

  private func expectMutationDiagnostic(
    _ result: ExitTest.Result?,
    operation: String
  ) {
    let standardError = String(
      decoding: result?.standardErrorContent ?? [],
      as: UTF8.self
    )

    // Swift Testing's exit-test child cannot install TSan interceptors when the
    // parent test bundle is sanitized. The exit condition is still checked by the
    // macro; skip only the child runtime's replacement stderr in that configuration.
    guard !standardError.contains("Interceptors are not working") else { return }

    #expect(standardError.contains(operation))
    #expect(standardError.contains("Move graph mutations outside that closure"))
  }
}
#endif
