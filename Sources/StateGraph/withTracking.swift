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
    let registration = TrackingRegistration(didChange: didChange)
    return TrackingRegistration.$registration.withValue(registration) {
      apply()
    }
  #endif

}

public enum StateGraphTrackingContinuation: Sendable {
  case stop
  case next
}

/// Tracks access to the properties of StoredNode or Computed.
/// Continuously tracks until `didChange` returns `.stop`.
/// It does not provides update of the properties granurarly. some frequency of updates may be aggregated into single event.
func withContinuousStateGraphTracking<R>(
  apply: @escaping () -> R,
  didChange: @escaping () -> StateGraphTrackingContinuation,
  isolation: isolated (any Actor)? = #isolation
) {

  let applyBox = UnsafeSendable(apply)
  let didChangeBox = UnsafeSendable(didChange)

  withStateGraphTracking(apply: apply) {
    let continuation = perform(didChangeBox._value, isolation: isolation)
    switch continuation {
    case .stop:
      break
    case .next:
      // continue tracking on next event loop.
      // It uses isolation and task dispatching to ensure apply closure is called on the same actor.
      withContinuousStateGraphTracking(
        apply: applyBox._value,
        didChange: didChangeBox._value,
        isolation: isolation
      )
    }
  }
}

func withStateGraphTrackingStream(
  apply: @escaping () -> Void
) -> AsyncStream<Void> {

  AsyncStream<Void> { (continuation: AsyncStream<Void>.Continuation) in

    let isCancelled = OSAllocatedUnfairLock(initialState: false)

    continuation.onTermination = { termination in
      isCancelled.withLock { $0 = true }
    }

    withContinuousStateGraphTracking(apply: apply) {
      continuation.yield()
      if isCancelled.withLock({ $0 }) {
        return .stop
      }
      return .next
    }
  }
}

// MARK: - Internals

public struct TrackingRegistration: Sendable, Hashable {

  private struct State {
    var isInvalidated: Bool = false
    let didChange: @isolated(any) @Sendable () -> Void
  }

  public struct Context: Sendable {
    public let nodeInfo: NodeInfo

    init(nodeInfo: NodeInfo) {
      self.nodeInfo = nodeInfo
    }
  }

  private let state: _ManagedCriticalState<State>

  init(didChange: @escaping @isolated(any) @Sendable () -> Void) {
    self.state = _ManagedCriticalState<State>(
      .init(
        didChange: didChange
      )
    )
  }

  func perform() {
    state.withCriticalRegion { state in
      guard state.isInvalidated == false else {
        return
      }
      state.isInvalidated = true
      let closure = state.didChange
      Task {
        await closure()
      }
    }
  }

  @TaskLocal
  static var registration: TrackingRegistration?
}

struct UnsafeSendable<V>: ~Copyable, @unchecked Sendable {

  let _value: V

  init(_ value: consuming V) {
    _value = value
  }

}

func perform<Return>(
  _ closure: () -> Return,
  isolation: isolated (any Actor)? = #isolation
)
  -> Return
{
  closure()
}
