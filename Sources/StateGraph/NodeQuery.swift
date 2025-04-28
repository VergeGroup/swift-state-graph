
public protocol NodeQuery {
  associatedtype Result
  
  func perform(graph: borrowing StateGraph) -> Result
}
