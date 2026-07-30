import Testing
@testable import StateGraphNormalization
import StateGraph
import Foundation
import os

extension ComputedEnvironmentValues {
  
  var normalizedStore: NormalizedStore! {
    get {
      self[NormalizedStore.self]
    }
    set {
      self[NormalizedStore.self] = newValue
    }
  }  
}

final class User: TypedIdentifiable, Sendable {
  
  typealias TypedIdentifierRawValue = String

  let typedID: TypedID
  
  @GraphStored
  var name: String
  
  @GraphStored
  var age: Int
  
  @GraphComputed
  var posts: [Post]
  
  init(
    id: String,
    name: String,
    age: Int
  ) {
    self.typedID = .init(id)
    self.name = name
    self.age = age
    self.$posts = .init(name: "posts") { context in
      context.environment.normalizedStore.posts
        .filter { $0.author.id.raw == id }
        .sorted(by: { $0.createdAt < $1.createdAt })
    }
  }
}

final class Post: TypedIdentifiable, Hashable, Sendable {
  
  static func == (lhs: Post, rhs: Post) -> Bool {
    lhs === rhs
  }
  
  func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(self))    
  }
  
  typealias TypedIdentifierRawValue = String

  let typedID: TypedID

  @GraphStored
  var title: String
  
  @GraphStored  
  var content: String
  
  let author: User
  
  let createdAt: Date = .init()
  
  @GraphComputed
  var allComments: [Comment]
  
  @GraphComputed
  var activeComments: [Comment]
  
  init(
    id: String,
    title: String,
    content: String,
    author: User
  ) {
    self.typedID = .init(id)
    self.title = title
    self.content = content
    self.author = author
    self.$allComments = .init(name: "allComments") { context in
      context.environment.normalizedStore.comments
        .filter { $0.post.id.raw == id }
        .sorted(by: { $0.createdAt < $1.createdAt })
    }
    self.$activeComments = .init(name: "activeComments") { context in
      context.environment.normalizedStore.comments
        .filter { $0.post.id.raw == id }
        .filter { !$0.isDeleted }
        .sorted(by: { $0.createdAt < $1.createdAt })
    }
  }
}

final class Comment: TypedIdentifiable, Sendable {
  typealias TypedIdentifierRawValue = String

  let typedID: TypedID
  
  @GraphStored
  var text: String
  
  @GraphStored
  var createdAt: Date = .init()
  
  let post: Post
  
  let author: User
  
  @GraphStored
  var isDeleted: Bool = false
  
  init(id: String, text: String, post: Post, author: User) {
    self.typedID = .init(id)
    self.text = text
    self.post = post
    self.author = author
  }
}

// Normalized store using StateGraph
final class NormalizedStore: ComputedEnvironmentKey, Sendable {
  
  typealias Value = NormalizedStore

  @GraphStored
  var users: EntityStore<User> = .init()

  @GraphStored
  var posts: EntityStore<Post> = .init()

  @GraphStored
  var comments: EntityStore<Comment> = .init()
}

private struct ValueEntity: TypedIdentifiable, Sendable {

  typealias TypedIdentifierRawValue = Int

  let typedID: TypedID
  var value: Int

  init(id: Int, value: Int) {
    self.typedID = .init(id)
    self.value = value
  }
}

private enum MutationError: Error {
  case expected
}

/// Owns a value-semantic entity store at the StateGraph mutation boundary.
private final class ValueStoreOwner: Sendable {

  @GraphStored
  var entities: EntityStore<ValueEntity> = .init()
}

@Suite
struct NormalizationTests {

  @Test func copiedStoresMutateIndependently() {
    var original = EntityStore<ValueEntity>()
    original.add(.init(id: 1, value: 1))

    var copy = original
    copy.modify(.init(1)) { entity in
      entity.value = 2
    }
    copy.add(.init(id: 2, value: 2))

    #expect(original.get(by: .init(1))?.value == 1)
    #expect(!original.contains(.init(2)))
    #expect(copy.get(by: .init(1))?.value == 2)
    #expect(copy.contains(.init(2)))
  }

  @Test func crudAndBatchOperations() {
    var store = EntityStore<ValueEntity>()

    #expect(store.isEmpty)

    store.add(.init(id: 1, value: 1))
    store.add([
      .init(id: 2, value: 2),
      .init(id: 3, value: 3),
    ])

    #expect(store.count == 3)
    #expect(store.contains(.init(1)))
    #expect(store.get(by: .init(2))?.value == 2)
    #expect(store[.init(3)]?.value == 3)

    store.modify(.init(1)) { entity in
      entity.value = 10
    }
    store.update(.init(id: 2, value: 20))
    store[.init(3)] = .init(id: 3, value: 30)

    #expect(store.get(by: .init(1))?.value == 10)
    #expect(store.get(by: .init(2))?.value == 20)
    #expect(store.get(by: .init(3))?.value == 30)
    #expect(store.filter { $0.value >= 20 }.count == 2)

    store.delete(.init(2))

    #expect(!store.contains(.init(2)))
    #expect(store.count == 2)
  }

  @Test func updateOrCreateUpdatesOrInserts() {
    var store = EntityStore<ValueEntity>(
      entities: [.init(1): .init(id: 1, value: 1)]
    )

    let updated = store.updateOrCreate(
      id: .init(1),
      update: { $0.value = 2 },
      create: { .init(id: 1, value: 999) }
    )
    let created = store.updateOrCreate(
      id: .init(2),
      update: { $0.value = 999 },
      create: { .init(id: 2, value: 3) }
    )

    #expect(updated.value == 2)
    #expect(created.value == 3)
    #expect(store.get(by: .init(1))?.value == 2)
    #expect(store.get(by: .init(2))?.value == 3)
  }

  @Test func failedValueUpdateDoesNotCommit() {
    var store = EntityStore<ValueEntity>(
      entities: [.init(1): .init(id: 1, value: 1)]
    )

    #expect(throws: MutationError.self) {
      try store.updateOrCreate(
        id: .init(1),
        update: { entity throws(MutationError) in
          entity.value = 2
          throw .expected
        },
        create: { () throws(MutationError) -> ValueEntity in
          .init(id: 1, value: 2)
        }
      )
    }

    #expect(store.get(by: .init(1))?.value == 1)

    #expect(throws: MutationError.self) {
      try store.updateOrCreate(
        id: .init(2),
        update: { _ throws(MutationError) in },
        create: { () throws(MutationError) -> ValueEntity in
          throw .expected
        }
      )
    }

    #expect(!store.contains(.init(2)))
  }

  @Test func graphStoredOwnerInvalidatesComputed() {
    let owner = ValueStoreOwner()
    let computationCount = OSAllocatedUnfairLock(initialState: 0)
    let count = Computed { _ in
      computationCount.withLock { $0 += 1 }
      return owner.entities.count
    }

    #expect(count.wrappedValue == 0)

    owner.entities.add(.init(id: 1, value: 1))

    #expect(count.wrappedValue == 1)
    #expect(computationCount.withLock { $0 } == 2)
  }

  @Test func batchMutationInvalidatesGraphTracking() async {
    let owner = ValueStoreOwner()
    let stream = withStateGraphTrackingStream {
      owner.entities.count
    }
    var iterator = stream.makeAsyncIterator()

    #expect(await iterator.next() == 0)

    owner.entities.add([
      .init(id: 1, value: 1),
      .init(id: 2, value: 2),
    ])

    #expect(await iterator.next() == 2)
  }

  @Test func getAllReturnsIndependentSnapshot() {
    var store = EntityStore<ValueEntity>()
    store.add(.init(id: 1, value: 1))

    let snapshot = store.getAll()
    store.add(.init(id: 2, value: 2))

    #expect(snapshot.map(\.typedID) == [.init(1)])
    #expect(Set(store.getAll().map(\.typedID)) == [.init(1), .init(2)])
  }

  @MainActor
  @Test func basic() async {
    
    let store = NormalizedStore()
    
    StateGraphGlobal.computedEnvironmentValues.withLock { values in
      values.normalizedStore = store
    }
    
    let user = User.init(
      id: "user1",
      name: "John Doe",
      age: 30
    )
    
    store.users.add(user)
    
    let post = Post.init(
      id: UUID().uuidString,
      title: "My first post",
      content: "This is my first post",
      author: user
    )
    
    store.posts.add(post)

    #expect(user.posts.count == 1)
    
    print(await NodeStore.shared.graphViz())
      
  } 

  @MainActor
  @Test func randomDataGeneration() async {
    
    let task = Task {
      let store = NormalizedStore()
      
      StateGraphGlobal.computedEnvironmentValues.withLock { values in
        values.normalizedStore = store
      }
      
      // ランダムなユーザーを生成
      let users = (0..<5).map { i in
        User(
          id: "user\(i)",
          name: "User \(i)",
          age: Int.random(in: 18...80)
        )
      }
      
      // ユーザーをストアに追加
      users.forEach { store.users.add($0) }
      
      // 各ユーザーに対してランダムな投稿を生成
      let posts = users.flatMap { user in
        (0..<Int.random(in: 1...3)).map { i in
          Post(
            id: UUID().uuidString,
            title: "Post \(i) by \(user.name)",
            content: "Content for post \(i)",
            author: user
          )
        }
      }
      
      // 投稿をストアに追加
      posts.forEach { store.posts.add($0) }
      
      // 各投稿に対してランダムなコメントを生成
      let comments = posts.flatMap { post in
        (0..<Int.random(in: 0...5)).map { i in
          Comment(
            id: UUID().uuidString,
            text: "Comment \(i) on post: \(post.title)",
            post: post,
            author: users.randomElement()!
          )
        }
      }
      
      // コメントをストアに追加
      comments.forEach { store.comments.add($0) }
      
      // 検証
      #expect(store.users.count == 5)
      #expect(store.posts.count == posts.count)
      #expect(store.comments.count == comments.count)
      
      // 各ユーザーの投稿数を検証
      for user in users {
        #expect(user.posts.count == posts.filter { $0.author.id == user.id }.count)
      }
      
      // 各投稿のコメント数を検証
      for post in posts {
        #expect(post.allComments.count == comments.filter { $0.post.id == post.id }.count)
        #expect(post.activeComments.count == comments.filter { $0.post.id == post.id && !$0.isDeleted }.count)
      }
      
    }
    
    await task.value
    
    StateGraphGlobal.computedEnvironmentValues.withLock { values in
      values.normalizedStore = nil
    }
    
    await Task.yield()
    
    print(await NodeStore.shared.graphViz())
    
  }
}
