import Testing
@testable import StateGraphNormalization
import StateGraph
import Foundation

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

@Suite
struct NormalizationTests {

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
