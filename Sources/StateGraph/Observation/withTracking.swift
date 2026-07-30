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

@available(*, deprecated, renamed: "GraphObservation.init(_:)")
public func withStateGraphTrackingStream<T: Sendable>(
  apply: @escaping @isolated(any) @Sendable () -> T,
  isolation: isolated (any Actor)? = #isolation
) -> GraphObservation<T> {
  GraphObservation(apply)
}

// MARK: - Internals

public final class TrackingRegistration: Sendable, Hashable {

  private struct State: Sendable {
    var isInvalidated: Bool = false
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
    state.withLock { state in
      guard state.isInvalidated == false else {
        return
      }
      
      // Re-entry Prevention Guard
      // ========================
      //
      // Problem: Infinite loop when setting unchanged values within tracking handlers
      //
      // Scenario:
      // 1. withGraphTrackingGroup { ... } establishes a tracking context
      // 2. Inside the handler, we read a node's value (e.g., node.wrappedValue)
      // 3. We set the same value back (e.g., node.wrappedValue = value)
      // 4. The setter ALWAYS triggers tracking registrations (no equality check)
      // 5. This calls perform() on the same registration that's currently executing
      // 6. The handler runs again, repeating steps 2-5 infinitely
      //
      // Solution:
      // Check if the registration trying to perform is the SAME as the one currently
      // executing (stored in TaskLocal). If so, skip re-execution to break the cycle.
      //
      // How it works:
      // - TrackingRegistration.registration is a @TaskLocal that holds the currently
      //   executing registration during handler execution
      // - If `self` (the registration being performed) matches the TaskLocal value,
      //   we're attempting to re-enter the same handler
      // - Return early to prevent the infinite loop
      //
      // Example:
      //   let node = Stored(wrappedValue: 42)
      //   withGraphTracking {
      //     withGraphTrackingGroup {
      //       let value = node.wrappedValue  // Establishes tracking
      //       node.wrappedValue = value      // Without this guard, would loop infinitely
      //     }
      //   }
      //
      // This behavior is similar to Apple's Observation framework.
      if ThreadLocal.registration.value == self {
        return
      }
      
      state.isInvalidated = true
      
      let closure = state.didChange
      Task {
        await closure()
      }
    }
  }

}
