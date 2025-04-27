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

  @Test func stateViewTest_first_read() {

    final class Mock: StateView {
      @Stored var a: Int = 0
    }

    let graph = StateGraph()

    let mock = Mock(stateGraph: graph)

    #expect(mock.nodes.count == 0)

    // read
    _ = mock.a

    #expect(mock.nodes.count == 1)
  }

  @Test func stateViewTest_first_write() {

    final class Mock: StateView {
      @Stored var a: Int = 0
    }

    let graph = StateGraph()

    let mock = Mock(stateGraph: graph)

    #expect(mock.nodes.count == 0)

    // write
    mock.a = 10

    #expect(mock.nodes.count == 1)
    #expect(mock.a == 10)
  }

  @Test func db() {

    let graph = StateGraph()

    final class Author: StateView {
      @Stored var name: String

      init(
        stateGraph: StateGraph,
        name: String
      ) {
        self._name = .init(wrappedValue: name)
        super.init(stateGraph: stateGraph)
      }
    }

    final class Tag: StateView {
      @Stored var name: String

      init(
        stateGraph: StateGraph,
        name: String
      ) {
        self._name = .init(wrappedValue: name)
        super.init(stateGraph: stateGraph)
      }
    }

    final class Book: StateView {
      let author: Author
      @Stored var title: String
      @Stored var tags: [Tag]

      init(
        stateGraph: StateGraph,
        author: Author,
        title: String,
        tags: [Tag]
      ) {
        self.author = author
        self._title = .init(wrappedValue: title)
        self._tags = .init(wrappedValue: tags)
        super.init(stateGraph: stateGraph)
      }
    }

    func makeTag(name: String) -> Tag {
      return Tag(
        stateGraph: graph,
        name: name
      )
    }

    func makeAuthor(name: String) -> Author {
      return Author(
        stateGraph: graph,
        name: name
      )
    }

    func makeBook(
      title: String,
      author: Author,
      tags: [Tag]
    ) -> Book {
      return Book(
        stateGraph: graph,
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

    let books = graph.input(name: "books", [book1, book2])

    let filteredBooksByJohn = graph.rule(name: "booksByJohn") { graph in
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

  @MainActor
  @Test func test() async {

    let graph = StateGraph()

    let node = graph.input(name: "", "A")

    let ex = Task {
      await confirmation(expectedCount: 1) { c in

        for await _ in node.onChange() {
          c.confirm()
          return
        }
      }
    }
    
    Task {
      node.wrappedValue = "B"
    }
    
    await ex.value
  }

  @MainActor
  @Test func testComputedNodeSubscription() async {
    let graph = StateGraph()

    // 入力ノードを作成
    let inputNode = graph.input(name: "input", 10)
    
    // 計算ノードを作成（入力ノードに依存）
    let computedNode = graph.rule(name: "computed") { _ in 
      inputNode.wrappedValue * 2 
    }

    // 最初の計算結果を確認
    #expect(computedNode.wrappedValue == 20)

    // computedNodeの変更を監視
    let ex = Task {
      await confirmation(expectedCount: 1) { c in
        for await _ in computedNode.onChange() {
          c.confirm()
          return
        }
      }
    }
    
    // 入力ノードの値を変更
    Task {
      inputNode.wrappedValue = 20
    }
    
    // 通知が届くのを待つ
    await ex.value
    
    // 計算結果が更新されていることを確認
    #expect(computedNode.wrappedValue == 40)
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
