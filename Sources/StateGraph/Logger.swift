#if canImport(os)
import os.log

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
// Stub for platforms that don't support os.log
enum Log {
  struct DummyLogger {
    func info(_ message: String) {}
    func debug(_ message: String) {}
    func error(_ message: String) {}
  }
  static let generic = DummyLogger()
}
#endif
