import Testing

@testable import StateGraph

@GraphView
final class Author {
  var name: String
  
  init(
    name: String
  ) {
    self.name = name
  }
}

@GraphView
final class Tag {
  var name: String
  
  init(
    name: String
  ) {
    self.name = name
  }
}

@GraphView
final class Book {
  
  let author: Author
  var title: String
  var tags: [Tag]
  
  init(
    author: Author,
    title: String,
    tags: [Tag]
  ) {
    self.author = author
    self.title = title
    self.tags = tags
  }
}

@Suite
struct Tests {
  @Test
  func test() {

    let a = StoredNode(name: "A", wrappedValue: 10)
    let b = StoredNode(name: "B", wrappedValue: 20)
    let c = ComputedNode(name: "C") { a.wrappedValue + b.wrappedValue }

    #expect(c.wrappedValue == 30)

    a.wrappedValue = 40

    #expect(c.wrappedValue == 60)
  }

  @Test func graph() {
    let a = StoredNode(name: "A", wrappedValue: 10)
    let b = StoredNode(name: "B", wrappedValue: 20)
    let c = ComputedNode(name: "C") { a.wrappedValue + b.wrappedValue }
    let d = ComputedNode(name: "D") { c.wrappedValue * 2 }
    let e = ComputedNode(name: "E") { a.wrappedValue * 2 }

    #expect(d.wrappedValue == 60)
    #expect(e.wrappedValue == 20)

  }

  @Test func graph2() {
    let a = StoredNode(name: "A", wrappedValue: 0)
    let b = StoredNode(name: "B", wrappedValue: 20)

    let e = ComputedNode(name: "E") {
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

    let bookNodes = (0..<10).map {
      StoredNode(name: "book\($0)", wrappedValue: 0)
    }

    let allBooks = StoredNode(name: "bookNodes", wrappedValue: bookNodes)

    let filteredBooks = ComputedNode(name: "allBooks") {
      allBooks
        .wrappedValue
        .filter {
          $0.name?.hasPrefix("book") == true
        }
    }

    #expect(filteredBooks.wrappedValue.count == 10)

    allBooks.wrappedValue.append(StoredNode(name: "book100", wrappedValue: 0))

    #expect(filteredBooks.wrappedValue.count == 11)

  }

  @Test func db() {

    func makeTag(name: String) -> Tag {
      return Tag(
        name: name
      )
    }

    func makeAuthor(name: String) -> Author {
      return Author(
        name: name
      )
    }

    func makeBook(
      title: String,
      author: Author,
      tags: [Tag]
    ) -> Book {
      return Book(
        author: author,
        title: title,
        tags: tags
      )
    }

    let tagA = makeTag(name: "A")
    let tagB = makeTag(name: "B")

    let john = makeAuthor(name: "John")
    let mike = makeAuthor(name: "Mike")

    let book1 = makeBook(
      title: "Swift Programming",
      author: john,
      tags: [tagA, tagB]
    )
    #expect(book1.author.name == "John")

    let book2 = makeBook(
      title: "Swift Programming 2",
      author: mike,
      tags: [tagA]
    )

    #expect(book2.author.name == "Mike")

    let books = StoredNode(wrappedValue: [book1, book2])

    let filteredBooksByJohn = ComputedNode(name: "booksByJohn") {
      books
        .wrappedValue
        .filter {
          $0.author.name == "John"
        }
    }

    #expect(books.wrappedValue.count == 2)
    #expect(filteredBooksByJohn.wrappedValue.count == 1)

    // add new book
    do {
      let book3 = makeBook(
        title: "Swift Programming 3",
        author: john,
        tags: [tagA, tagB]
      )
      books.wrappedValue.append(book3)
      #expect(books.wrappedValue.count == 3)
      #expect(filteredBooksByJohn.wrappedValue.count == 2)
    }

    // add new book by John
    do {
      let book4 = makeBook(
        title: "Swift Programming 4",
        author: john,
        tags: [tagA, tagB]
      )
      books.wrappedValue.append(book4)
      #expect(books.wrappedValue.count == 4)
      #expect(filteredBooksByJohn.wrappedValue.count == 3)
    }

  }

}

@Suite
struct SubscriptionTests {

}

import Observation

@Suite
struct StateViewTests {
  
  @GraphView
  final class Model: Sendable {
    var count: Int = 0
  }
  
  @Test func tracking() async {
    
    let m = Model()
    
    await confirmation(expectedCount: 1) { c in
      
      withObservationTracking { 
        _ = m.count
      } onChange: { 
        #expect(m.count == 0)
        c.confirm()
      }
      
      m.count += 1
      
    }
           
  }
  

}

@Suite
struct StateGraphTrackingTests {
  
  @GraphView
  final class Model: Sendable {
    var count: Int = 0
  }
  
  @Test func basic() async {
    
    let m = Model()
    
    await confirmation(expectedCount: 1) { c in
      withStateGraphTracking { 
        _ = m.count              
      } didChange: { 
        #expect(m.count == 1)
        c.confirm()        
      }
      m.count += 1
    }
    
  }
  
  @Test func twice_access_single_call() async {
    
    let m = Model()
    
    await confirmation(expectedCount: 1) { c in
      withStateGraphTracking { 
        _ = m.count              
        _ = m.count              
      } didChange: { 
        #expect(m.count == 1)
        c.confirm()        
      }
      m.count += 1
    }
    
  }
}
