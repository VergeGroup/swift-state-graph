import Observation
import Testing
import os.lock

@testable import StateGraph

@Suite("Node Lifecycle Tests")
struct NodeLifecycleTests {

  @Test
  func releasingUpstreamComputedRemovesDownstreamEdge() async {
    let trigger = Stored(wrappedValue: 0)
    var upstream: Computed<Int>? = Computed { _ in 10 }
    weak let weakUpstream = upstream
    let downstream = Computed { [weak upstream] _ in
      (upstream?.wrappedValue ?? 0) + trigger.wrappedValue
    }

    #expect(downstream.wrappedValue == 10)

    upstream = nil

    for _ in 0..<100 where weakUpstream != nil {
      try? await Task.sleep(for: .milliseconds(1))
    }

    #expect(weakUpstream == nil)

    trigger.wrappedValue = 1
    #expect(downstream.wrappedValue == 1)
  }

  @Test(
    "Releasing a changed source preserves its pending downstream invalidation",
    arguments: [false, true]
  )
  func releasingChangedSourcePreservesPendingInvalidation(
    usesTransaction: Bool
  ) {
    var source: Stored<Int>? = Stored(wrappedValue: 1)
    weak let weakSource = source
    let reader = WeakStoredFallbackReader(source: source.unsafelyUnwrapped)
    let downstream = Computed { _ in
      reader.value
    }

    #expect(downstream.wrappedValue == 1)

    if usesTransaction {
      withGraphTransaction {
        source.unsafelyUnwrapped.wrappedValue = 2
      }
    } else {
      source.unsafelyUnwrapped.wrappedValue = 2
    }

    #expect(reader.value == 2)
    source = nil

    #expect(weakSource == nil)
    #expect(downstream.wrappedValue == 2)
  }

  @Test("Releasing an unchanged source invalidates a weak downstream read")
  func releasingUnchangedSourceInvalidatesWeakDownstreamRead() {
    var source: Stored<Int>? = Stored(wrappedValue: 1)
    let downstream = Computed { [weak source] _ in
      source?.wrappedValue ?? 0
    }

    #expect(downstream.wrappedValue == 1)

    source = nil

    #expect(downstream.wrappedValue == 0)
  }

  @Test("Releasing a dirty computed source preserves downstream invalidation")
  func releasingDirtyComputedSourcePreservesDownstreamInvalidation() {
    let source = Stored(wrappedValue: 1)
    var intermediate: Computed<Int>? = Computed { _ in
      source.wrappedValue
    }
    let downstream = Computed { [weak intermediate] _ in
      intermediate?.wrappedValue ?? source.wrappedValue
    }

    #expect(downstream.wrappedValue == 1)

    source.wrappedValue = 2
    intermediate = nil

    #expect(downstream.wrappedValue == 2)
  }

  @Test("Releasing a computed source during transaction willSet preserves invalidation")
  @MainActor
  func releasingComputedSourceDuringTransactionWillSetPreservesInvalidation() {
    let source = Stored(wrappedValue: 1)
    let intermediateHolder = OSAllocatedUnfairLock<Computed<Int>?>(
      uncheckedState: nil
    )
    weak var weakIntermediate: Computed<Int>?
    let downstream: Computed<Int> = {
      let intermediate = Computed { _ in
        source.wrappedValue
      }
      weakIntermediate = intermediate
      intermediateHolder.withLock { $0 = intermediate }

      return Computed { [weak intermediate] _ in
        intermediate?.wrappedValue ?? source.wrappedValue
      }
    }()

    #expect(downstream.wrappedValue == 1)

    withObservationTracking {
      _ = source.wrappedValue
    } onChange: {
      intermediateHolder.withLock { $0 = nil }
    }

    withGraphTransaction {
      source.wrappedValue = 2
    }

    let intermediateWasReleased = weakIntermediate == nil
    let downstreamWasDirty = downstream.potentiallyDirty
    let incomingEdgeCount = downstream.incomingEdges.count
    let sourceWasDetached = downstream.incomingEdges.first?.from == nil
    let edgeWasPending = downstream.incomingEdges.first?.isPending == true
    let resolvedValue = downstream.wrappedValue

    #expect(intermediateWasReleased)
    #expect(downstreamWasDirty)
    #expect(incomingEdgeCount == 1)
    #expect(sourceWasDetached)
    #expect(edgeWasPending)
    #expect(resolvedValue == 2)
  }
}

/// Reads through a weak source while preserving the last live result as a fallback.
private final class WeakStoredFallbackReader: @unchecked Sendable {

  private weak var source: Stored<Int>?
  private let fallback: OSAllocatedUnfairLock<Int>

  var value: Int {
    guard let source else {
      return fallback.withLock { $0 }
    }

    let value = source.wrappedValue
    fallback.withLock { $0 = value }
    return value
  }

  init(source: Stored<Int>) {
    self.source = source
    self.fallback = .init(initialState: source.wrappedValue)
  }
}
