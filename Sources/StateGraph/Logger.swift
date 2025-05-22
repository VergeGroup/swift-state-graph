#if canImport(os.log)
import os.log
#else
struct Logger {
  init(_ log: OSLog) {}
  func debug(_ message: String) {}
}
struct OSLog {
  static let disabled = OSLog()
  init(subsystem: String = "", category: String = "") {}
}
#endif

enum Log {
  
  static let generic = Logger(OSLog.makeOSLogInDebug { OSLog.init(subsystem: "state-graph", category: "generic") })
  
}

#if canImport(os.log)
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
extension OSLog {
  static func makeOSLogInDebug(isEnabled: Bool = true, _ factory: () -> OSLog) -> OSLog {
    return OSLog()
  }
}
#endif
