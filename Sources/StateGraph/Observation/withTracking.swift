import Observation

/// Tracks access to the properties of StoredNode or Computed.
/// Similarly to Observation.withObservationTracking, didChange runs one time after property changes applied.
/// To observe properties continuously, use ``withContinuousStateGraphTracking``.
@discardableResult
func withStateGraphTracking<R>(
  apply: () -> R,
  @_inheritActorContext didChange: @escaping @isolated(any) @Sendable () -> Void
) -> R {
  #if false  // #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    return withObservationTracking(
      apply,
      onChange: {
        Task {
          await didChange()
        }
      }
    )
  #else
    /// Need this for now as https://github.com/VergeGroup/swift-state-graph/pull/79
    let registration = TrackingRegistration(didChange: didChange)
    return ThreadLocal.registration.withValue(registration) {
      apply()
    }
  #endif

}

public enum StateGraphTrackingContinuation: Sendable {
  case stop
  case next
}

// MARK: - Internal Types

struct UnsafeSendable<V>: ~Copyable, @unchecked Sendable {

  let _value: V

  init(_ value: consuming V) {
    _value = value
  }

}

/// A box that wraps a closure to prevent thunk stack growing during recursive calls.
/// By wrapping closures in this struct and passing the struct instead of the raw closure,
/// we avoid the overhead of repeatedly wrapping/unwrapping closure types.
struct ClosureBox<R> {
  let closure: () -> R

  init(_ closure: @escaping () -> R) {
    self.closure = closure
  }

  func callAsFunction() -> R {
    closure()
  }
}

/// Owns a tracking handler's lifetime and serializes its execution.
///
/// The state lock is held only while updating invocation state. The handler runs
/// after the lock is released so it may cancel its own tracking scope safely.
final class GraphTrackingHandler: @unchecked Sendable {

  /// Immutable closure storage whose execution is serialized by the owning state machine.
  private struct Handler: @unchecked Sendable {
    let closure: () -> Void

    func callAsFunction() {
      closure()
    }
  }

  private struct State {
    var handler: Handler?
    var isInvoking = false
    var needsInvocation = false
  }

  private let state: OSAllocatedUnfairLock<State>

  init(_ handler: @escaping () -> Void) {
    self.state = .init(
      uncheckedState: .init(handler: .init(closure: handler))
    )
  }

  var isCancelled: Bool {
    state.withLock { $0.handler == nil }
  }

  func invoke() {
    let shouldDrain = state.withLock { state in
      guard state.handler != nil else { return false }

      state.needsInvocation = true
      guard !state.isInvoking else { return false }

      state.isInvoking = true
      return true
    }

    guard shouldDrain else { return }

    while let handler = takeNextHandler() {
      handler()
    }
  }

  func cancel() {
    state.withLock { state in
      state.handler = nil
      state.needsInvocation = false
    }
  }

  private func takeNextHandler() -> Handler? {
    state.withLock { state in
      guard state.needsInvocation, let handler = state.handler else {
        state.isInvoking = false
        return nil
      }

      state.needsInvocation = false
      return handler
    }
  }
}

func perform<Return>(
  _ closure: () -> Return,
  isolation: isolated (any Actor)? = #isolation
) -> Return {
  closure()
}

func perform<Return>(
  _ box: ClosureBox<Return>,
  isolation: isolated (any Actor)? = #isolation
) -> Return {
  box()
}

// MARK: - Continuous Tracking

/// Tracks access to the properties of StoredNode or Computed.
/// Continuously tracks until `didChange` returns `.stop`.
/// It does not provides update of the properties granurarly. some frequency of updates may be aggregated into single event.
func withContinuousStateGraphTracking<R>(
  apply: @escaping () -> R,
  didChange: @escaping () -> StateGraphTrackingContinuation,
  isolation: isolated (any Actor)? = #isolation
) {
  // Wrap closures in ClosureBox to prevent thunk stack growing during recursive calls.
  // The boxes are created once here and passed through all recursive iterations.
  let applyBox = ClosureBox(apply)
  let didChangeBox = ClosureBox(didChange)
  _withContinuousStateGraphTracking(
    apply: applyBox,
    didChange: didChangeBox,
    isolation: isolation
  )
}

/// Private implementation that receives pre-wrapped closures to prevent thunk stack growing.
/// By passing ClosureBox<...> directly in recursive calls, we avoid
/// the cost of re-wrapping/unwrapping closure types on each iteration.
private func _withContinuousStateGraphTracking<R>(
  apply: ClosureBox<R>,
  didChange: ClosureBox<StateGraphTrackingContinuation>,
  isolation: isolated (any Actor)? = #isolation
) {
  withStateGraphTracking(apply: apply.closure) {
    let continuation = perform(didChange, isolation: isolation)
    switch continuation {
    case .stop:
      break
    case .next:
      // continue tracking on next event loop.
      // It uses isolation and task dispatching to ensure apply closure is called on the same actor.
      // Pass the already-wrapped closures directly to avoid thunk stack growing.
      _withContinuousStateGraphTracking(
        apply: apply,
        didChange: didChange,
        isolation: isolation
      )
    }
  }
}

/// Creates an `AsyncStream` that emits projected values whenever tracked StateGraph nodes change.
///
/// This function provides a convenient way to observe StateGraph node changes using Swift's
/// async/await concurrency model. The stream emits the current value immediately upon iteration,
/// then emits new values whenever any accessed node changes.
///
/// ## Basic Usage
/// ```swift
/// let counter = Stored(wrappedValue: 0)
///
/// for await value in withStateGraphTrackingStream(apply: {
///   counter.wrappedValue
/// }) {
///   print("Counter: \(value)")
/// }
/// ```
///
/// ## Important: Single-Consumer Stream
///
/// This function returns an `AsyncStream`, which is **single-consumer**.
/// When multiple iterators consume the same stream, values are distributed between them
/// in a racing manner rather than being duplicated to each iterator.
///
/// ```swift
/// let stream = withStateGraphTrackingStream { model.counter }
///
/// // ⚠️ Values are NOT duplicated - they compete for values
/// let taskA = Task { for await v in stream { print("A: \(v)") } }
/// let taskB = Task { for await v in stream { print("B: \(v)") } }
/// // Output might be: A: 0, B: 1, A: 2 (racing behavior)
/// ```
///
/// ## Multi-Consumer Alternative
///
/// If you need multiple independent consumers that each receive all values,
/// use ``GraphTrackings`` instead (available on iOS 18+):
///
/// ```swift
/// // Each iterator gets its own independent stream of all values
/// let trackings = GraphTrackings { model.counter }
///
/// let taskA = Task { for await v in trackings { print("A: \(v)") } }
/// let taskB = Task { for await v in trackings { print("B: \(v)") } }
/// // Output: A: 0, B: 0, A: 1, B: 1, A: 2, B: 2 (both receive all values)
/// ```
///
/// ## Comparison Table
///
/// | Feature | `withStateGraphTrackingStream` | `GraphTrackings` |
/// |---------|-------------------------------|------------------|
/// | Return Type | `AsyncStream<T>` | `AsyncSequence` |
/// | Consumer Model | Single-consumer | Multi-consumer |
/// | Value Distribution | Racing (values split) | Duplicated (all receive) |
/// | iOS Availability | iOS 13+ | iOS 18+ |
///
/// - Parameters:
///   - apply: A closure that accesses StateGraph nodes and returns a projected value.
///            This closure is called initially and whenever tracked nodes change.
///   - isolation: The actor isolation context for the tracking. Defaults to the caller's isolation.
///
/// - Returns: An `AsyncStream` that emits the projected value from `apply` whenever tracked nodes change.
///
/// - Note: The stream automatically handles cancellation. When the consuming task is cancelled,
///         the internal tracking stops.
///
/// - SeeAlso: ``GraphTrackings`` for multi-consumer scenarios
/// - SeeAlso: ``withContinuousStateGraphTracking(_:didChange:isolation:)`` for callback-based tracking
public func withStateGraphTrackingStream<T>(
  apply: @escaping () -> T,
  isolation: isolated (any Actor)? = #isolation
) -> AsyncStream<T> {
  
  AsyncStream<T> { (continuation: AsyncStream<T>.Continuation) in
    
    let isCancelled = OSAllocatedUnfairLock(initialState: false)
    
    continuation.onTermination = { termination in
      isCancelled.withLock { $0 = true }
    }
    
    withContinuousStateGraphTracking(
      apply: {
        let value = apply()
        continuation.yield(value)
      },
      didChange: {
        if isCancelled.withLock({ $0 }) {
          return .stop
        }
        return .next
      },
      isolation: isolation
    )

  }
}

// MARK: - Internals

public final class TrackingRegistration: Sendable, Hashable {

  private struct State: Sendable {
    var isInvalidated: Bool = false
#if DEBUG
    var hasEmittedSelfInvalidationWarning = false
#endif
    let didChange: @isolated(any) @Sendable () -> Void
  }

  public static func == (lhs: TrackingRegistration, rhs: TrackingRegistration) -> Bool {
    lhs === rhs
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(self))
  }

  private let state: OSAllocatedUnfairLock<State>

  init(didChange: @escaping @isolated(any) @Sendable () -> Void) {
    self.state = .init(uncheckedState:
      .init(
        didChange: didChange
      )
    )
  }

  func perform() {
#if DEBUG
    let isSelfInvalidationWarningEnabled = StateGraphDiagnostics.isSelfInvalidationWarningEnabled
#endif

    let shouldEmitSelfInvalidationWarning = state.withLock { state in
      guard state.isInvalidated == false else {
        return false
      }
      
      // Re-entry Prevention Guard
      // =========================
      //
      // `_Stored` evaluates its notification predicate before calling `perform()`:
      //
      // - Equatable values notify only when `oldValue != newValue`.
      // - Non-Equatable reference values notify only when their identity changes.
      // - Values without either comparison use the default predicate and notify
      //   for every assignment.
      //
      // Assignments filtered by that predicate never reach this method. This means
      // that assigning the same `Int`, for example, is already handled by `_Stored`
      // and does not exercise this guard. Changed values and assignments that use
      // the always-notify predicate still need explicit re-entry protection here.
      //
      // During a tracking handler's execution, `withStateGraphTracking` stores its
      // registration in `ThreadLocal.registration`. Reading a node then adds that
      // registration to the node's set of observers. If the same handler mutates
      // the node before it finishes, the setter asks every captured registration
      // to perform, including the registration that is currently executing.
      //
      // Without this identity check, the active registration would schedule its
      // own `didChange` closure. Continuous tracking would run the handler again,
      // install a new registration, perform the same mutation, and repeat the cycle.
      //
      // Only the currently executing registration is suppressed. Other handlers
      // observing the same node have different registrations, so they must still be
      // invalidated and receive the update normally.
      //
      // For example, a non-Equatable value uses the always-notify predicate:
      //
      //   struct Value: Sendable { var rawValue: Int }
      //   let node = Stored(wrappedValue: Value(rawValue: 0))
      //
      //   withGraphTracking {
      //     withGraphTrackingGroup {
      //       let value = node.wrappedValue
      //       node.wrappedValue = value
      //     }
      //   }
      //
      // Although the stored properties are unchanged, the assignment is
      // notification-worthy because `Value` has no equality predicate. This guard
      // prevents that group from re-entering itself while allowing peer groups to
      // observe the assignment.
      if ThreadLocal.registration.value == self {
#if DEBUG
        if isSelfInvalidationWarningEnabled, state.hasEmittedSelfInvalidationWarning == false {
          state.hasEmittedSelfInvalidationWarning = true
          return true
        }
#endif
        return false
      }
      
      state.isInvalidated = true
      
      let closure = state.didChange
      Task {
        await closure()
      }
      return false
    }

#if DEBUG
    if shouldEmitSelfInvalidationWarning {
      Log.logSuppressedSelfInvalidation()
    }
#endif
  }

}
