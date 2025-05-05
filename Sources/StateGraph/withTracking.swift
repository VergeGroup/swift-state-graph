/// Tracks access to the properties of StoredNode or ComputedNode.
/// Similarly to Observation.withObservationTracking, didChange runs one time after property changes applied.
/// To observe properties continuously, use ``withContinuousStateGraphTracking``.
public func withStateGraphTracking(
  apply: () -> Void,
  didChange: @escaping @Sendable () -> Void
) {
  let registration = TrackingRegistration(didChange: didChange)
  TrackingRegistration.$registration.withValue(registration) {
    apply()
  }
}

public enum StateGraphTrackingContinuation: Sendable {
  case stop
  case next
}

/// Tracks access to the properties of StoredNode or ComputedNode.
/// Continuously tracks until `didChange` returns `.stop`.
/// It does not provides update of the properties granurarly. some frequency of updates may be aggregated into single event.
public func withContinuousStateGraphTracking(
  apply: @escaping () -> Void,
  didChange: @escaping () -> StateGraphTrackingContinuation,
  isolation: isolated (any Actor)? = #isolation
) {

  let applyBox = UnsafeSendable(apply)
  let didChangeBox = UnsafeSendable(didChange)

  withStateGraphTracking(apply: apply) {
    Task {
      let continuation = await perform(didChangeBox._value, isolation: isolation)
      switch continuation {
      case .stop:
        break
      case .next:
        // continue tracking on next event loop.
        // It uses isolation and task dispatching to ensure apply closure is called on the same actor.
        await withContinuousStateGraphTracking(
          apply: applyBox._value,
          didChange: didChangeBox._value,
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

private func perform<Return>(_ closure: () -> Return, isolation: isolated (any Actor)? = #isolation)
  -> Return
{
  closure()
}
