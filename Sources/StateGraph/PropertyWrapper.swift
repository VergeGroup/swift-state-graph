@propertyWrapper
public struct ComputedMember<Value>: Sendable {

  @available(
    *, unavailable,
    message: "This property wrapper can only be applied to classes"
  )

  public var wrappedValue: Value {
    get { fatalError() }
    set { fatalError() }
  }

  private var hasRegistered: Bool = false
  private let node: ComputedNode<Value>

  public init(compute: @escaping @Sendable () -> Value) {
    self.node = .init(name: "", rule: compute)
  }

  public static subscript<T: StateView>(
    _enclosingInstance instance: T,
    wrapped wrappedKeyPath: ReferenceWritableKeyPath<T, Value>,
    storage storageKeyPath: ReferenceWritableKeyPath<T, Self>
  ) -> Value {

    let node = instance[keyPath: storageKeyPath].node
    if instance[keyPath: storageKeyPath].hasRegistered == false {
      node.register(instance)
      instance[keyPath: storageKeyPath].hasRegistered = true
    }
    return node.wrappedValue

  }

}

@propertyWrapper
public struct StoredMember<Value>: Sendable {

  @available(
    *, unavailable,
    message: "This property wrapper can only be applied to classes"
  )

  public var wrappedValue: Value {
    get { fatalError() }
    set { fatalError() }
  }

  private let node: StoredNode<Value>
  private var hasRegistered: Bool = false

  public init(wrappedValue: consuming Value) {
    self.node = .init(name: "", wrappedValue: wrappedValue)
  }

  public var projectedValue: StoredNode<Value> {
    self.node
  }

  public static subscript<T: StateView>(
    _enclosingInstance instance: T,
    wrapped wrappedKeyPath: ReferenceWritableKeyPath<T, Value>,
    storage storageKeyPath: ReferenceWritableKeyPath<T, Self>
  ) -> Value {

    get {
      let node = instance[keyPath: storageKeyPath].node
      if instance[keyPath: storageKeyPath].hasRegistered == false {
        node.register(instance)
        instance[keyPath: storageKeyPath].hasRegistered = true
      }
      return node.wrappedValue
    }
    set {
      let node = instance[keyPath: storageKeyPath].node
      if instance[keyPath: storageKeyPath].hasRegistered == false {
        node.register(instance)
        instance[keyPath: storageKeyPath].hasRegistered = true
      }
      node.wrappedValue = newValue
    }

  }

}
