import Observation

/// Tracks access to the properties of StoredNode or Computed.
/// Similarly to Observation.withObservationTracking, didChange runs one time after property changes applied.
/// Callback delivery is enqueued asynchronously. An actor-isolated callback returns to that actor;
/// a nonisolated callback runs on an unspecified executor.
/// To observe properties continuously, use ``withContinuousStateGraphTracking``.
@discardableResult
func withStateGraphTracking<R>(
  apply: () -> R,
  didChange: @escaping () -> Void,
  isolation: isolated (any Actor)? = #isolation
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
    let registration = TrackingRegistration(
      didChange: didChange,
      isolation: isolation
    )
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
  withStateGraphTracking(
    apply: apply.closure,
    didChange: {
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
    },
    isolation: isolation
  )
}

@available(*, deprecated, renamed: "GraphObservation.init(_:)")
public func withStateGraphTrackingStream<T: Sendable>(
  apply: @escaping @isolated(any) @Sendable () -> T,
  isolation: isolated (any Actor)? = #isolation
) -> GraphObservation<T> {
  GraphObservation(apply)
}

// MARK: - Internals

/// Delivers a one-shot invalidation callback in its requested isolation context.
///
/// Delivery is always enqueued in a task. When an actor was captured at registration time, the
/// callback returns to that actor. Without an actor, it executes on an unspecified executor.
///
/// `@unchecked Sendable` deliberately localizes the existing internal transport of a non-`Sendable`
/// callback. It doesn't make the closure's captures thread-safe. The recorded isolation determines
/// where an actor-isolated callback executes, while `nil` retains the unspecified-executor contract.
private struct TrackingInvalidationCallback: @unchecked Sendable {

  private let closure: () -> Void
  private let isolation: (any Actor)?

  init(
    closure: @escaping () -> Void,
    isolation: isolated (any Actor)?
  ) {
    self.closure = closure
    self.isolation = isolation
  }

  func callAsFunction() {
    Task { [self] in
      if let isolation {
        await perform(isolation: isolation)
      } else {
        perform()
      }
    }
  }

  private func perform() {
    closure()
  }

  private func perform(isolation: isolated (any Actor)) {
    closure()
  }
}

/// A one-shot record of the State Graph nodes read during one tracking pass.
///
/// StateGraph creates a fresh registration for each execution of a continuous tracking API and
/// installs it as the current tracking context while that execution reads nodes. Each accessed
/// node retains the registration until an eligible change captures and invalidates it.
///
/// The first eligible invalidation delivers the registration's change callback. Further
/// invalidations are ignored, and the next continuous tracking pass creates a new registration
/// for its newly read dependencies.
///
/// You don't create or manage registrations directly. Use ``withGraphTracking(_:)`` together with
/// ``withGraphTrackingGroup(_:isolation:)`` or a graph tracking map instead.
///
/// For the complete lifecycle, notification filtering, self-invalidation behavior, and concurrent
/// rerun invariant, see <doc:Tracking-Registrations>.
public final class TrackingRegistration: Sendable, Hashable {

  private struct State: Sendable {
    var isInvalidated: Bool = false
#if DEBUG
    var hasEmittedSelfInvalidationWarning = false
#endif
    let didChange: TrackingInvalidationCallback
  }

  public static func == (lhs: TrackingRegistration, rhs: TrackingRegistration) -> Bool {
    lhs === rhs
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(self))
  }

  private let state: OSAllocatedUnfairLock<State>

  init(
    didChange: @escaping () -> Void,
    isolation: isolated (any Actor)? = #isolation
  ) {
    self.state = .init(uncheckedState:
      .init(
        didChange: .init(
          closure: didChange,
          isolation: isolation
        )
      )
    )
  }

  func perform() {
#if DEBUG
    let isSelfInvalidationWarningEnabled = StateGraphDiagnostics.isSelfInvalidationWarningEnabled
#endif

    let invalidation: (
      didChange: TrackingInvalidationCallback?,
      shouldEmitSelfInvalidationWarning: Bool
    ) = state.withLock { state in
      guard state.isInvalidated == false else {
        return (nil, false)
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
      // Without this identity check, the active registration would invoke its
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
          return (nil, true)
        }
#endif
        return (nil, false)
      }

      state.isInvalidated = true

      return (state.didChange, false)
    }

    invalidation.didChange?()

#if DEBUG
    if invalidation.shouldEmitSelfInvalidationWarning {
      Log.logSuppressedSelfInvalidation()
    }
#endif
  }

}
