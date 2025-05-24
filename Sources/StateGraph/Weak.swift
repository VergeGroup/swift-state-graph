/// A wrapper that holds a weak reference to an object of type ``T``.
public struct Weak<T: AnyObject> {

  /// The weakly referenced object.
  public weak var value: T?

  /// Creates a ``Weak`` wrapper with a non-optional reference.
  /// - Parameter value: The object to wrap.
  public init(_ value: T) {
    self.value = value
  }

  /// Creates a ``Weak`` wrapper with an optional reference.
  /// - Parameter value: The object to wrap.
  public init(_ value: T?) {
    self.value = value
  }

}

extension Weak: Sendable where T: Sendable {
  
}
