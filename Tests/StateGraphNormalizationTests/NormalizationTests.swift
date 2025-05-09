import Testing
@testable import StateGraphNormalization
import StateGraph

final class User: TypedIdentifiable {
  
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

final class Post: TypedIdentifiable {
  typealias TypedIdentifierRawValue = String

  let typedID: TypedID

  @GraphStored
  var title: String
  
  @GraphStored  
  var content: String
  
  let author: User
  
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

final class Comment: TypedIdentifiable {
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
}

@Suite
struct NormalizationTests {
  
  @Test
  func testBasicNormalization() {
    // Create store
    let store = NormalizedStore()
    
    // Create test data
    let user1 = User(id: "user1", name: "Alice", age: 30)
    let user2 = User(id: "user2", name: "Bob", age: 28)
    
    // Add users to store
    store.addUser(user1)
    store.addUser(user2)
    
    // Create posts
    let post1 = Post(id: "post1", title: "Hello World", content: "My first post", author: user1)
    let post2 = Post(id: "post2", title: "Swift Programming", content: "Swift is awesome", author: user1)
    let post3 = Post(id: "post3", title: "StateGraph", content: "Learning about state management", author: user2)
    
    // Add posts to store
    store.addPost(post1)
    store.addPost(post2)
    store.addPost(post3)
    
    // Create comments
    let comment1 = Comment(id: "comment1", text: "Great post!", post: post1, author: user2)
    let comment2 = Comment(id: "comment2", text: "Thanks for sharing", post: post2, author: user2)
    let comment3 = Comment(id: "comment3", text: "Interesting topic", post: post3, author: user1)
    
    // Add comments to store
    store.addComment(comment1)
    store.addComment(comment2)
    store.addComment(comment3)
    
    // Test computed node: getUserWithPosts
    let userWithPostsNode = store.getUserWithPosts(userId: "user1")
    let (user, posts) = userWithPostsNode.wrappedValue
    
    #expect(user?.name == "Alice")
    #expect(posts.count == 2)
    #expect(posts.map(\.title).contains("Hello World"))
    #expect(posts.map(\.title).contains("Swift Programming"))
    
    // Test computed node: getPostWithDetails
    let postWithDetailsNode = store.getPostWithDetails(postId: "post1")
    let (post, author, comments) = postWithDetailsNode.wrappedValue
    
    #expect(post?.title == "Hello World")
    #expect(author?.name == "Alice")
    #expect(comments.count == 1)
    #expect(comments[0].text == "Great post!")
  }
  
  @Test
  func testUpdatingEntities() {
    // Create store and data
    let store = NormalizedStore()
    
    // Add user and post
    let user = User(id: "user1", name: "Charlie", age: 35)
    store.addUser(user)
    
    let post = Post(id: "post1", title: "Original Title", content: "Content", author: user)
    store.addPost(post)
    
    // Create computed node to track user with posts
    let userWithPostsNode = store.getUserWithPosts(userId: "user1")
    let initialResult = userWithPostsNode.wrappedValue
    
    #expect(initialResult.0?.name == "Charlie")
    #expect(initialResult.1.count == 1)
    #expect(initialResult.1[0].title == "Original Title")
    
    // Update user name
    store.updateUserName(userId: "user1", newName: "Charles")
    
    // Update post title
    store.updatePostTitle(postId: "post1", newTitle: "Updated Title")
    
    // Check that the computed node reflects the changes
    let updatedResult = userWithPostsNode.wrappedValue
    
    #expect(updatedResult.0?.name == "Charles")
    #expect(updatedResult.1.count == 1)
    #expect(updatedResult.1[0].title == "Updated Title")
  }
  
  @Test
  func testReactiveChanges() {
    // Create store and data
    let store = NormalizedStore()
    
    // Add initial users
    let user1 = User(id: "user1", name: "David", age: 40)
    store.addUser(user1)
    
    // Create a computed node for user posts
    let userPostsNode = store.getPostsByUser(userId: "user1")
    
    #expect(userPostsNode.wrappedValue.count == 0)
    
    // Add a post
    let post1 = Post(id: "post1", title: "First Post", content: "Content", author: user1)
    store.addPost(post1)
    
    // Check that the computed node updates automatically
    #expect(userPostsNode.wrappedValue.count == 1)
    #expect(userPostsNode.wrappedValue[0].title == "First Post")
    
    // Add another post
    let post2 = Post(id: "post2", title: "Second Post", content: "More content", author: user1)
    store.addPost(post2)
    
    // Check that the computed node updates again
    #expect(userPostsNode.wrappedValue.count == 2)
    
    // Get user with posts to test the relationship in both directions
    let userWithPostsNode = store.getUserWithPosts(userId: "user1")
    let (user, posts) = userWithPostsNode.wrappedValue
    
    #expect(user?.name == "David")
    #expect(posts.count == 2)
    #expect(posts.map(\.id).sorted() == ["post1", "post2"])
  }
  
  @Test
  func testEntityDeletion() {
    // Create store and data
    let store = NormalizedStore()
    
    // Add user, post, and comment
    let user = User(id: "user1", name: "Eve", age: 25)
    store.addUser(user)
    
    let post = Post(id: "post1", title: "Test Post", content: "Delete me", author: user)
    store.addPost(post)
    
    let comment = Comment(id: "comment1", text: "Test comment", post: post, author: user)
    store.addComment(comment)
    
    // Verify entities were added
    let userPostsNode = store.getPostsByUser(userId: "user1")
    #expect(userPostsNode.wrappedValue.count == 1)
    
    // Delete post
    store.deletePost(postId: "post1")
    
    // Verify post was deleted
    #expect(userPostsNode.wrappedValue.count == 0)
    
    // Delete user
    store.deleteUser(userId: "user1")
    
    // Verify user was deleted
    let userWithPostsNode = store.getUserWithPosts(userId: "user1")
    #expect(userWithPostsNode.wrappedValue.0 == nil)
  }
}
