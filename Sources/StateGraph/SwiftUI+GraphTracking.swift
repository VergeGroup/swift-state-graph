#if canImport(SwiftUI)

@preconcurrency import Combine
import SwiftUI

extension View {

  /// Starts a StateGraph tracking scope while this view is visible.
  ///
  /// Use this modifier when a SwiftUI view needs to host side effects that depend on
  /// StateGraph values, such as starting a service, logging derived state, or synchronizing
  /// external UI. The tracking scope starts when the view appears and is cancelled when the
  /// view disappears.
  ///
  /// The closure can call ``withGraphTrackingGroup(_:)`` and ``withGraphTrackingMap(_:onChange:isolation:)``
  /// just like a manually retained ``withGraphTracking(_:)`` subscription.
  ///
  /// ```swift
  /// content
  ///   .graphTracking {
  ///     withGraphTrackingGroup {
  ///       print(model.count)
  ///     }
  ///   }
  /// ```
  ///
  /// - Parameter scope: A closure that registers StateGraph tracking operations.
  /// - Returns: A view that keeps the tracking subscription alive while it is visible.
  public func graphTracking(
    _ scope: @MainActor @escaping () -> Void
  ) -> some View {
    modifier(
      GraphTrackingViewModifier(
        id: GraphTrackingStableID(),
        scope: scope
      )
    )
  }

  /// Starts a StateGraph tracking scope while this view is visible, restarting when an identity changes.
  ///
  /// Use this overload when the tracking closure captures a value that can be replaced while the
  /// view remains mounted. When `id` changes, the current subscription is cancelled and a new
  /// tracking scope is created with the latest closure.
  ///
  /// ```swift
  /// content
  ///   .graphTracking(id: model.id) {
  ///     withGraphTrackingMap {
  ///       model.count
  ///     } onChange: { count in
  ///       print(count)
  ///     }
  ///   }
  /// ```
  ///
  /// - Parameters:
  ///   - id: A value that identifies the dependencies captured by `scope`.
  ///   - scope: A closure that registers StateGraph tracking operations.
  /// - Returns: A view that keeps the tracking subscription alive while it is visible.
  public func graphTracking<ID: Equatable>(
    id: ID,
    _ scope: @MainActor @escaping () -> Void
  ) -> some View {
    modifier(
      GraphTrackingViewModifier(
        id: id,
        scope: scope
      )
    )
  }
}

private struct GraphTrackingStableID: Equatable {}

private struct GraphTrackingViewModifier<ID: Equatable>: ViewModifier {

  let id: ID
  let scope: @MainActor () -> Void

  func body(content: Content) -> some View {
    content
      .task(id: id) { @MainActor in
        let taskState = GraphTrackingTaskState()

        await withTaskCancellationHandler {
          let cancellable = withGraphTracking {
            scope()
          }
          taskState.setCancellable(cancellable)
          await taskState.waitUntilCancelled()
        } onCancel: {
          taskState.cancel()
        }
      }
  }
}

/// Holds a graph tracking subscription until its SwiftUI task is cancelled.
///
/// `withGraphTracking` returns a synchronous `AnyCancellable`, so the SwiftUI task must stay
/// alive to retain that cancellable until the view disappears or the task identity changes.
/// This state object keeps the subscription and the waiting continuation behind a lock so
/// cancellation can safely arrive before or after the subscription is created.
private final class GraphTrackingTaskState: @unchecked Sendable {

  private struct State {
    var cancellable: AnyCancellable?
    var continuation: CheckedContinuation<Void, Never>?
    var isCancelled = false
  }

  private let state = OSAllocatedUnfairLock(uncheckedState: State())

  func setCancellable(_ cancellable: AnyCancellable) {
    let shouldCancelImmediately = state.withLock { state in
      if state.isCancelled {
        return true
      }
      state.cancellable = cancellable
      return false
    }

    if shouldCancelImmediately {
      cancellable.cancel()
    }
  }

  func waitUntilCancelled() async {
    await withCheckedContinuation { continuation in
      let shouldResumeImmediately = state.withLock { state in
        if state.isCancelled {
          return true
        }
        state.continuation = continuation
        return false
      }

      if shouldResumeImmediately {
        continuation.resume()
      }
    }
  }

  func cancel() {
    let cancellation = state.withLock { state -> (AnyCancellable?, CheckedContinuation<Void, Never>?) in
      guard !state.isCancelled else {
        return (nil, nil)
      }
      state.isCancelled = true
      defer {
        state.cancellable = nil
        state.continuation = nil
      }
      return (state.cancellable, state.continuation)
    }

    cancellation.0?.cancel()
    cancellation.1?.resume()
  }
}

#endif
