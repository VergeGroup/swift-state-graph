
/**
 Tracks access to the properties of the instance compatible with ``GraphViewType``. 
 Similarly to Observation.withObservationTracking, didChange runs one time after property changes applied.
 To observe properties continuously, use ``withContinuousStateGraphTracking``.
 */
public func withStateGraphTracking(
  apply: () -> Void,
  didChange: @escaping @Sendable () -> Void
) {
  let registration = TrackingRegistration(didChange: didChange)
  TrackingRegistration.$registration.withValue(registration) { 
    apply()
  }
}

public enum StateGraphTrackingContinuation {
  case stop
  case next
}

/**
 Tracks access to the properties of the instance compatible with ``GraphViewType``. 
 Continuously tracks until `didChange` returns `.stop`.
 It does not provides update of the properties granurarly. some frequency of updates may be aggregated into single event.
 */
public func withContinuousStateGraphTracking(
  apply: @escaping () -> Void,
  didChange: @escaping @Sendable () -> StateGraphTrackingContinuation,
  isolation: isolated (any Actor)? = #isolation
) {
  
  let applyBox = UnsafeSendable(apply) 
      
  withStateGraphTracking(apply: apply) { 
    let continuation = didChange()
    switch continuation {
    case .stop:
      break
    case .next:
      // continue tracking on next event loop.
      // It uses isolation and task dispatching to ensure apply closure is called on the same actor.
      Task {
        await withContinuousStateGraphTracking(
          apply: applyBox._value,
          didChange: didChange,
          isolation: isolation
        )
      }
      
    }
  }
}

public func withStateGraphTrackingStream(
  apply: @escaping () -> Void
) -> AsyncStream<StateGraphTrackingContinuation> {
  
  return AsyncStream { continuation in
    withContinuousStateGraphTracking(apply: apply) { 
      continuation.yield(.next)
      return .next
    }
  }
}

// MARK: - Internals

final class TrackingRegistration: Sendable, Hashable {
  
  static func == (lhs: TrackingRegistration, rhs: TrackingRegistration) -> Bool {
    lhs === rhs
  }
  
  func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(self))
  }
  
  private let didChange: @Sendable () -> Void
  
  init(didChange: @escaping @Sendable () -> Void) {
    self.didChange = didChange
  }
  
  func perform() {
    didChange()
  }
  
  @TaskLocal
  static var registration: TrackingRegistration?
}

private struct UnsafeSendable<V>: ~Copyable, @unchecked Sendable {
  
  let _value: V
  
  init(_ value: V) {
    _value = value
  }
  
}
