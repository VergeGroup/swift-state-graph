# Data Normalization

Efficiently managing and accessing related data with Swift State Graph's normalization module.

## Overview

The `StateGraphNormalization` module provides tools for organizing your data in a normalized structure, making it easier to handle complex relationships between entities. This approach eliminates data duplication, ensures consistency, and integrates seamlessly with Swift State Graph's reactive system.

## Core Concepts

Data normalization involves storing entities in separate collections while maintaining relationships through references. This pattern is particularly useful for applications with complex data relationships like social networks, content management systems, or e-commerce platforms.

### Benefits of Normalization

1. **Single Source of Truth**: Entities are stored once, preventing duplication and inconsistencies
2. **Efficient Updates**: Changes to an entity are automatically reflected in all computed properties
3. **Relationship Management**: Easily handle one-to-many and many-to-many relationships
4. **Performance**: Optimized for fast lookups and updates through ID-based access
5. **Reactivity**: Combined with State Graph's dependency tracking for automatic UI updates

## EntityStore

`EntityStore` is a generic container for managing collections of entities with unique identifiers:

```swift
import StateGraphNormalization

// Creating entity stores for different types
let userStore = EntityStore<User>()
let postStore = EntityStore<Post>()
let commentStore = EntityStore<Comment>()

// Adding entities
userStore.add(user)
postStore.add(post)

// Retrieving entities
let user = userStore.get(by: userId)
let allUsers = userStore.getAll()

// Filtering entities
let activeUsers = userStore.filter { !$0.isDeleted }

// Updating entities
userStore.update(updatedUser)
// or modify in place
userStore.modify(userId) { user in 
  user.name = "New Name"
}

// Checking conditions
let hasUser = userStore.contains(userId)
let count = userStore.count

// Removing entities
userStore.delete(userId)
```

### EntityStore Operations

The `EntityStore` provides a comprehensive API for entity management:

```swift
// Bulk operations
userStore.add([user1, user2, user3])

// Subscript access
userStore[userId] = updatedUser
let user = userStore[userId]

// Collection properties
if userStore.isEmpty {
  print("No users found")
}

print("Total users: \(userStore.count)")
```

## TypedIdentifiable Protocol

Entities stored in an `EntityStore` must conform to the `TypedIdentifiable` protocol, which provides type-safe identifiers:

```swift
import TypedIdentifier

final class User: TypedIdentifiable {
  typealias TypedIdentifierRawValue = String
  
  let typedID: TypedID
  
  @GraphStored
  var name: String
  
  @GraphStored
  var email: String
  
  @GraphStored
  var isActive: Bool
  
  init(id: String, name: String, email: String) {
    self.typedID = .init(id)
    self.name = name
    self.email = email
    self.isActive = true
  }
}

// Usage with type-safe IDs
let userId: User.TypedID = .init("user123")
let user = userStore.get(by: userId)
```

### Benefits of TypedIdentifiable

- **Type Safety**: IDs are strongly typed, preventing mix-ups between different entity types
- **Compiler Checking**: Catch ID-related errors at compile time
- **Clear Intent**: Code explicitly shows which type of entity an ID refers to

## NormalizedStore

`NormalizedStore` acts as a central repository for managing multiple entity types:

```swift
final class NormalizedStore {
  @GraphStored
  var users: EntityStore<User> = .init()
  
  @GraphStored
  var posts: EntityStore<Post> = .init()
  
  @GraphStored
  var comments: EntityStore<Comment> = .init()
  
  @GraphStored
  var tags: EntityStore<Tag> = .init()
}

// Create a single store instance for your app
let store = NormalizedStore()
```

## Building Relationships

### One-to-Many Relationships

```swift
final class Author: TypedIdentifiable {
  typealias TypedIdentifierRawValue = String
  let typedID: TypedID
  
  @GraphStored var name: String
  
  // Computed property for posts by this author
  @GraphComputed var posts: [Post]
  
  init(id: String, name: String, store: NormalizedStore) {
    self.typedID = .init(id)
    self.name = name
    
    // Define the relationship
    self.$posts = .init { _ in
      store.posts.filter { $0.authorId == self.id }
    }
  }
}

final class Post: TypedIdentifiable {
  typealias TypedIdentifierRawValue = String
  let typedID: TypedID
  
  @GraphStored var title: String
  @GraphStored var content: String
  
  // Reference to author
  let authorId: Author.TypedID
  
  init(id: String, title: String, content: String, authorId: Author.TypedID) {
    self.typedID = .init(id)
    self.title = title
    self.content = content
    self.authorId = authorId
  }
}
```

### Many-to-Many Relationships

```swift
final class Post: TypedIdentifiable {
  typealias TypedIdentifierRawValue = String
  let typedID: TypedID
  
  @GraphStored var title: String
  @GraphStored var tagIds: Set<Tag.TypedID>
  
  // Computed property for related tags
  @GraphComputed var tags: [Tag]
  
  init(id: String, title: String, store: NormalizedStore) {
    self.typedID = .init(id)
    self.title = title
    self.tagIds = []
    
    self.$tags = .init { [$tagIds] _ in
      $tagIds.wrappedValue.compactMap { tagId in
        store.tags.get(by: tagId)
      }
    }
  }
}

final class Tag: TypedIdentifiable {
  typealias TypedIdentifierRawValue = String
  let typedID: TypedID
  
  @GraphStored var name: String
  
  // Computed property for posts with this tag
  @GraphComputed var posts: [Post]
  
  init(id: String, name: String, store: NormalizedStore) {
    self.typedID = .init(id)
    self.name = name
    
    self.$posts = .init { _ in
      store.posts.filter { post in
        post.tagIds.contains(self.id)
      }
    }
  }
}
```

## Complete Example: Social Media Application

Here's a comprehensive example of a social media application using normalization:

```swift
// Entity definitions
final class User: TypedIdentifiable {
  typealias TypedIdentifierRawValue = String
  let typedID: TypedID
  
  @GraphStored var name: String
  @GraphStored var email: String
  @GraphStored var followerIds: Set<User.TypedID>
  
  @GraphComputed var posts: [Post]
  @GraphComputed var followers: [User]
  @GraphComputed var followerCount: Int
  
  init(id: String, name: String, email: String, store: NormalizedStore) {
    self.typedID = .init(id)
    self.name = name
    self.email = email
    self.followerIds = []
    
    self.$posts = .init { _ in
      store.posts.filter { $0.authorId == self.id }
    }
    
    self.$followers = .init { [$followerIds] _ in
      $followerIds.wrappedValue.compactMap { followerId in
        store.users.get(by: followerId)
      }
    }
    
    self.$followerCount = .init { [$followers] _ in
      $followers.wrappedValue.count
    }
  }
}

final class Post: TypedIdentifiable {
  typealias TypedIdentifierRawValue = String
  let typedID: TypedID
  
  @GraphStored var title: String
  @GraphStored var content: String
  @GraphStored var likes: Int
  
  let authorId: User.TypedID
  
  @GraphComputed var author: User?
  @GraphComputed var comments: [Comment]
  @GraphComputed var commentCount: Int
  
  init(id: String, title: String, content: String, authorId: User.TypedID, store: NormalizedStore) {
    self.typedID = .init(id)
    self.title = title
    self.content = content
    self.likes = 0
    self.authorId = authorId
    
    self.$author = .init { _ in
      store.users.get(by: self.authorId)
    }
    
    self.$comments = .init { _ in
      store.comments.filter { $0.postId == self.id }
    }
    
    self.$commentCount = .init { [$comments] _ in
      $comments.wrappedValue.count
    }
  }
}

final class Comment: TypedIdentifiable {
  typealias TypedIdentifierRawValue = String
  let typedID: TypedID
  
  @GraphStored var text: String
  @GraphStored var likes: Int
  
  let postId: Post.TypedID
  let authorId: User.TypedID
  
  @GraphComputed var author: User?
  @GraphComputed var post: Post?
  
  init(id: String, text: String, postId: Post.TypedID, authorId: User.TypedID, store: NormalizedStore) {
    self.typedID = .init(id)
    self.text = text
    self.likes = 0
    self.postId = postId
    self.authorId = authorId
    
    self.$author = .init { _ in
      store.users.get(by: self.authorId)
    }
    
    self.$post = .init { _ in
      store.posts.get(by: self.postId)
    }
  }
}

// Usage
let store = NormalizedStore()

// Create users
let alice = User(id: "alice", name: "Alice", email: "alice@example.com", store: store)
let bob = User(id: "bob", name: "Bob", email: "bob@example.com", store: store)

store.users.add([alice, bob])

// Create posts
let post = Post(
  id: "post1",
  title: "Hello World",
  content: "My first post!",
  authorId: alice.id,
  store: store
)

store.posts.add(post)

// Create comments
let comment = Comment(
  id: "comment1",
  text: "Great post!",
  postId: post.id,
  authorId: bob.id,
  store: store
)

store.comments.add(comment)

// Access relationships
print("Posts by Alice: \(alice.posts.count)")
print("Comments on post: \(post.commentCount)")
print("Comment author: \(comment.author?.name ?? "Unknown")")
```

## Advanced Patterns

### Computed Collections

Create collections that automatically update based on complex criteria:

```swift
final class FeedViewModel {
  let store: NormalizedStore
  let currentUserId: User.TypedID
  
  @GraphComputed var feedPosts: [Post]
  @GraphComputed var trendingPosts: [Post]
  
  init(store: NormalizedStore, currentUserId: User.TypedID) {
    self.store = store
    self.currentUserId = currentUserId
    
    // Posts from followed users
    self.$feedPosts = .init { _ in
      guard let currentUser = store.users.get(by: currentUserId) else { return [] }
      
      let followedUserIds = currentUser.followerIds
      return store.posts.filter { post in
        followedUserIds.contains(post.authorId)
      }.sorted { $0.likes > $1.likes }
    }
    
    // Posts with high engagement
    self.$trendingPosts = .init { _ in
      store.posts.filter { $0.likes > 10 }
        .sorted { $0.likes > $1.likes }
        .prefix(20)
        .map { $0 }
    }
  }
}
```

### State Synchronization

Keep UI state synchronized with normalized data:

```swift
final class PostDetailViewModel {
  @GraphStored var selectedPostId: Post.TypedID?
  
  @GraphComputed var selectedPost: Post?
  @GraphComputed var relatedPosts: [Post]
  
  init(store: NormalizedStore) {
    self.$selectedPost = .init { [$selectedPostId] _ in
      guard let postId = $selectedPostId.wrappedValue else { return nil }
      return store.posts.get(by: postId)
    }
    
    self.$relatedPosts = .init { [$selectedPost] _ in
      guard let post = $selectedPost.wrappedValue else { return [] }
      
      // Find posts by the same author
      return store.posts.filter { otherPost in
        otherPost.authorId == post.authorId && otherPost.id != post.id
      }
    }
  }
}
```

## Integration with SwiftUI

Normalized data works seamlessly with SwiftUI:

```swift
struct PostListView: View {
  let store: NormalizedStore
  
  var body: some View {
    List(store.posts.getAll()) { post in
      PostRow(post: post)
    }
  }
}

struct PostRow: View {
  let post: Post
  
  var body: some View {
    VStack(alignment: .leading) {
      Text(post.title)
        .font(.headline)
      
      Text("by \(post.author?.name ?? "Unknown")")
        .font(.caption)
        .foregroundColor(.secondary)
      
      Text("\(post.commentCount) comments • \(post.likes) likes")
        .font(.caption)
    }
  }
}
```

## Performance Considerations

### Efficient Filtering

Use indexed lookups when possible:

```swift
// ✅ Efficient: Direct lookup
let user = store.users.get(by: userId)

// ❌ Inefficient: Linear search
let user = store.users.getAll().first { $0.id == userId }
```

### Batch Operations

Group related changes together:

```swift
// Add multiple entities at once
store.users.add([user1, user2, user3])

// Modify entities in batch
userIds.forEach { userId in
  store.users.modify(userId) { user in
    user.isActive = false
  }
}
```

Swift State Graph's normalization module provides a powerful foundation for building applications with complex data relationships while maintaining the benefits of reactive programming. 