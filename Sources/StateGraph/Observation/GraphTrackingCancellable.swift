
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

  /// Weak parent storage accessed only while the owning cancellable state is locked.
  private final class WeakParent {
    weak var value: GraphTrackingCancellable?
  }

  private struct State {
    var onCancel: (() -> Void)?
    var children: [GraphTrackingCancellable] = []
    var isCancelled = false
    let parent = WeakParent()
  }

  /// Immutable work extracted from the lock and consumed synchronously by `cancel()`.
  private struct CancellationWork: @unchecked Sendable {
    let parent: GraphTrackingCancellable?
    let children: [GraphTrackingCancellable]
    let onCancel: (() -> Void)?
  }

  private let state: OSAllocatedUnfairLock<State>

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
    let didAdd = state.withLock { state in
      guard !state.isCancelled else { return false }
      state.children.append(child)
      return true
    }

    guard didAdd else {
      child.cancel()
      return
    }

    guard child.attach(to: self) else {
      removeChild(child)
      return
    }
  }

  private func attach(to parent: GraphTrackingCancellable) -> Bool {
    state.withLock { state in
      guard !state.isCancelled else { return false }

      if let currentParent = state.parent.value, currentParent !== parent {
        assertionFailure("A graph tracking cancellable cannot have multiple parents.")
        return false
      }

      state.parent.value = parent
      return true
    }
  }

  private func detachParent(if parent: GraphTrackingCancellable) {
    state.withLock { state in
      guard state.parent.value === parent else { return }
      state.parent.value = nil
    }
  }

  private func removeChild(_ child: GraphTrackingCancellable) {
    state.withLock { state in
      state.children.removeAll { $0 === child }
    }
  }

  /// Cancels all children without cancelling this cancellable.
  ///
  /// Call this method when re-executing a group/map to clean up
  /// nested subscriptions before recreating them.
  ///
  /// - Note: After calling this method, children are removed from this parent.
  func cancelChildren() {
    let children = state.withLock { state in
      let children = state.children
      state.children.removeAll()
      return children
    }

    for child in children {
      child.detachParent(if: self)
      child.cancel()
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
    guard let work = state.withLock({ state -> CancellationWork? in
      guard !state.isCancelled else { return nil }

      state.isCancelled = true
      let work = CancellationWork(
        parent: state.parent.value,
        children: state.children,
        onCancel: state.onCancel
      )

      state.parent.value = nil
      state.children.removeAll()
      state.onCancel = nil
      return work
    }) else {
      return
    }

    work.parent?.removeChild(self)

    for child in work.children {
      child.detachParent(if: self)
      child.cancel()
    }

    work.onCancel?()
  }
}
