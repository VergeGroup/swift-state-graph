
public struct Weak<T: AnyObject> {
  
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
