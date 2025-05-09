import Testing
@testable import StateGraphNormalization
import StateGraph
import Foundation

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
    age: Int,
    posts: ComputedNode<[Post]>
  ) {
    self.typedID = .init(id)
    self.name = name
    self.age = age
    self.$posts = posts
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
    author: User,
    allComments: ComputedNode<[Comment]>,
    activeComments: ComputedNode<[Comment]>
  ) {
    self.typedID = .init(id)
    self.title = title
    self.content = content
    self.author = author
    self.$allComments = allComments
    self.$activeComments = activeComments
  }
}

final class Comment: TypedIdentifiable, Sendable {
  typealias TypedIdentifierRawValue = String

  let typedID: TypedID
  
  @GraphStored
  var text: String
  
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
final class NormalizedStore {
  
  @GraphStored
  var users: EntityStore<User> = .init()  
  @GraphStored
  var posts: EntityStore<Post> = .init()
  @GraphStored
  var comments: EntityStore<Comment> = .init()
  
  let commentsForPost: StoredNode<[Post : ComputedNode<[Comment]>]> = .init(wrappedValue: [:])
    
}

@Suite
struct NormalizationTests {

  @Test func basic() {
    
    let store = NormalizedStore()
    
    let user = User.init(
      id: "user1",
      name: "John Doe",
      age: 30,
      posts: .init { [posts = store.posts] _ in
        posts
          .filter { $0.author.id.raw == "user1" }
          .sorted(by: { $0.createdAt < $1.createdAt })
      }
    )
    
    
    
  } 

}
