# Swift State Graph

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/vergegroup/swift-state-graph)

## Table of Contents

- [Introduction](#introduction)
- [Core Concepts](#core-concepts)
- [Installation](#installation)
- [Basic Usage](#basic-usage)
- [Describing Models](#describing-models)
- [SwiftUI Integration](#swiftui-integration)
- [UIKit Integration](#uikit-integration)
- [Advanced Usage](#advanced-usage)
- [Comparing with Swift's Observable Protocol](#comparing-with-swifts-observable-protocol)
- [Data Normalization](#data-normalization)

## Introduction

Swift State Graph is a framework designed for managing application state using a graph-based approach. It provides tools for creating and managing stored and computed properties, enabling efficient and reactive data flow within an application.

## Core Concepts

The library is built around two primary types of nodes:

### Stored Value Nodes

Stored nodes act as containers for values that can be set directly:

```swift
// Creating a stored node
let counter = Stored(wrappedValue: 0)

// Reading the value
let currentCount = counter.wrappedValue // 0

// Updating the value
counter.wrappedValue = 1
```

Stored nodes can be wrapped with the `@GraphStored` macro for cleaner syntax:

```swift
final class CounterViewModel {
  @GraphStored
  var count: Int = 0
}

// Usage
let viewModel = CounterViewModel()
viewModel.count += 1
```

### Computed Value Nodes

Computed nodes derive their values from other nodes and automatically update when dependencies change:

```swift
let a = Stored(wrappedValue: 10)
let b = Stored(wrappedValue: 20)

// This computed node depends on nodes a and b
let sum = Computed { _ in
    a.wrappedValue + b.wrappedValue
}

print(sum.wrappedValue) // 30

// When a dependency changes, the computed value updates automatically
a.wrappedValue = 15
print(sum.wrappedValue) // 35
```

### Dependency Tracking

The power of Swift State Graph lies in its automatic dependency tracking:

1. When a computed node accesses another node's value, a dependency is automatically recorded
2. When a node's value changes, all dependent nodes are marked as "potentially dirty"
3. When a potentially dirty node's value is accessed, it recalculates its value first

This creates a reactive system where changes propagate automatically through the dependency graph.

## Installation

### Swift Package Manager

Add the following to your `Package.swift` file:

```swift
dependencies: [
    .package(url: "https://github.com/VergeGroup/swift-state-graph.git", from: "0.1.0")
]
```

Then add the dependency to your target:

```swift
.target(
    name: "YourTarget",
    dependencies: ["StateGraph"]
)
```

## Basic Usage

Here's a simple example of how to use Swift State Graph:

```swift
import StateGraph

final class CounterViewModel {
  @GraphStored
  var count: Int

  @GraphComputed
  var isEven: Bool

  init(count: Int) {
    self.count = count
    self.$isEven = .init { [$count] _ in
      $count.wrappedValue % 2 == 0
    }
  }

  func increment() {
    count += 1
  }
}
```

## Describing Models

Swift State Graph makes it easy to define reactive data models. Here's an example of a library management system:

```swift
final class Author {
  @GraphStored
  var name: String

  init(name: String) {
    self.name = name
  }
}

final class Tag {
  @GraphStored
  var name: String

  init(name: String) {
    self.name = name
  }
}

final class Book {
  let author: Author

  @GraphStored
  var title: String

  @GraphStored
  var tags: [Tag]

  init(author: Author, title: String, tags: [Tag]) {
    self.author = author
    self.title = title
    self.tags = tags
  }
}

// Creating a library collection
let johnAuthor = Author(name: "John Smith")
let programmingTag = Tag(name: "Programming")
let swiftTag = Tag(name: "Swift")

let book = Book(
  author: johnAuthor,
  title: "Swift Programming",
  tags: [programmingTag, swiftTag]
)

// Creating a stored collection
let libraryCollection = Stored(wrappedValue: [book])

// Creating a computed collection filtered by author
let booksByJohn = Computed { _ in
  libraryCollection.wrappedValue.filter {
    $0.author.name == "John Smith"
  }
}

// Adding a new book automatically updates the filtered collection
let newBook = Book(
  author: johnAuthor,
  title: "Advanced Swift",
  tags: [programmingTag, swiftTag]
)
libraryCollection.wrappedValue.append(newBook)

print(booksByJohn.wrappedValue.count) // 2
```

## SwiftUI Integration

Swift State Graph integrates seamlessly with SwiftUI:

```swift
import SwiftUI
import StateGraph

final class CounterViewModel {
  @GraphStored
  var count: Int = 0
}

struct CounterView: View {
  let viewModel: CounterViewModel

  var body: some View {
    VStack {
      Text("Count: \(viewModel.count)")

      // Using the viewModel directly
      Button("Increment") {
        viewModel.count += 1
      }

      // Using a SwiftUI binding
      // The $count property accesses the underlying Stored node
      // And the binding property converts it to a SwiftUI Binding
      TextField("New Count", value: viewModel.$count.binding, format: .number)
    }
  }
}
```

## UIKit Integration

While Swift State Graph doesn't have direct UIKit-specific APIs, its reactive nature makes it easy to use with UIKit through the `withGraphTracking` function:

```swift
import UIKit
import StateGraph

final class CounterViewModel {
  @GraphStored
  var count: Int = 0

  @GraphComputed
  var isEven: Bool

  init() {
    self.$isEven = .init { [$count] _ in
      $count.wrappedValue % 2 == 0
    }
  }
}

class CounterViewController: UIViewController {
  private let viewModel = CounterViewModel()
  private var subscription: AnyCancellable?

  private let countLabel = UILabel()
  private let evenOddLabel = UILabel()
  private let incrementButton = UIButton(type: .system)

  override func viewDidLoad() {
    super.viewDidLoad()
    setupUI()
    bindViewModel()
  }

  private func setupUI() {
    ...
  }

  private func bindViewModel() {
    // Initial update
    updateUI()

    // Reactive updates
    subscription = withGraphTracking {
      viewModel.$count.onChange { value in
        // Handle count changes if needed
      }
      viewModel.$isEven.onChange { value in
        // Handle isEven changes if needed
      }

      // Define what happens when changes occur
      Computed { _ in
        (viewModel.count, viewModel.isEven)
      }
      .onChange { [weak self] _ in
        self?.updateUI()
      }
    }
  }

  private func updateUI() {
    countLabel.text = "Count: \(viewModel.count)"
    evenOddLabel.text = viewModel.isEven ? "Even" : "Odd"
  }

  @objc private func incrementCount() {
    viewModel.count += 1
  }
}
```

## Advanced Usage

### Subscribing to Multiple Nodes with `withGraphTracking`

The `withGraphTracking` function allows you to create a subscription that observes multiple nodes at once:

```swift
// Example: Managing product availability in an e-commerce app

// Model for product and cart
final class StoreViewModel {
  @GraphStored var stockLevel: Int = 10 // Available stock for a product
  @GraphStored var itemsInCart: Int = 0  // Number of this product in the user's cart
}

let viewModel = StoreViewModel()

// Subscription to track product availability
// Keep this subscription instance to keep tracking active.
var availabilitySubscription: AnyCancellable?

availabilitySubscription = withGraphTracking {
  // Computed node to determine if the product can be added to cart
  Computed { _ in
    // This computation runs when `stockLevel` or `itemsInCart` changes.
    viewModel.stockLevel > viewModel.itemsInCart
  }
  .onChange { isAvailable in
    // This block is called when the `isAvailable` value changes.
    if isAvailable {
      print("✅ Product is available to add to cart.")
    } else {
      print("⚠️ Product is out of stock or cart limit reached.")
    }
  }

  // Observe changes in stock level directly
  viewModel.$stockLevel.onChange { newStock in
    print("📦 Stock level updated: \(newStock)")
  }

  // Observe changes in items in cart directly
  viewModel.$itemsInCart.onChange { items in
    print("🛒 Items in cart updated: \(items)")
  }
}

// --- Example of how this works ---
// Simulate adding an item to the cart
// viewModel.itemsInCart = 1
// Output will be:
// 🛒 Items in cart updated: 1
// ✅ Product is available to add to cart.

// Simulate stock running out
// viewModel.stockLevel = 0
// Output will be:
// 📦 Stock level updated: 0
// ⚠️ Product is out of stock or cart limit reached.

// To stop tracking, set the subscription to nil
// availabilitySubscription = nil
```

### Key Features

- **Unified Subscription**: All nodes registered within the tracking block are bundled into a single subscription.
- **Automatic Cleanup**: When the returned subscription object is deallocated, all registered callbacks are automatically removed.
- **Reactive Programming**: Changes in any dependent node will trigger the appropriate callbacks without manual observer management.

### Usage Patterns

1. **Non-UI State Reactions**:
   ```swift
   subscription = withGraphTracking {
     model.$isLoggedIn.onChange { isLoggedIn in
       if isLoggedIn {
         analyticsService.logEvent("user_login")
       }
     }
   }
   ```

2. **Derived Calculations**:
   ```swift
   subscription = withGraphTracking {
     Computed { _ in
       repository.items.filter { $0.isCompleted }.count
     }
     .onChange { completedCount in
       if completedCount == repository.items.count {
         notificationService.sendCompletionNotification()
       }
     }
   }
   ```

3. **Multi-value Dependencies**:
   ```swift
   subscription = withGraphTracking {
     Computed { _ in
       (authService.isAuthorized, networkMonitor.isConnected)
     }
     .onChange { (isAuthorized, isConnected) in
       syncService.canSync = isAuthorized && isConnected
     }
   }
   ```

By storing the returned subscription object in a property, you ensure the tracking remains active for as long as needed.

## Comparing with Swift's Observable Protocol

The key difference between Swift State Graph and Swift's standard `Observable` protocol is the presence of **Computed nodes** in Swift State Graph.

While the standard `Observable` protocol in Swift is designed for observing changes to stored properties, Swift State Graph introduces **Computed nodes** that can automatically derive their values from other nodes.
These computed nodes track dependencies and update reactively when any of their source nodes change, enabling more powerful and declarative state relationships.

**Example:**

```swift
let stored = Stored(wrappedValue: 10)

let computed = Computed { _ in stored.wrappedValue * 2 }

// computed.wrappedValue => 20

stored.wrappedValue = 20

// computed.wrappedValue => 40 (automatically updated)
```

With Swift State Graph, you can build complex, reactive data flows that are difficult to achieve with just the `Observable` protocol.

## Data Normalization

Swift State Graph provides a normalization module for efficiently managing and accessing related data. The `StateGraphNormalization` module helps you organize your data in a normalized structure, making it easier to handle complex relationships between entities.

### Core Concepts

#### EntityStore

`EntityStore` is a generic container for managing collections of entities with unique identifiers:

```swift
// Creating an entity store for a specific entity type
let userStore = EntityStore<User>()
let postStore = EntityStore<Post>()

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
// or
userStore.modify(userId) { user in 
  user.name = "New Name"
}

// Checking conditions
let hasUser = userStore.contains(userId)
let count = userStore.count

// Removing entities
userStore.delete(userId)
```

#### TypedIdentifiable

Entities stored in an `EntityStore` must conform to the `TypedIdentifiable` protocol, which provides type-safe identifiers:

```swift
final class User: TypedIdentifiable {
  typealias TypedIdentifierRawValue = String
  
  let typedID: TypedID
  
  @GraphStored
  var name: String
  
  init(id: String, name: String) {
    self.typedID = .init(id)
    self.name = name
  }
}
```

#### NormalizedStore

`NormalizedStore` acts as a central repository for managing multiple entity types:

```swift
final class NormalizedStore {
  @GraphStored
  var users: EntityStore<User> = .init()
  
  @GraphStored
  var posts: EntityStore<Post> = .init()
  
  @GraphStored
  var comments: EntityStore<Comment> = .init()
}
```

### Example: Social Media Application

Here's an example of using normalization in a social media application:

```swift
// Define entity types
final class User: TypedIdentifiable {
  typealias TypedIdentifierRawValue = String
  let typedID: TypedID
  
  @GraphStored var name: String
  @GraphComputed var posts: [Post]
  
  init(id: String, name: String, store: NormalizedStore) {
    self.typedID = .init(id)
    self.name = name
    self.$posts = .init { _ in
      store.posts.filter { $0.author.id == self.id }
    }
  }
}

final class Post: TypedIdentifiable {
  typealias TypedIdentifierRawValue = String
  let typedID: TypedID
  
  @GraphStored var title: String
  @GraphStored var content: String
  let author: User
  
  @GraphComputed var comments: [Comment]
  
  init(id: String, title: String, content: String, author: User, store: NormalizedStore) {
    self.typedID = .init(id)
    self.title = title
    self.content = content
    self.author = author
    self.$comments = .init { _ in
      store.comments.filter { $0.post.id == self.id }
    }
  }
}

final class Comment: TypedIdentifiable {
  typealias TypedIdentifierRawValue = String
  let typedID: TypedID
  
  @GraphStored var text: String
  let post: Post
  let author: User
  
  init(id: String, text: String, post: Post, author: User) {
    self.typedID = .init(id)
    self.text = text
    self.post = post
    self.author = author
  }
}

// Create and use a normalized store
let store = NormalizedStore()

// Create entities
let user = User(id: "user1", name: "John", store: store)
store.users.add(user)

let post = Post(id: "post1", title: "Hello World", content: "My first post", author: user, store: store)
store.posts.add(post)

let comment = Comment(id: "comment1", text: "Great post!", post: post, author: user)
store.comments.add(comment)

// Access related entities through computed properties
print(user.posts.count) // 1
print(post.comments.count) // 1
```

### Benefits of Normalization

Using the normalization module provides several advantages:

1. **Single Source of Truth**: Entities are stored once, preventing duplication and inconsistencies
2. **Efficient Updates**: Changes to an entity are automatically reflected in all computed properties
3. **Relationship Management**: Easily handle one-to-many and many-to-many relationships
4. **Performance**: Optimized for fast lookups and updates through ID-based access
5. **Reactivity**: Combined with State Graph's dependency tracking for automatic UI updates

### Sharing State Between Objects with @GraphStored Reference Assignment

Swift State Graph allows you to share state between different objects by directly assigning `@GraphStored` property references. This pattern is particularly useful for creating clean architectures where ViewModels observe state from Services or other data sources.

#### Simple Example: Direct @GraphStored Sharing

```swift
// Service
final class DataService {
  @GraphStored var items: [Item] = []
  @GraphStored var isLoading: Bool = false
}

// ViewModel
final class ViewModel: ObservableObject { // ObservableObject conformance only for @StateObject usage
  @GraphStored var items: [Item]
  @GraphStored var isLoading: Bool
  
  init(service: DataService) {
    // Simply pass @GraphStored directly
    self.$items = service.$items
    self.$isLoading = service.$isLoading
  }
}
```

**Creating unnecessary instances:**
```swift
// ❌ No need to create new Stored instances
self.$items = service.$items.map { _, value in value }
```

**Simple approach:**
```swift
// ✅ Direct assignment
self.$items = service.$items
```

#### Benefits

- **Simple**: Eliminates verbose mapping functions
- **Performance**: Avoids unnecessary computation overhead
- **Reactive**: Source changes automatically propagate

#### Use Cases

- Exposing service state to ViewModels
- Simple sharing without state transformation
- Loose coupling in MVVM architectures

This reference sharing pattern is particularly powerful in MVVM architectures where you want view models to reactively observe service state without tight coupling.