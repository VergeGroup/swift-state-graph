
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
  var count: Int = 0

  @GraphComputed
  var isEven: Bool {
    count % 2 == 0
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
  var isEven: Bool {
    count % 2 == 0
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
    view.backgroundColor = .white

    countLabel.translatesAutoresizingMaskIntoConstraints = false
    evenOddLabel.translatesAutoresizingMaskIntoConstraints = false
    incrementButton.translatesAutoresizingMaskIntoConstraints = false

    incrementButton.setTitle("Increment", for: .normal)
    incrementButton.addTarget(self, action: #selector(incrementCount), for: .touchUpInside)

    view.addSubview(countLabel)
    view.addSubview(evenOddLabel)
    view.addSubview(incrementButton)

    NSLayoutConstraint.activate([
      countLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      countLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),

      evenOddLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      evenOddLabel.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 20),

      incrementButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      incrementButton.topAnchor.constraint(equalTo: evenOddLabel.bottomAnchor, constant: 20)
    ])
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
