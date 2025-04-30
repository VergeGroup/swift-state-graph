import os.lock

public protocol StateViewType {

}

open class StateView: Hashable, StateViewType {

  public func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(self))
  }

  public static func == (lhs: StateView, rhs: StateView) -> Bool {
    return lhs === rhs
  }

  public init() {
  }

  private let lock: OSAllocatedUnfairLock<Void> = .init()
  nonisolated(unsafe)
  private var _sink: Sink = .init()

  public func onChange() -> AsyncStream<Void> {
    lock.lock()
    defer {
      lock.unlock()
    }
    return _sink.addStream()
  }

  func didMemberChanged() {
    lock.lock()
    defer {
      lock.unlock()
    }
    _sink.send()
  }

}

extension StateViewType where Self: StateView {

  public typealias Computed<Value> = ComputedMember<Value>
  public typealias Stored<Value> = StoredMember<Value>

}
