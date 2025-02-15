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
    
    a.wrappedValue = 40
    
    #expect(c.wrappedValue == 60)
  }
  
  @Test
  func graph() {
    let graph = AttributeGraph()
    let a = graph.input(name: "A", 10)
    let b = graph.input(name: "B", 20)
    let c = graph.rule(name: "C") { a.wrappedValue + b.wrappedValue }
    let d = graph.rule(name: "D") { c.wrappedValue * 2 }
    
    #expect(d.wrappedValue == 60)
    
    let str = """
    digraph {
    A
    B
    C
    D
    A -> C
    B -> C
    C -> D
    }
    """
    #expect(str == graph.graphViz())
    
    a.wrappedValue = 40
    //    #expect(c.wrappedValue == 60)
    
    let str2 = """
    digraph {
    A
    B
    C [style=dashed]
    D [style=dashed]
    A -> C [style=dashed]
    B -> C
    C -> D
    }
    """
    #expect(str2 == graph.graphViz())
  }
}
