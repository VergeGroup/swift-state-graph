import Observation
import Testing

@testable import StateGraph

final class Author {
  @GraphStored
  var name: String

  init(
    name: String
  ) {
    self.name = name
  }
}

final class Tag {
  @GraphStored
  var name: String

  init(
    name: String
  ) {
    self.name = name
  }
}

final class Book {

  let author: Author
  @GraphStored
  var title: String
  @GraphStored
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

    let a = Stored(name: "A", wrappedValue: 10)
    let b = Stored(name: "B", wrappedValue: 20)
    let c = Computed(name: "C") { _ in a.wrappedValue + b.wrappedValue }

    #expect(c.wrappedValue == 30)

    a.wrappedValue = 40

    #expect(c.wrappedValue == 60)
  }

  @Test func graph() {
    let a = Stored(name: "A", wrappedValue: 10)
    let b = Stored(name: "B", wrappedValue: 20)
    let c = Computed(name: "C") { _ in a.wrappedValue + b.wrappedValue }
    let d = Computed(name: "D") { _ in c.wrappedValue * 2 }
    let e = Computed(name: "E") { _ in a.wrappedValue * 2 }

    #expect(d.wrappedValue == 60)
    #expect(e.wrappedValue == 20)

  }

  @Test func graph2() {
    let a = Stored(name: "A", wrappedValue: 0)
    let b = Stored(name: "B", wrappedValue: 20)

    let e = Computed(name: "E") { _ in
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

    let bookNodes = (0..<10).map { _ in
      Stored(name: "book", wrappedValue: 0)
    }

    let allBooks = Stored(name: "bookNodes", wrappedValue: bookNodes)

    let filteredBooks = Computed(name: "allBooks") { _ in
      allBooks
        .wrappedValue
        .filter {
          $0.info.name.map(String.init)?.hasPrefix("book") == true
        }
    }

    #expect(filteredBooks.wrappedValue.count == 10)

    allBooks.wrappedValue.append(Stored(name: "book100", wrappedValue: 0))

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

    let books = Stored(wrappedValue: [book1, book2])

    let filteredBooksByJohn = Computed(name: "booksByJohn") { _ in
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

  @Test func withGraphTracking_onChange() async {

    final class Model: Sendable {
      @GraphStored var name: String = ""
      @GraphStored var count1: Int = 0
      @GraphStored var count2: Int = 0
    }

    let model = Model()

    await confirmation(expectedCount: 5) { c in

      let cancellable = withGraphTracking {
        let computed = Computed { _ in
          model.count1 + model.count2
        }
        withGraphTrackingMap {
          computed.wrappedValue
        } onChange: { value in
          c.confirm()
        }
        withGraphTrackingMap {
          model.$count1.wrappedValue
        } onChange: { value in
          c.confirm()
        }
      }

      try? await Task.sleep(for: .milliseconds(100))

      model.count1 = 10
      try? await Task.sleep(for: .milliseconds(100))
      model.count2 = 5
      try? await Task.sleep(for: .milliseconds(100))

      withExtendedLifetime(cancellable, {})
    }

  }

  @Test func computed_onChange_notCalledWhenResultIsSame() async {

    final class Model: Sendable {
      @GraphStored var count1: Int = 5
      @GraphStored var count2: Int = 5
    }

    let model = Model()

    // onChange should be called for initial value and when the computed result actually changes
    // Expected calls: 1) initial value (10), 2) when sum changes to 11
    await confirmation(expectedCount: 2) { c in

      let cancellable = withGraphTracking {
        let computed = Computed { _ in
          model.count1 + model.count2
        }
        withGraphTrackingMap {
          computed.wrappedValue
        } onChange: { value in
          c.confirm()
        }
      }

      try? await Task.sleep(for: .milliseconds(100))

      // Change count1 and count2, but sum remains 10 - should NOT trigger onChange
      model.count1 = 6
      model.count2 = 4
      try? await Task.sleep(for: .milliseconds(100))

      // Change again, but sum still remains 10 - should NOT trigger onChange
      model.count1 = 7
      model.count2 = 3
      try? await Task.sleep(for: .milliseconds(100))

      // Finally change the sum to 11 - this SHOULD trigger onChange
      model.count1 = 8
      try? await Task.sleep(for: .milliseconds(100))

      withExtendedLifetime(cancellable, {})
    }

  }

}

@Suite
struct SubscriptionTests {

}

@Suite
@MainActor
struct StateViewTests {

  final class Model: Sendable {
    @GraphStored
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

  final class Model: Sendable {
    @GraphStored
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
      
      try! await Task.sleep(for: .milliseconds(100))
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
      
      try! await Task.sleep(for: .milliseconds(100))

    }

  }
}


final class NestedModel: Sendable {

  @GraphStored
  var counter: Int = 0

  @GraphStored
  var subModel: SubModel?

  init() {
    self.subModel = nil
  }

  func incrementCounter() {
    counter += 1
  }

  func createSubModel() {
    subModel = SubModel()
  }
}

final class SubModel: Sendable {
  @GraphStored
  var value: String = "default"

  init() {}

  func updateValue(_ newValue: String) {
    value = newValue
  }
}

@Suite
struct GraphViewAdvancedTests {
  
  @Test func nested_model_tracking() async {
    let model = NestedModel()
    model.createSubModel()

    await confirmation(expectedCount: 1) { c in
      withStateGraphTracking {
        _ = model.subModel?.value
      } didChange: {
        #expect(model.subModel?.value == "updated")
        c.confirm()
      }

      model.subModel?.updateValue("updated")
      
      try! await Task.sleep(for: .milliseconds(100))
    }
  }

  @Test func multiple_properties_tracking() async {
    let model = NestedModel()

    await confirmation(expectedCount: 1) { c in
      withStateGraphTracking {
        _ = model.counter
        model.createSubModel()
        _ = model.subModel?.value
      } didChange: {
        #expect(model.counter == 1)
        c.confirm()
      }

      model.incrementCounter()
      
      try! await Task.sleep(for: .milliseconds(100))
    }
  }

}

import Foundation

@Suite
struct StreamTests {
    
  @Test func projection_tracking() async {
    let model = NestedModel()

    await confirmation(expectedCount: 4) { c in
      let receivedValues = OSAllocatedUnfairLock<[Int]>(initialState: [])

      let task = Task {
        // Test that withStateGraphTrackingStream now returns projected values directly
        for await value in withStateGraphTrackingStream(apply: {
          model.counter  // Returns Int directly
        }) {
          receivedValues.withLock { $0.append(value) }
          c.confirm()
          if value == 3 {
            break
          }
        }
      }

      try! await Task.sleep(for: .milliseconds(100))

      model.counter = 1
      try! await Task.sleep(for: .milliseconds(100))

      model.counter = 2
      try! await Task.sleep(for: .milliseconds(100))

      model.counter = 3
      try! await Task.sleep(for: .milliseconds(100))

      await task.value

      // Verify we received the projected values: initial (0) + 3 changes
      #expect(receivedValues.withLock { $0 } == [0, 1, 2, 3])
    }
  }  
    
  @Test func continuous_tracking() async {
    let model = NestedModel()

    await confirmation(expectedCount: 4) { c in

      let expectation = OSAllocatedUnfairLock<Int>(initialState: 0)

      let task = Task {
        for await _ in withStateGraphTrackingStream(apply: {
          _ = model.counter
        }) {
          print(model.counter)
          #expect(model.counter == expectation.withLock { $0 })
          c.confirm()
          if model.counter == 3 {
            break
          }
        }
      }

      try! await Task.sleep(for: .milliseconds(100))

      // Trigger updates
      expectation.withLock { $0 = 1 }
      model.counter = expectation.withLock { $0 }

      try! await Task.sleep(for: .milliseconds(100))

      expectation.withLock { $0 = 2 }
      model.counter =  expectation.withLock { $0 }
      try! await Task.sleep(for: .milliseconds(100))

      expectation.withLock { $0 = 3 }
      model.counter =  expectation.withLock { $0 }

      try! await Task.sleep(for: .milliseconds(100))

      await task.value
    }

  }
  
  @Test func continuous_tracking_main() async {
    let model = NestedModel()

    await confirmation(expectedCount: 4) { c in

      let (valueStream, valueContinuation) = AsyncStream<Int>.makeStream()

      let task = Task { @MainActor in

        let stream: AsyncStream<Int> = withStateGraphTrackingStream(apply: {
          assert(Thread.isMainThread, "Because this stream has been created on MainActor.")
          return model.counter
        })

        await Task.detached {
          for await value in stream {
            valueContinuation.yield(value)
            c.confirm()
            if value == 3 {
              break
            }
          }
          valueContinuation.finish()
        }.value

      }

      var iterator = valueStream.makeAsyncIterator()

      // Wait for initial value - confirms stream consumer is ready
      let v0 = await iterator.next()
      #expect(v0 == 0)

      // Trigger updates, waiting for each to be received
      model.counter = 1
      let v1 = await iterator.next()
      #expect(v1 == 1)

      model.counter = 2
      let v2 = await iterator.next()
      #expect(v2 == 2)

      model.counter = 3
      let v3 = await iterator.next()
      #expect(v3 == 3)

      await task.value
    }

  }

  /// Test that AsyncStream from withStateGraphTrackingStream is single-consumer.
  /// Only the first iterator receives values, the second iterator gets nothing.
  @Test func single_consumer_stream() async {
    let model = NestedModel()

    let receivedByA = OSAllocatedUnfairLock<[Int]>(initialState: [])
    let receivedByB = OSAllocatedUnfairLock<[Int]>(initialState: [])

    // Create a single stream
    let stream = withStateGraphTrackingStream(apply: {
      model.counter
    })

    // Iterator A - will receive values
    let taskA = Task {
      for await value in stream {
        receivedByA.withLock { $0.append(value) }
        if value == 2 {
          break
        }
      }
    }

    // Iterator B - trying to consume the same stream
    let taskB = Task {
      for await value in stream {
        receivedByB.withLock { $0.append(value) }
        if value == 2 {
          break
        }
      }
    }

    try! await Task.sleep(for: .milliseconds(100))

    model.counter = 1
    try! await Task.sleep(for: .milliseconds(100))

    model.counter = 2
    try! await Task.sleep(for: .milliseconds(100))

    // Cancel tasks after a short wait to prevent hanging
    // (one iterator will never receive value 2 because AsyncStream is single-consumer)
    taskA.cancel()
    taskB.cancel()

    // Wait a bit for cancellation to propagate
    try! await Task.sleep(for: .milliseconds(50))

    let valuesA = receivedByA.withLock { $0 }
    let valuesB = receivedByB.withLock { $0 }

    print("Iterator A received: \(valuesA)")
    print("Iterator B received: \(valuesB)")

    // AsyncStream is single-consumer: values are NOT duplicated
    // Multiple iterators compete for values (racing behavior)
    #expect(valuesA.count > 0 || valuesB.count > 0, "At least one iterator should receive values")

    // Verify single-consumer behavior:
    // 1. Values are NOT duplicated (each value goes to exactly one iterator)
    // 2. Together, both iterators receive all values
    let allReceivedValues = Set(valuesA + valuesB)
    let expectedValues = Set([0, 1, 2])
    #expect(allReceivedValues == expectedValues, "Together, iterators should receive all values: \(allReceivedValues)")

    // Verify NO duplication - if values were duplicated, combined count would be > 3
    let combinedCount = valuesA.count + valuesB.count
    #expect(combinedCount == 3, "Each value should be delivered exactly once (no duplication): combined=\(combinedCount)")

    // This demonstrates that AsyncStream is single-consumer:
    // - Values are NOT duplicated between iterators (unlike GraphTrackings)
    // - Multiple iterators compete for values in a racing manner
  }

}
