import Foundation
import Testing
import os.lock

@testable import StateGraph

/// Covers nodes deinitialized while a `Computed` evaluation holds its nonrecursive node lock.
///
/// Evaluation locks nodes from downstream to upstream, whereas releasing a node reaches its
/// neighbors in both directions. These tests keep ordinary descriptor and cache lifetimes from
/// locking a node that the releasing thread already owns, or one that another thread's
/// evaluation owns while it waits for a lock held by the releasing thread.
@Suite("Node Release During Evaluation Tests")
struct NodeReleaseDuringEvaluationTests {

  @Test("Releasing a temporary node read by a descriptor keeps its reader clean")
  func releasingTemporaryStoredReadByDescriptor() {
    let source = Stored(wrappedValue: 1)
    let evaluationCount = OSAllocatedUnfairLock(initialState: 0)
    let computed = Computed<Int> { _ in
      evaluationCount.withLock { $0 += 1 }
      return ReleasedModel(count: source.wrappedValue).count
    }

    #expect(computed.wrappedValue == 1)
    #expect(computed.potentiallyDirty == false)
    #expect(computed.wrappedValue == 1)
    #expect(evaluationCount.withLock { $0 } == 1)

    source.wrappedValue = 2

    #expect(computed.wrappedValue == 2)
    #expect(evaluationCount.withLock { $0 } == 2)
  }

  @Test("Releasing a temporary computed read by a descriptor detaches it from its source")
  func releasingTemporaryComputedReadByDescriptor() {
    let source = Stored(wrappedValue: 1)
    let computed = Computed<Int> { _ in
      let temporary = Computed<Int> { _ in source.wrappedValue * 2 }
      return temporary.wrappedValue
    }

    #expect(computed.wrappedValue == 2)
    #expect(computed.potentiallyDirty == false)
    #expect(source.outgoingEdgesSnapshot().isEmpty)
  }

  @Test("Replacing an upstream value releases a node that the refreshing reader consumes")
  func replacingUpstreamValueDuringDownstreamRefresh() {
    let source = Stored(wrappedValue: 1)
    let model = Computed<ReleasedModel> { _ in
      ReleasedModel(count: source.wrappedValue)
    }
    let downstream = Computed<Int> { _ in
      model.wrappedValue.count
    }

    #expect(downstream.wrappedValue == 1)

    source.wrappedValue = 2
    #expect(downstream.wrappedValue == 2)

    source.wrappedValue = 3
    #expect(downstream.wrappedValue == 3)

    model.wrappedValue.count = 4
    #expect(downstream.wrappedValue == 4)
  }

  @Test("A released node refreshes its reader when the replacing upstream value compares equal")
  func releasedNodeRefreshesReaderWhenUpstreamValueIsEqual() {
    let source = Stored(wrappedValue: 1)
    let model = Computed<IdentifiedReleasedModel> { _ in
      IdentifiedReleasedModel(id: 1, count: source.wrappedValue)
    }
    let downstream = Computed<Int> { _ in
      model.wrappedValue.count
    }

    #expect(downstream.wrappedValue == 1)

    // The replacement compares equal, so only the released `count` node's pending edge
    // makes the refreshing downstream rebuild its dependencies.
    source.wrappedValue = 2
    #expect(downstream.wrappedValue == 2)

    model.wrappedValue.count = 3
    #expect(downstream.wrappedValue == 3)
  }

  @Test("Releasing a node during another node's evaluation invalidates its other readers")
  func releaseDuringEvaluationInvalidatesUnrelatedReader() {
    let source = Stored(wrappedValue: 1)
    let model = Computed<ReleasedModel> { _ in
      ReleasedModel(count: source.wrappedValue)
    }
    let reader = WeakReleasedModelReader(model: model.wrappedValue)
    let observer = Computed<Int> { _ in
      reader.count
    }

    #expect(observer.wrappedValue == 1)

    source.wrappedValue = 2
    #expect(observer.potentiallyDirty == false)

    // The replaced model is released while `model` holds its lock.
    #expect(model.wrappedValue.count == 2)
    #expect(observer.potentiallyDirty)
    #expect(observer.wrappedValue == WeakReleasedModelReader.fallback)
  }

  @Test("Releasing a node during another node's evaluation notifies its tracked readers")
  func releaseDuringEvaluationNotifiesTrackedReader() async {
    let source = Stored(wrappedValue: 1)
    let model = Computed<ReleasedModel> { _ in
      ReleasedModel(count: source.wrappedValue)
    }
    let reader = WeakReleasedModelReader(model: model.wrappedValue)
    let observer = Computed<Int> { _ in
      reader.count
    }
    let didTrackFallback = TestSignal()

    let subscription = withGraphTracking {
      withGraphTrackingGroup(
        {
          if observer.wrappedValue == WeakReleasedModelReader.fallback {
            didTrackFallback.signal()
          }
        },
        isolation: nil
      )
    }
    defer { subscription.cancel() }

    // The tracking callback captured while `model` holds its lock runs after it unlocks.
    source.wrappedValue = 2
    #expect(model.wrappedValue.count == 2)
    #expect(await didTrackFallback.wait(for: .seconds(5)))
  }

  @Test("A tracking pass reruns when its own read releases a node it already read")
  func trackingPassRerunsWhenItsReadReleasesNodeItRead() async {
    let source = Stored(wrappedValue: 1)
    let model = Computed<ReleasedModel> { _ in
      ReleasedModel(count: source.wrappedValue)
    }
    let reader = WeakReleasedModelReader(model: model.wrappedValue)
    let observer = Computed<Int> { _ in
      reader.count
    }
    let didTrackFallback = TestSignal()

    let subscription = withGraphTracking {
      withGraphTrackingGroup(
        {
          // Reading `model` after `observer` can release the model that `observer` read.
          let observedCount = observer.wrappedValue
          _ = model.wrappedValue
          if observedCount == WeakReleasedModelReader.fallback {
            didTrackFallback.signal()
          }
        },
        isolation: nil
      )
    }
    defer { subscription.cancel() }

    // The rerun's own `model` read invalidates `observer` after the rerun read it. That
    // release is not a mutation by the pass, so the pass must not suppress it.
    source.wrappedValue = 2
    #expect(await didTrackFallback.wait(for: .seconds(5)))
  }

  @Test("Releasing a node during evaluation dirties a clean reader before the refresh reaches it")
  func releaseDuringEvaluationDirtiesCleanReaderBeforeRefresh() {
    let source = Stored(wrappedValue: 1)
    let model = Computed<ReleasedModel> { _ in
      ReleasedModel(count: source.wrappedValue)
    }
    let reader = WeakReleasedModelReader(model: model.wrappedValue)
    let observer = Computed<Int> { _ in
      reader.count
    }
    let downstream = Computed<Int> { _ in
      model.wrappedValue.count * 10 + observer.wrappedValue
    }

    #expect(downstream.wrappedValue == 11)

    // Refreshing `downstream` recomputes `model` first, releasing the value that the
    // clean `observer` read. The observer becomes dirty without locking the evaluating
    // downstream, so the same refresh recomputes it with the fallback.
    source.wrappedValue = 2

    #expect(downstream.wrappedValue == 20 + WeakReleasedModelReader.fallback)
    #expect(observer.potentiallyDirty == false)
  }

  @Test("Releasing a computed that read an evaluating upstream detaches it after unlock")
  func releasingComputedThatReadEvaluatingUpstream() {
    let identifiers = Stored(wrappedValue: [1, 2])
    let items = Computed<[ReleasedItem]> { _ in
      identifiers.wrappedValue.map(ReleasedItem.init(id:))
    }
    let itemCount = Computed<Int> { _ in
      items.wrappedValue.count
    }

    weak var firstItem: ReleasedItem?
    do {
      let firstItems = items.wrappedValue
      firstItem = firstItems.first
      for item in firstItems {
        item.bind(itemCount: itemCount)
        #expect(item.isLast.wrappedValue == (item.id == 2))
      }
    }
    #expect(itemCount.outgoingEdgesSnapshot().count == 2)

    identifiers.wrappedValue = [1, 2, 3]

    // Refreshing `itemCount` recomputes `items`, releasing the old items. Each old
    // `isLast` read `itemCount`, whose lock this thread holds during that refresh.
    #expect(itemCount.wrappedValue == 3)
    #expect(firstItem == nil)
    #expect(itemCount.outgoingEdgesSnapshot().isEmpty)
  }

#if DEBUG
  @Test("Releasing a node under an upstream evaluation lock does not deadlock a refreshing reader")
  func crossThreadReleaseDuringUpstreamEvaluation() async {
    await expectContendedAttempt(releaseDuringUpstreamEvaluationAttempt)
  }

  /// Releases the node from `model`'s evaluation while another thread refreshes its reader.
  ///
  /// - Returns: Whether the threads met with both locks held, or `nil` after a deadlock.
  private func releaseDuringUpstreamEvaluationAttempt() async -> Bool? {
    let source = Stored(wrappedValue: 1)
    let isGated = OSAllocatedUnfairLock(initialState: false)
    let upstreamEvaluationStarted = TestThreadSignal()
    let downstreamRefreshStarted = TestThreadSignal()
    let didMeet = OSAllocatedUnfairLock(initialState: false)

    let marker = Computed<Int> { _ in
      let value = source.wrappedValue
      if isGated.withLock({ $0 }) {
        downstreamRefreshStarted.signal()
      }
      return value
    }
    let model = Computed<ReleasedModel> { _ in
      let model = ReleasedModel(count: source.wrappedValue)
      if isGated.withLock({ $0 }) {
        upstreamEvaluationStarted.signal()
        let didRefreshStart = Self.waitInsideCommittedRead(for: downstreamRefreshStarted)
        didMeet.withLock { $0 = didRefreshStart }
      }
      return model
    }
    let downstream = Computed<Int> { _ in
      marker.wrappedValue + model.wrappedValue.count
    }

    #expect(downstream.wrappedValue == 2)

    isGated.withLock { $0 = true }
    source.wrappedValue = 2

    let upstreamFinished = TestSignal()
    let downstreamFinished = TestSignal()
    let downstreamValue = OSAllocatedUnfairLock(initialState: 0)

    // Holds `model`'s lock while replacing its value, whose `count` node `downstream` read.
    Thread {
      _ = model.wrappedValue
      upstreamFinished.signal()
    }.start()

    // Holds `downstream`'s lock while refreshing `marker`, then waits for `model`'s lock.
    Thread {
      upstreamEvaluationStarted.wait(until: Date().addingTimeInterval(5))
      let value = downstream.wrappedValue
      downstreamValue.withLock { $0 = value }
      downstreamFinished.signal()
    }.start()

    let didUpstreamFinish = await upstreamFinished.wait(for: .seconds(5))
    let didDownstreamFinish = await downstreamFinished.wait(for: .seconds(5))
    #expect(didUpstreamFinish)
    #expect(didDownstreamFinish)
    guard didUpstreamFinish, didDownstreamFinish else { return nil }

    #expect(downstreamValue.withLock { $0 } == 4)
    return didMeet.withLock { $0 }
  }

  @Test("Releasing a node read by another thread's first evaluation does not deadlock")
  func crossThreadReleaseDuringFirstEvaluation() async {
    await expectContendedAttempt(releaseDuringFirstEvaluationAttempt)
  }

  /// Releases a node that another thread's first evaluation read and still holds locked.
  ///
  /// A first evaluation is not dirty yet, so checking a dirty flag before locking could
  /// not avoid this release's wait for the downstream lock.
  ///
  /// - Returns: Whether the threads met with both locks held, or `nil` after a deadlock.
  private func releaseDuringFirstEvaluationAttempt() async -> Bool? {
    let source = Stored(wrappedValue: 1)
    let isGated = OSAllocatedUnfairLock(initialState: false)
    let downstreamReadReleasedNode = TestThreadSignal()
    let upstreamEvaluationStarted = TestThreadSignal()
    let didMeet = OSAllocatedUnfairLock(initialState: false)

    let model = Computed<ReleasedModel> { _ in
      let model = ReleasedModel(count: source.wrappedValue)
      if isGated.withLock({ $0 }) {
        upstreamEvaluationStarted.signal()
      }
      return model
    }
    let reader = WeakReleasedModelReader(model: model.wrappedValue)

    // Dirty `model` before `downstream` reads anything, so no write waits for its lock.
    source.wrappedValue = 2
    isGated.withLock { $0 = true }

    // Reads the current model's `count` node without depending on `model`, then waits
    // for another thread to recompute `model` before reading it.
    let downstream = Computed<Int> { _ in
      let releasedCount = reader.count
      downstreamReadReleasedNode.signal()
      let didUpstreamStart = Self.waitInsideCommittedRead(for: upstreamEvaluationStarted)
      didMeet.withLock { $0 = didUpstreamStart }
      return releasedCount + model.wrappedValue.count
    }

    let downstreamFinished = TestSignal()
    let upstreamFinished = TestSignal()

    Thread {
      _ = downstream.wrappedValue
      downstreamFinished.signal()
    }.start()

    // Holds `model`'s lock while releasing the value whose `count` node `downstream` read.
    Thread {
      downstreamReadReleasedNode.wait(until: Date().addingTimeInterval(5))
      _ = model.wrappedValue
      upstreamFinished.signal()
    }.start()

    let didDownstreamFinish = await downstreamFinished.wait(for: .seconds(5))
    let didUpstreamFinish = await upstreamFinished.wait(for: .seconds(5))
    #expect(didDownstreamFinish)
    #expect(didUpstreamFinish)
    guard didDownstreamFinish, didUpstreamFinish else { return nil }

    guard didMeet.withLock({ $0 }) else { return false }

    // The release came from another thread, so the evaluation it interrupted is stale.
    #expect(downstream.wrappedValue == WeakReleasedModelReader.fallback + 2)
    return true
  }

  // MARK: - Cross-thread attempts

  /// Waits inside a committed read until a peer thread signals from its own read.
  ///
  /// A transaction in a parallel test can close read admission before the peer's read
  /// begins. That publication waits for this read to finish, so the wait stops at once
  /// instead of stalling unrelated tests; the attempt is then retried.
  ///
  /// - Returns: `true` if the peer signaled, or `false` if a publication intervened.
  private static func waitInsideCommittedRead(for peerSignal: TestThreadSignal) -> Bool {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if peerSignal.wait(until: Date().addingTimeInterval(0.001)) {
        return true
      }
      if GraphTransactionCoordinator.shared.__testing__isReadAdmissionClosed() {
        return false
      }
    }
    return false
  }

  /// Retries `attempt` with fresh nodes until its threads meet with both locks held.
  private func expectContendedAttempt(_ attempt: () async -> Bool?) async {
    for _ in 0..<20 {
      switch await attempt() {
      case true?:
        return
      case false?:
        continue
      case nil:
        // The threads deadlocked and still own their node locks.
        return
      }
    }

    Issue.record("The release never ran while both evaluation locks were held.")
  }
#endif
}

private final class ReleasedModel {
  @GraphStored var count: Int

  init(count: Int) {
    self.count = count
  }
}

/// A model whose equality ignores its graph-backed count.
private final class IdentifiedReleasedModel: Equatable {
  let id: Int
  @GraphStored var count: Int

  init(id: Int, count: Int) {
    self.id = id
    self.count = count
  }

  static func == (lhs: IdentifiedReleasedModel, rhs: IdentifiedReleasedModel) -> Bool {
    lhs.id == rhs.id
  }
}

/// An item whose computed property reads a node derived from the collection that owns it.
private final class ReleasedItem: @unchecked Sendable {
  let id: Int
  private let isLastHolder = OSAllocatedUnfairLock<Computed<Bool>?>(uncheckedState: nil)

  var isLast: Computed<Bool> {
    isLastHolder.withLockUnchecked { $0! }
  }

  init(id: Int) {
    self.id = id
  }

  func bind(itemCount: Computed<Int>) {
    let id = id
    isLastHolder.withLockUnchecked {
      $0 = Computed { _ in itemCount.wrappedValue == id }
    }
  }
}

/// Reads a model through a weak reference without depending on the node that owns it.
private final class WeakReleasedModelReader: @unchecked Sendable {

  static let fallback = -1

  private weak var model: ReleasedModel?

  var count: Int {
    model?.count ?? Self.fallback
  }

  init(model: ReleasedModel) {
    self.model = model
  }
}
