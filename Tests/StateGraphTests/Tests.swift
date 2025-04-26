import Testing
@testable import StateGraph

@Suite
struct Tests {
  @Test
  func test() {
    
    let graph = StateGraph()
    let a = graph.input(name: "A", 10)
    let b = graph.input(name: "B", 20)
    let c = graph.rule(name: "C") { _ in a.wrappedValue + b.wrappedValue }
        
    #expect(c.wrappedValue == 30)
    
    a.wrappedValue = 40
    
    #expect(c.wrappedValue == 60)
  }
  
  @Test func graph() {
    let graph = StateGraph()
    let a = graph.input(name: "A", 10)
    let b = graph.input(name: "B", 20)
    let c = graph.rule(name: "C") { _ in a.wrappedValue + b.wrappedValue }
    let d = graph.rule(name: "D") { _ in c.wrappedValue * 2 }
    let e = graph.rule(name: "E") { _ in a.wrappedValue * 2 }

    #expect(d.wrappedValue == 60)
    #expect(e.wrappedValue == 20)
    
    let str = """
    digraph {
    A
    B
    C
    D
    E
    A -> C
    A -> E
    B -> C
    C -> D
    }
    """
    #expect(str == graph.graphViz())
  
  }
  
  @Test func graph2() {
    let graph = StateGraph()
    let a = graph.input(name: "A", 0)
    let b = graph.input(name: "B", 20)
    
    let e = graph.rule(name: "E") { _ in 
      if a.wrappedValue < 10 {
        a
      } else {
        b
      }
    }
    
    #expect(e.wrappedValue.wrappedValue == 0)
    
    a.wrappedValue = 20
    
    #expect(e.wrappedValue.wrappedValue == 20)
  
  }
  
  @Test
  func node_in_node() {
    
    let graph = StateGraph()
    
    let bookNodes = (0..<10).map {
      graph.input(name: "book\($0)", 0)
    }
    
    let allBooks = graph.input(name: "bookNodes", bookNodes)
            
    let filteredBooks = graph.rule(name: "allBooks") { graph in
      allBooks
        .wrappedValue
        .filter {
          $0.name.hasPrefix("book")
        }
    }

    #expect(filteredBooks.wrappedValue.count == 10)
      
    allBooks.wrappedValue.append(graph.input(name: "book100", 0))
    
    #expect(filteredBooks.wrappedValue.count == 11)
    
  }
  
  @Test func db() {
    
    let graph = StateGraph()
    
    final class Author: StateView {
      let name: StoredNode<String>
      
      init(name: StoredNode<String>) {
        self.name = name
      }
    }
    
    final class Book: StateView {
      let author: Author
      let title: StoredNode<String> 
      
      init(author: Author, title: StoredNode<String>) {
        self.author = author
        self.title = title
      }
    }
    
    func makeAuthor(name: String) -> Author {
      let nameNode = graph.input(name: name, name)
      return Author(name: nameNode)
    }
    
    func makeBook(author: Author) -> Book {
      let titleNode = graph.input(name: "title", "title")
      return Book(author: author, title: titleNode)      
    }
    
    let john = makeAuthor(name: "John")
    let mike = makeAuthor(name: "Mike")
    
    let book1 = makeBook(author: john)
    #expect(book1.author.name.wrappedValue == "John")
    
    let book2 = makeBook(author: mike)
    #expect(book2.author.name.wrappedValue == "Mike")
    
    let books = graph.input(name: "books", [book1, book2])
    
    let filteredBooksByJohn = graph.rule(name: "booksByJohn") { graph in
      books
        .wrappedValue
        .filter {
          $0.author.name.wrappedValue == "John"
        }
    }
    
    #expect(books.wrappedValue.count == 2)
    #expect(filteredBooksByJohn.wrappedValue.count == 1)
    
    // add new book
    do {
      let book3 = makeBook(author: john)
      books.wrappedValue.append(book3)
      #expect(books.wrappedValue.count == 3)
      #expect(filteredBooksByJohn.wrappedValue.count == 2)
    }

    // add new book by John
    do {
      let book4 = makeBook(author: john)
      books.wrappedValue.append(book4)
      #expect(books.wrappedValue.count == 4)
      #expect(filteredBooksByJohn.wrappedValue.count == 3)
    }
    
  }
  
}

@Suite
struct StateTests {
  
  @Test func macro() {
    
    let graph = StateGraph()

    let h = Hoge(stateGraph: graph)
        
    h.computed2    

  }
    
  @Test func test() {
    
    let graph = StateGraph()
    
    let a = AState(stateGraph: graph)    
    let b = AState(stateGraph: graph)
    
    do {
            
      a.value = 10
      
      #expect(a.value == 10)
      
      #expect(a.computedValue == 20)
      
      a.value = 20
      
      #expect(a.computedValue == 40)
    }
    
    do {
      
      b.value = 20      
      #expect(b.value == 20)      
      #expect(b.computedValue == 40)
      
      b.value = 30
      
      #expect(b.computedValue == 60)
    }
    
    #expect(a.computedValue == 40)
    
  }
  
}
