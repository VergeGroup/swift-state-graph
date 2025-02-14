import Testing
import StateGraph

@Suite
struct Tests {
  @Test
  func test() {
    
    let graph = AttributeGraph()
    let a = graph.input(name: "A", 10)
    let b = graph.input(name: "B", 20)
    let c = graph.rule(name: "C") { a.wrappedValue + b.wrappedValue }
        
    #expect(c.wrappedValue == 30)
    
    print(graph.graphViz())
  }
}
