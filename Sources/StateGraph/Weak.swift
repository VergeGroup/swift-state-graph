public protocol WeakType {
  associatedtype Wrapped: AnyObject
  var value: Wrapped? { get }
}

public struct Weak<T: AnyObject>: WeakType {
  
  public weak var value: T?
  
  public init(_ value: T) {
    self.value = value
  }
  
  public init(_ value: T?) {
    self.value = value
  }

}

extension Weak: Sendable where T: Sendable {
  
}

extension RangeReplaceableCollection where Element : WeakType {
  
  public mutating func compact() {
    self.removeAll {
      $0.value == nil
    }
  }
  
  public consuming func compacted() -> Self {
    self.compact()
    return self
  }
  
}

extension Collection where Element : WeakType {
    
  public consuming func unwrapped() -> [Element.Wrapped] {
    return self.compactMap { $0.value }
  }
  
}
  
