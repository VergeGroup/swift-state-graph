
/// A wrapper that holds an unowned reference to an object of type ``T``.
public struct Unowned<T: AnyObject> {

  /// The unowned referenced object.
  public unowned var value: T

  /// Creates an ``Unowned`` wrapper.
  /// - Parameter value: The object to wrap.
  public init(_ value: T) {
    self.value = value
  }

}
  
extension Unowned: Sendable where T: Sendable {
  
}

