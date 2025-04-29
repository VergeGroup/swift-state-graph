
public protocol StateViewType {
    
}

open class StateView: Hashable, StateViewType {
  
  public func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(self))
  }
    
  public static func == (lhs: StateView, rhs: StateView) -> Bool {
    return lhs === rhs
  }
  
  public private(set) weak var stateGraph: StateGraph?
  
  public init(stateGraph: StateGraph) {
    self.stateGraph = stateGraph
  }
  
  func addNode(_ node: any Node) {
    node.stateViews.append(self)
  }
  
  private var _sink: Sink = .init()
  
  public func onChange() -> AsyncStream<Void> {
    return _sink.addStream()
  }
  
  func didMemberChanged() {
    _sink.send()
  }
     
  struct NodeWeakBox {
    weak var node: (any Node)?
    
    init(node: any Node) {
      self.node = node
    }
  }
}

extension StateViewType where Self : StateView {
  
  public typealias Computed<Value> = ComputedMember<Value>
  public typealias Stored<Value> = StoredMember<Value>
   
}
