
public struct Unowned<T: AnyObject> {
  
  public unowned var value: T
  
  public init(_ value: T) {
    self.value = value
  }
  
}
  
extension Unowned: Sendable where T: Sendable {
  
}

