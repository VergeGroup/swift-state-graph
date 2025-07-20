/// Tracks access to the properties of StoredNode or Computed.
/// Similarly to Observation.withObservationTracking, didChange runs one time after property changes applied.
/// To observe properties continuously, use ``withContinuousStateGraphTracking``.
func withStateGraphTracking(
  apply: () -> Void,
  didChange: @escaping @Sendable (TrackingRegistration) -> Void
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

/// Tracks access to the properties of StoredNode or Computed.
/// Continuously tracks until `didChange` returns `.stop`.
/// It does not provides update of the properties granurarly. some frequency of updates may be aggregated into single event.
func withContinuousStateGraphTracking(
  apply: @escaping () -> Void,
  didChange: @escaping () -> StateGraphTrackingContinuation,
  isolation: isolated (any Actor)? = #isolation
) {
  
  let applyBox = UnsafeSendable(apply)
  let didChangeBox = UnsafeSendable(didChange)
  
  let registration = TrackingRegistration(didChange: { trackingRegistration in
    Task {
      let continuation = await perform(didChangeBox._value, isolation: isolation)
      switch continuation {
      case .stop:
        break
      case .next:
        // continue tracking on next event loop.
        // It uses isolation and task dispatching to ensure apply closure is called on the same actor.
        await Task.yield()
        await _withContinuousStateGraphTracking(
          apply: applyBox._value,
          trackingRegistration: trackingRegistration,
          isolation: isolation
        )
      }
    }
  })
  
  _withContinuousStateGraphTracking(apply: apply, trackingRegistration: registration)
}

@inline(__always)
private func _withContinuousStateGraphTracking(
  apply: @escaping () -> Void,
  trackingRegistration: TrackingRegistration,
  isolation: isolated (any Actor)? = #isolation
) {
  
  let applyBox = UnsafeSendable(apply)
     
  TrackingRegistration.$registration.withValue(trackingRegistration) {
    apply()
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

public final class TrackingRegistration: Sendable, Hashable {
  
  public struct Context: Sendable {
    public let nodeInfo: NodeInfo
    
    init(nodeInfo: NodeInfo) {
      self.nodeInfo = nodeInfo
    }
  }

  public static func == (lhs: TrackingRegistration, rhs: TrackingRegistration) -> Bool {
    lhs === rhs
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(self))
  }

  private let didChange: @Sendable (TrackingRegistration) -> Void

  init(didChange: @escaping @Sendable (TrackingRegistration) -> Void) {
    self.didChange = didChange
  }

  func perform(context: Context?) {
    Self.$context.withValue(context) {
      didChange(self)
    }
  }
  
  @TaskLocal
  static var context: Context?

  @TaskLocal
  static var registration: TrackingRegistration?
}

public func _printStateGraphChanged() {
  guard let context = TrackingRegistration.context else {
    print("Unknown context for state graph tracking")
    return
  }
  let nodeInfo = context.nodeInfo
  print("\(nodeInfo.name) @ \(nodeInfo.sourceLocation.file):\(nodeInfo.sourceLocation.line)")
}

struct UnsafeSendable<V>: ~Copyable, @unchecked Sendable {

  let _value: V

  init(_ value: consuming V) {
    _value = value
  }

}

func perform<Return>(_ closure: () -> Return, isolation: isolated (any Actor)? = #isolation)
  -> Return
{
  closure()
}
