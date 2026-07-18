import Observation

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

@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
extension ObservationRegistrar {
  
  static let shared = ObservationRegistrar()  
  
}
