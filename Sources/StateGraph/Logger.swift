#if canImport(os)
import os

enum Log {
  
  static let generic = Logger(OSLog.makeOSLogInDebug { OSLog.init(subsystem: "state-graph", category: "generic") })
  
}

extension OSLog {
  
  @inline(__always)
  fileprivate static func makeOSLogInDebug(isEnabled: Bool = true, _ factory: () -> OSLog) -> OSLog {
#if DEBUG
    return factory()
#else
    return .disabled
#endif
  }
  
}
#else
enum Log {
  static let generic: Any? = nil
}
#endif
