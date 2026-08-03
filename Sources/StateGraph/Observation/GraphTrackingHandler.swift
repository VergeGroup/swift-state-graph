/// Coordinates the lifetime and serialized execution of a graph tracking handler.
///
/// Cancellation and execution use separate synchronization domains:
///
/// - The lifetime state decides whether a new invocation may start and releases
///   the stored handler when cancellation wins.
/// - The execution gate serializes complete group/map passes, including child
///   cleanup and the map projection/filter/delivery pipeline.
///
/// Cancellation is cooperative and non-waiting. An invocation that already captured
/// the active handler is allowed to finish, while later invocations observe
/// `.cancelled` and return without executing user code.
///
/// `@unchecked Sendable` applies to this container's synchronized shared state, not
/// to the handler's captures. The continuous tracking caller remains responsible for
/// executing an admitted handler in its requested actor-isolation context.
final class GraphTrackingHandler: @unchecked Sendable {

  /// The mutually exclusive lifetime states of the stored handler.
  ///
  /// Transitioning to `.cancelled` removes the handler from shared storage so an
  /// inactive subscription does not retain the handler's captures.
  private enum State {
    case active(ClosureBox<Void>)
    case cancelled
  }

  private let state: OSAllocatedUnfairLock<State>
  private let executionGate = OSAllocatedUnfairLock<Void>()

  init(_ handler: @escaping () -> Void) {
    self.state = OSAllocatedUnfairLock(
      uncheckedState: .active(ClosureBox(handler))
    )
  }

  /// Whether cancellation has prevented future handler invocations.
  var isCancelled: Bool {
    state.withLock { state in
      switch state {
      case .active:
        false
      case .cancelled:
        true
      }
    }
  }

  /// Prevents future invocations without waiting for an admitted invocation.
  ///
  /// The moved handler keeps its captures alive outside the state lock. An admitted
  /// invocation may hold another snapshot until that invocation finishes.
  func cancel() {
    var releasedHandler = state.withLockUnchecked { state -> ClosureBox<Void>? in
      switch state {
      case .active(let handler):
        state = .cancelled
        return handler
      case .cancelled:
        return nil
      }
    }

    withExtendedLifetime(releasedHandler) {}
    releasedHandler = nil
  }

  /// Serializes one complete tracking pass if cancellation has not won admission.
  ///
  /// Capturing the active handler is the invocation's admission point relative to
  /// ``cancel()``. The body may synchronously cancel this handler because cancellation
  /// does not acquire the execution gate and no lifetime lock is held while the body runs.
  ///
  /// - Parameter body: Work that performs child cleanup, installs the current
  ///   cancellable, and invokes the admitted handler.
  func executeIfActive(_ body: (ClosureBox<Void>) -> Void) {
    executionGate.withLockUnchecked {
      let handler = state.withLockUnchecked { state -> ClosureBox<Void>? in
        switch state {
        case .active(let handler):
          handler
        case .cancelled:
          nil
        }
      }

      guard let handler else { return }
      body(handler)
    }
  }
}
