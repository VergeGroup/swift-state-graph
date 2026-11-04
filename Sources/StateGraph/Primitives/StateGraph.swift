import os.lock

/// A dependency link whose lifetime does not keep either endpoint alive.
public final class Edge: CustomDebugStringConvertible {

  weak var from: (any TypeErasedNode)?
  weak var to: (any TypeErasedNode)?
  
  private let lock: OSAllocatedUnfairLock<Void> = .init()
  
  var isPending: Bool {
    _read {
      lock.lock()
      defer { lock.unlock() }
      yield _isPending
    }
    _modify {
      lock.lock()
      defer { lock.unlock() }
      yield &_isPending
    }
  }

  private var _isPending: Bool = false

  init(from: any TypeErasedNode, to: any TypeErasedNode) {
    self.from = from
    self.to = to
  }

  public var debugDescription: String {
    guard let from, let to else {
      return "Edge(deallocated endpoint)"
    }

    return "\(from.debugDescription) -> \(to.debugDescription)"
  }

  deinit {
//    Log.generic.debug("Deinit Edge")
  }
  
}

/// The nonrecursive physical lock protecting one node's value and graph metadata.
///
/// User callbacks must run outside this lock. Immediate writers that release it for
/// comparison or Observation delivery retain a coordinator-owned logical
/// reservation until their value is published.
public typealias NodeLock = OSAllocatedUnfairLock<Void>
