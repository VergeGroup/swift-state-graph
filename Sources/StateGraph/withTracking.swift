/// Tracks accesses to nodes within ``apply`` and notifies ``didChange`` once after changes occur.
/// To observe continuously, use ``withContinuousStateGraphTracking``.
func withStateGraphTracking(
  apply: () -> Void,
  didChange: @escaping @Sendable () -> Void
) {
  let registration = TrackingRegistration(didChange: didChange)
  TrackingRegistration.$registration.withValue(registration) {
    apply()
  }
}

/// Indicates whether continuous tracking should continue or stop.
public enum StateGraphTrackingContinuation: Sendable {
  case stop
  case next
}

/// Continuously tracks accesses to nodes while ``apply`` runs and invokes ``didChange`` after each batch of updates.
/// Tracking stops when ``didChange`` returns ``StateGraphTrackingContinuation.stop``.
func withContinuousStateGraphTracking(
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

/// Internal helper storing a change handler for tracking scopes.
public final class TrackingRegistration: Sendable, Hashable {

  public static func == (lhs: TrackingRegistration, rhs: TrackingRegistration) -> Bool {
    lhs === rhs
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(self))
  }

  /// Handler executed when a tracked property changes.
  private let didChange: @Sendable () -> Void

  init(didChange: @escaping @Sendable () -> Void) {
    self.didChange = didChange
  }

  /// Executes the stored change handler.
  func perform() {
    didChange()
  }

  /// The currently active registration in task-local storage.
  @TaskLocal
  static var registration: TrackingRegistration?
}

/// A simple wrapper that marks a value as ``Sendable``.
struct UnsafeSendable<V>: ~Copyable, @unchecked Sendable {

  /// Wrapped value.
  let _value: V

  init(_ value: V) {
    _value = value
  }

}

/// Executes ``closure`` on the specified ``isolation`` actor.
func perform<Return>(_ closure: () -> Return, isolation: isolated (any Actor)? = #isolation)
  -> Return
{
  closure()
}
