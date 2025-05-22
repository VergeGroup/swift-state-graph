#if !canImport(os.lock)
import Foundation

public final class OSAllocatedUnfairLock<State>: @unchecked Sendable {
  private let lock = NSLock()
  private var state: State

  public init(initialState: State) {
    self.state = initialState
  }

  public init(uncheckedState: State) {
    self.state = uncheckedState
  }

  @discardableResult
  public func withLock<R>(_ body: (inout State) -> R) -> R {
    lock.lock()
    defer { lock.unlock() }
    return body(&state)
  }

  @discardableResult
  public func withLockUnchecked<R>(_ body: (inout State) -> R) -> R {
    lock.lock()
    defer { lock.unlock() }
    return body(&state)
  }
}
#endif
