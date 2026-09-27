#if DEBUG
import Foundation
import Testing
import os

@testable import StateGraph

@Suite("Computed initialization boundaries")
struct ComputedInitializationPreconditionTests {

  @Test
  func valueReadEndsInitialization() async {
    let result = await #expect(
      processExitsWith: .failure,
      observing: [\.standardErrorContent]
    ) {
      let computed = Computed<Stored<Int>> { _ in
        let node = Stored(wrappedValue: 0)
        _ = node.wrappedValue
        node.wrappedValue = 1
        // Retain the node in the result if the guard regresses, so its release
        // cannot turn an unexpected success into an unrelated evaluation crash.
        return node
      }

      _ = computed.wrappedValue
    }

    expectMutationDiagnostic(result)
  }

  @Test
  func assignmentObserverEndsInitialization() async {
    let result = await #expect(
      processExitsWith: .failure,
      observing: [\.standardErrorContent]
    ) {
      let computed = Computed<Stored<Int>> { _ in
        let node = Stored(wrappedValue: 0)
        node.onDidSet { _, _ in }
        node.wrappedValue = 1
        return node
      }

      _ = computed.wrappedValue
    }

    expectMutationDiagnostic(result)
  }

  @Test
  func debugDescriptionEndsInitialization() async {
    let result = await #expect(
      processExitsWith: .failure,
      observing: [\.standardErrorContent]
    ) {
      let computed = Computed<Stored<Int>> { _ in
        let node = Stored(wrappedValue: 0)
        _ = node.debugDescription
        node.wrappedValue = 1
        return node
      }

      _ = computed.wrappedValue
    }

    expectMutationDiagnostic(result)
  }

  @Test
  func transactionValueReadEndsInitialization() async {
    let result = await #expect(
      processExitsWith: .failure,
      observing: [\.standardErrorContent]
    ) {
      let computed = Computed<Stored<Int>> { _ in
        let node = Stored(wrappedValue: 0)
        _ = node.wrappedValue
        node.wrappedValue = 1
        return node
      }

      withGraphTransaction {
        _ = computed.wrappedValue
      }
    }

    expectMutationDiagnostic(result)
  }

  @Test
  func ordinaryWriteOnAnotherThreadEndsInitialization() async {
    let result = await #expect(
      processExitsWith: .failure,
      observing: [\.standardErrorContent]
    ) {
      let computed = Computed<Stored<Int>> { _ in
        let node = Stored(wrappedValue: 0)
        let written = TestThreadSignal()
        Thread {
          node.wrappedValue = 1
          written.signal()
        }.start()
        precondition(written.wait(until: Date().addingTimeInterval(5)))

        node.wrappedValue = 2
        return node
      }

      _ = computed.wrappedValue
    }

    expectMutationDiagnostic(result)
  }

  @Test
  func laterEvaluationCannotInitializeAnUnreadNode() async {
    let result = await #expect(
      processExitsWith: .failure,
      observing: [\.standardErrorContent]
    ) {
      let source = Stored(wrappedValue: 0)
      let retainedNode = OSAllocatedUnfairLock<Stored<Int>?>(initialState: nil)
      let computed = Computed<Stored<Int>> { _ in
        _ = source.wrappedValue
        if let node = retainedNode.withLock({ $0 }) {
          node.wrappedValue = 1
          return node
        }

        let node = Stored(wrappedValue: 0)
        retainedNode.withLock { $0 = node }
        return node
      }

      _ = computed.wrappedValue
      source.wrappedValue = 1
      _ = computed.wrappedValue
    }

    expectMutationDiagnostic(result)
  }

  @Test
  func nestedEvaluationCannotInitializeParentNodes() async {
    let result = await #expect(
      processExitsWith: .failure,
      observing: [\.standardErrorContent]
    ) {
      let retainedChild = OSAllocatedUnfairLock<Computed<Int>?>(initialState: nil)
      let parent = Computed<Stored<Int>> { _ in
        let node = Stored(wrappedValue: 0)
        let child = Computed<Int> { _ in
          node.wrappedValue = 1
          return 0
        }
        // Releasing a dependency during its parent's evaluation is a separate
        // lifecycle regression; keep this test focused on the mutation diagnostic.
        retainedChild.withLock { $0 = child }
        _ = child.wrappedValue
        return node
      }

      _ = parent.wrappedValue
    }

    expectMutationDiagnostic(result)
  }

  @Test
  func parentEvaluationCannotInitializeReturnedChildNodes() async {
    let result = await #expect(
      processExitsWith: .failure,
      observing: [\.standardErrorContent]
    ) {
      let child = Computed<Stored<Int>> { _ in
        Stored(wrappedValue: 0)
      }
      let parent = Computed<Stored<Int>> { _ in
        let node = child.wrappedValue
        node.wrappedValue = 1
        return node
      }

      _ = parent.wrappedValue
    }

    expectMutationDiagnostic(result)
  }

  @Test
  func nestedEqualityCannotInitializeParentNodes() async {
    let result = await #expect(
      processExitsWith: .failure,
      observing: [\.standardErrorContent]
    ) {
      let source = Stored(wrappedValue: 0)
      let retainedNode = OSAllocatedUnfairLock<Stored<Int>?>(initialState: nil)
      let child = Computed(
        descriptor: AnyComputedDescriptor<Int>(
          compute: { _ in source.wrappedValue },
          isEqual: { _, _ in
            let node = retainedNode.withLock { $0! }
            node.wrappedValue = 1
            return false
          }
        )
      )

      _ = child.wrappedValue
      source.wrappedValue = 1

      let parent = Computed<Stored<Int>> { _ in
        let node = Stored(wrappedValue: 0)
        retainedNode.withLock { $0 = node }
        _ = child.wrappedValue
        return node
      }

      _ = parent.wrappedValue
    }

    expectMutationDiagnostic(result)
  }

  private func expectMutationDiagnostic(_ result: ExitTest.Result?) {
    let standardError = String(
      decoding: result?.standardErrorContent ?? [],
      as: UTF8.self
    )

    // Match the existing exit-test convention when TSan prevents the child
    // process from installing its interceptors before test code can execute.
    guard !standardError.contains("Interceptors are not working") else { return }

    #expect(standardError.contains("Stored.wrappedValue mutation"))
    #expect(standardError.contains("Move graph mutations outside that closure"))
  }
}
#endif
