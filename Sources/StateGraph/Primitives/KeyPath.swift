import Observation

struct PointerKeyPathRoot: Observable, Sendable {
  
  static let shared = PointerKeyPathRoot()
  
  subscript(pointer pointer: UnsafeMutableRawPointer) -> Never {
    fatalError()
  }
  
}

@inline(__always) 
func _keyPath(_ object: AnyObject) -> any KeyPath<PointerKeyPathRoot, Never> & Sendable {
  let p = Unmanaged.passUnretained(object).toOpaque()
  let keyPath = \PointerKeyPathRoot[pointer: p]
  return keyPath
}

@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
extension ObservationRegistrar {
  
  static let shared = ObservationRegistrar()  
  
}
