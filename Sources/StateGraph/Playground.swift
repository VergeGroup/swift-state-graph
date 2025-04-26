
public protocol StateFragment: AnyObject {
  
  var stateGraph: StateGraph { get }
}

extension StateFragment {
  
  public var stateGraph: StateGraph {
    fatalError("Placeholder")
  }
  
  public func sink(handler: @escaping (Self) -> Void) {
  
  }
}

class BState: StateFragment {
      
  static let typeIdentifier: String = String(describing: BState.self)
      
  var value: Int = 0
  
}

class Hoge {
  
  var value_no_initial: Int
    
//  var value_has_initial: Int = 0
  
  var computed: Int {
    value_no_initial * 2
  }
  
  var computed2: Int {
    get {
      computed * 2
    }
  }
  
  init(stateGraph: StateGraph) {
//    self.stateGraph = stateGraph
    self.value_no_initial = 1
  }
}

class AState {
  
  public var stateGraph: StateGraph
  static let typeIdentifier: String = String(describing: AState.self)
    
  var value: Int {
    @storageRestrictions(
      accesses: stateGraph,
      initializes: _value
    )
    init(initialValue) {
      _value = stateGraph.input(name: "value", initialValue)
    }
    get {
      _value.wrappedValue
    }
    set {
      _value.wrappedValue = newValue
    }
  }
  
  private var _value: StoredNode<Int>
    
  var computedValue: Int {   
    if let _computedValue {
      return _computedValue.wrappedValue
    }
    let node = stateGraph.rule(name: "computedValue") { _ in 
      self.value * 2
    }
    self._computedValue = node
    return node.wrappedValue
  }
  
  private var _computedValue: ComputedNode<Int>?
  
  init(stateGraph: StateGraph) {
    self.stateGraph = stateGraph  
    self.value = 2
  }
  
}

class Angle {
  private var degrees: Double
  var radians: Double {
    @storageRestrictions(initializes: degrees)
    init(initialValue)  {
      degrees = initialValue * 180 / .pi
    }
    
    get { degrees * .pi / 180 }
    set { degrees = newValue * 180 / .pi }
  }
  
  init(radiansParam: Double) {
    self.radians = radiansParam // calls init accessor for 'self.radians', passing 'radiansParam' as the argument
  }
}
