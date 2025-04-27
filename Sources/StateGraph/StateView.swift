
public protocol StateViewType {
    
}

open class StateView: StateViewType {
  
  weak var stateGraph: StateGraph?
  
//  private(set) var nodes: ContiguousArray<NodeWeakBox> = []
  
  public init(stateGraph: StateGraph) {
    self.stateGraph = stateGraph
  }
  
  func addNode(_ node: any Node) {
//    nodes.append(.init(node: node))
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
