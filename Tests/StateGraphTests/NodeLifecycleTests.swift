import Observation
import Testing
import os.lock

@testable import StateGraph

@Suite("Node Lifecycle Tests")
struct NodeLifecycleTests {

  @Test
  func releasingUpstreamComputedUsesDownstreamFallback() async {
    var upstream: Computed<String>? = Computed { _ in "upstream" }
    weak let weakUpstream = upstream
    let downstream = Computed { [weak upstream] _ in
      return upstream?.wrappedValue ?? "fallback"
    }

    #expect(downstream.wrappedValue == "upstream")

    upstream = nil

    for _ in 0..<100 where weakUpstream != nil {
      try? await Task.sleep(for: .milliseconds(1))
    }

    #expect(weakUpstream == nil)
    #expect(downstream.wrappedValue == "fallback")
  }

  @Test(
    "Releasing a changed source preserves its pending downstream invalidation",
    arguments: [false, true]
  )
  func releasingChangedSourcePreservesPendingInvalidation(
    usesTransaction: Bool
  ) {
    var source: Stored<String>? = Stored(wrappedValue: "initial")
    weak let weakSource = source
    let reader = WeakStoredFallbackReader(source: source.unsafelyUnwrapped)
    let downstream = Computed { _ in
      reader.value
    }

    #expect(downstream.wrappedValue == "initial")

    if usesTransaction {
      withGraphTransaction {
        source.unsafelyUnwrapped.wrappedValue = "updated"
      }
    } else {
      source.unsafelyUnwrapped.wrappedValue = "updated"
    }

    #expect(reader.value == "updated")
    source = nil

    #expect(weakSource == nil)
    #expect(downstream.wrappedValue == "updated")
  }

  @Test("Releasing an unchanged source invalidates a weak downstream read")
  func releasingUnchangedSourceInvalidatesWeakDownstreamRead() {
    var source: Stored<String>? = Stored(wrappedValue: "source")
    let downstream = Computed { [weak source] _ in
      source?.wrappedValue ?? "fallback"
    }

    #expect(downstream.wrappedValue == "source")

    source = nil

    #expect(downstream.wrappedValue == "fallback")
  }

  @Test("Releasing a dirty computed source preserves downstream invalidation")
  func releasingDirtyComputedSourcePreservesDownstreamInvalidation() {
    let source = Stored(wrappedValue: "initial")
    var intermediate: Computed<String>? = Computed { _ in
      source.wrappedValue
    }
    let downstream = Computed { [weak intermediate] _ in
      intermediate?.wrappedValue ?? source.wrappedValue
    }

    #expect(downstream.wrappedValue == "initial")

    source.wrappedValue = "updated"
    intermediate = nil

    #expect(downstream.wrappedValue == "updated")
  }

  @Test("Releasing a computed source during transaction willSet preserves invalidation")
  @MainActor
  func releasingComputedSourceDuringTransactionWillSetPreservesInvalidation() {
    let source = Stored(wrappedValue: "initial")
    let intermediateHolder = OSAllocatedUnfairLock<Computed<String>?>(
      uncheckedState: nil
    )
    weak var weakIntermediate: Computed<String>?
    let downstream: Computed<String> = {
      let intermediate = Computed { _ in
        source.wrappedValue
      }
      weakIntermediate = intermediate
      intermediateHolder.withLock { $0 = intermediate }

      return Computed { [weak intermediate] _ in
        intermediate?.wrappedValue ?? source.wrappedValue
      }
    }()

    #expect(downstream.wrappedValue == "initial")

    withObservationTracking {
      _ = source.wrappedValue
    } onChange: {
      intermediateHolder.withLock { $0 = nil }
    }

    withGraphTransaction {
      source.wrappedValue = "updated"
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
    #expect(resolvedValue == "updated")
  }
}

/// Reads through a weak source while preserving the last live result as a fallback.
private final class WeakStoredFallbackReader: @unchecked Sendable {

  private weak var source: Stored<String>?
  private let fallback: OSAllocatedUnfairLock<String>

  var value: String {
    guard let source else {
      return fallback.withLock { $0 }
    }

    let value = source.wrappedValue
    fallback.withLock { $0 = value }
    return value
  }

  init(source: Stored<String>) {
    self.source = source
    self.fallback = .init(initialState: source.wrappedValue)
  }
}
