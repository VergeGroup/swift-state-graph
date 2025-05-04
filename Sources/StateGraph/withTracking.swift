
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

private struct UnsafeSendable<V>: ~Copyable, @unchecked Sendable {
  
  let _value: V
  
  init(_ value: V) {
    _value = value
  }
  
}
