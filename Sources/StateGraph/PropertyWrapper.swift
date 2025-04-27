
@propertyWrapper public struct ComputedMember<Value> {
  
  @available(*, unavailable,
              message: "This property wrapper can only be applied to classes"
  )
  
  public var wrappedValue: Value {
    get { fatalError() }
    set { fatalError() }
  }
  
  private var compute: (StateGraph) -> Value
  private var node: ComputedNode<Value>?
  
  public init(compute: @escaping (StateGraph) -> Value) {
    self.compute = compute
  }
  
  public static subscript<T: StateView>(
    _enclosingInstance instance: T,
    wrapped wrappedKeyPath: ReferenceWritableKeyPath<T, Value>,
    storage storageKeyPath: ReferenceWritableKeyPath<T, Self>
  ) -> Value {
        
    if let node = instance[keyPath: storageKeyPath].node {
      return node.wrappedValue
    }   
    
    let compute = instance[keyPath: storageKeyPath].compute
    
    let node = instance.stateGraph!.rule(name: "", compute)
    
    instance[keyPath: storageKeyPath].node = node
    instance.addNode(node)
        
    return node.wrappedValue
    
  }
  
  
}

@propertyWrapper public struct StoredMember<Value> {
  
  @available(*, unavailable,
              message: "This property wrapper can only be applied to classes"
  )
  
  public var wrappedValue: Value {
    get { fatalError() }
    set { fatalError() }
  }
  
  private let initialValue: Value
  private var node: StoredNode<Value>?
  
  public init(wrappedValue: consuming Value) {
    self.initialValue = consume wrappedValue
  }
  
  public static subscript<T: StateView>(
    _enclosingInstance instance: T,
    wrapped wrappedKeyPath: ReferenceWritableKeyPath<T, Value>,
    storage storageKeyPath: ReferenceWritableKeyPath<T, Self>
  ) -> Value {
    
    get {
      
      if let node = instance[keyPath: storageKeyPath].node {
        return node.wrappedValue
      }            
      
      let initialValue = instance[keyPath: storageKeyPath].initialValue
      
      let node = instance.stateGraph!.input(name: "", initialValue)
                
      instance.addNode(node)

      instance[keyPath: storageKeyPath].node = node
      
      return node.wrappedValue
    }
    set {
      
      if let node = instance[keyPath: storageKeyPath].node {
        node.wrappedValue = newValue
        return
      }   
            
      let node = instance.stateGraph!.input(name: "", newValue)
      
      instance.addNode(node)
      
      instance[keyPath: storageKeyPath].node = node
    }
    
  }
  
  
}
