import Observation

/// Lazily owns the Apple Observation registrar associated with one graph node.
///
/// The owning node must serialize access to this storage with its node lock. Keeping the
/// registrar scoped to one node ensures that registrations are released with that node.
@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
struct NodeObservationRegistrar: Sendable {

  private var registrar: ObservationRegistrar?

  var current: ObservationRegistrar? {
    registrar
  }

  var isInitialized: Bool {
    registrar != nil
  }

  mutating func initializeIfNeeded() -> ObservationRegistrar {
    if let registrar {
      return registrar
    }

    let registrar = ObservationRegistrar()
    self.registrar = registrar
    return registrar
  }
}

struct PointerKeyPathRoot<Object: AnyObject>: Observable, Sendable {
  
  static var shared: PointerKeyPathRoot<Object> {
    PointerKeyPathRoot<Object>()
  }
  
  subscript(pointer pointer: UnsafeMutableRawPointer) -> Never {
    fatalError()
  }
  
}

@inline(__always) 
func _keyPath<Object: AnyObject>(
  _ object: Object
) -> any KeyPath<PointerKeyPathRoot<Object>, Never> & Sendable {
  let p = Unmanaged.passUnretained(object).toOpaque()
  let keyPath = \PointerKeyPathRoot<Object>[pointer: p]
  return keyPath
}
