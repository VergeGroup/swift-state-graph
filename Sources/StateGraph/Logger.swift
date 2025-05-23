import os.log

/// Convenience logging categories used by the framework.
enum Log {
  
  /// Generic logger active only in debug builds.
  static let generic = Logger(OSLog.makeOSLogInDebug { OSLog.init(subsystem: "state-graph", category: "generic") })
  
}

extension OSLog {
  
  @inline(__always)
  /// Creates an ``OSLog`` only in debug builds; otherwise returns ``OSLog.disabled``.
  fileprivate static func makeOSLogInDebug(isEnabled: Bool = true, _ factory: () -> OSLog) -> OSLog {
#if DEBUG
    return factory()
#else
    return .disabled
#endif
  }
  
}
