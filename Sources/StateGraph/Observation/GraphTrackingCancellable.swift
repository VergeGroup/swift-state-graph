
import Combine

/// A tree-structured Cancellable that manages hierarchical subscription lifecycles.
///
/// This class enables nested tracking within `withGraphTracking` scopes.
/// When a parent group/map re-executes, all its children are automatically cancelled
/// and recreated, preventing subscription accumulation and ensuring correct behavior.
///
/// ## Key Features
/// - Supports parent-child relationships between cancellables
/// - Children are automatically cancelled when parent re-executes
/// - Conforms to `Cancellable` for compatibility with `AnyCancellable`
/// - Thread-safe using `OSAllocatedUnfairLock`
///
/// ## Nested Tracking Example
///
/// This class powers the nested tracking behavior in `withGraphTrackingGroup` and
/// `withGraphTrackingMap`. The following example shows conditional nested tracking:
///
/// ```swift
/// let enableA = Stored(wrappedValue: true)
/// let enableB = Stored(wrappedValue: false)
/// let valueA = Stored(wrappedValue: 1)
/// let valueB = Stored(wrappedValue: 2)
///
/// withGraphTracking {
///   withGraphTrackingGroup {
///     if enableA.wrappedValue {
///       withGraphTrackingGroup {
///         // This nested group is created/destroyed based on enableA
///         print("Feature A: \(valueA.wrappedValue)")
///       }
///     }
///
///     if enableB.wrappedValue {
///       withGraphTrackingGroup {
///         print("Feature B: \(valueB.wrappedValue)")
///       }
///     }
///   }
/// }
/// ```
///
/// When `enableA` changes from `true` to `false`, the nested group tracking `valueA`
/// is automatically cancelled. When it changes back to `true`, a new nested group is created.
final class GraphTrackingCancellable: Cancellable, @unchecked Sendable {

  private struct State {
    var onCancel: (() -> Void)?
    var children: [GraphTrackingCancellable] = []
  }

  private let state: OSAllocatedUnfairLock<State>
  private weak var parent: GraphTrackingCancellable?

  init(onCancel: @escaping () -> Void = {}) {
    self.state = OSAllocatedUnfairLock(uncheckedState: State(onCancel: onCancel))
  }

  /// Adds a child cancellable to this parent.
  ///
  /// The child will be cancelled when:
  /// - `cancelChildren()` is called (during parent re-execution)
  /// - `cancel()` is called on this parent
  ///
  /// - Parameter child: The child cancellable to add.
  func addChild(_ child: GraphTrackingCancellable) {
    child.parent = self
    state.withLock { $0.children.append(child) }
  }

  /// Removes this cancellable from its parent's children list.
  private func removeFromParent() {
    parent?.state.withLock { state in
      state.children.removeAll { $0 === self }
    }
    parent = nil
  }

  /// Cancels all children without cancelling this cancellable.
  ///
  /// Call this method when re-executing a group/map to clean up
  /// nested subscriptions before recreating them.
  ///
  /// - Note: After calling this method, children are removed from this parent.
  func cancelChildren() {
    state.withLock { state in
      for child in state.children {
        // Prevent child from calling removeFromParent during cancel
        child.parent = nil
        child.cancel()
      }
      state.children.removeAll()
    }
  }

  /// Cancels this cancellable and all its children.
  ///
  /// This method:
  /// 1. Removes itself from its parent's children list
  /// 2. Recursively cancels all children
  /// 3. Calls the onCancel closure
  ///
  /// - Note: Conforms to `Cancellable` protocol.
  func cancel() {
    // Remove from parent first
    removeFromParent()

    state.withLock { state in
      // Cancel all children
      for child in state.children {
        // Prevent child from calling removeFromParent during cancel
        child.parent = nil
        child.cancel()
      }
      state.children.removeAll()

      // Call onCancel closure
      state.onCancel?()
      state.onCancel = nil
    }
  }
}
