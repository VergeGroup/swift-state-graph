import os.log

/// Runtime diagnostics emitted by StateGraph during development.
///
/// Diagnostic settings are process-wide and thread-safe. They affect only developer
/// feedback and never change graph mutation or notification behavior.
public enum StateGraphDiagnostics {

  private struct State: Sendable {
    var isSelfInvalidationWarningEnabled = true
  }

  private static let state = OSAllocatedUnfairLock(initialState: State())

  /// Controls the warning emitted when a tracking handler suppresses its own invalidation.
  ///
  /// The mutation is still applied and peer registrations are notified normally. The
  /// suppressed one-shot registration is not restored to the invalidated node.
  ///
  /// The default value is `true`. StateGraph logging is disabled automatically in
  /// non-DEBUG builds regardless of this value.
  public static var isSelfInvalidationWarningEnabled: Bool {
    get {
      state.withLock { $0.isSelfInvalidationWarningEnabled }
    }
    set {
      state.withLock { $0.isSelfInvalidationWarningEnabled = newValue }
    }
  }
}

enum Log {

#if DEBUG
  @TaskLocal
  static var selfInvalidationWarningObserver: (@Sendable () -> Void)?
#endif

  static let generic = Logger(OSLog.makeOSLogInDebug { OSLog.init(subsystem: "state-graph", category: "generic") })
  static let tracking = Logger(
    OSLog.makeOSLogInDebug { OSLog.init(subsystem: "state-graph", category: "tracking") }
  )

  static func logSuppressedSelfInvalidation() {
#if DEBUG
    selfInvalidationWarningObserver?()
#endif

    tracking.warning(
      "A tracking handler invalidated its own active registration. The mutation was applied and peer registrations were notified, but this registration was not restored to the invalidated node."
    )
  }
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
