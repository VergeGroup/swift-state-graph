
# Swift State Graph

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/vergegroup/swift-state-graph)

## Introduction

StateGraph is a Swift framework designed for managing application state using a graph-based approach. It provides tools for creating and managing stored and computed properties, enabling efficient and reactive data flow within an application.

## Overview

```swift
final class MyObject {
  @GraphStored
  var count: Int = 0
}
```

```swift
struct MyView {
  let object: MyObject

  var body: some View {
    VStack {
      Text("\(object.count)")
      Button("Increment") {
        object.count += 1
      }
    }
  }
}
```

## `@GraphStored` Macro

`@GraphStored` macro lets you easily declare a `Stored<Value>` node as a property. It automatically generates and manages the underlying `Stored<Value>` instance for you, so you can write clean and declarative code.

### Usage

When you declare a property with `@GraphStored`:

```swift
final class MyViewModel {
  @GraphStored var count: Int = 0
}
```

Expanded
```swift
final class MyViewModel {
  @GraphStored var count: Int {
    get {
      return $count.wrappedValue
    }
    set {
      $count.wrappedValue = newValue
    }
  }
  @GraphIgnored let $count: Stored<Int> = .init(name: "count", wrappedValue: 0)
}
```

## Core Concept

There are 2 primitive types.

**Stored value node**

**Computed value node**

Computed value nodes depend on other nodes.

```swift
let stored = Stored(wrappedValue: 10)

let computed = Computed(wrappedValue: 0) { _ in stored.wrappedValue * 2 }

// computed.wrappedValue => 20

stored.wrappedValue = 20

// computed.wrappedValue => 40
```

## What's the difference from using `Observable` protocol object

The key difference is the presence of **Computed nodes** in swift-state-graph.

While the standard `Observable` protocol in Swift is designed for observing changes to stored properties, swift-state-graph introduces **Computed nodes** that can automatically derive their values from other nodes.  
These computed nodes track dependencies and update reactively when any of their source nodes change, enabling more powerful and declarative state relationships.

**Example:**

```swift
let stored = Stored(wrappedValue: 10)

let computed = Computed { _ in stored.wrappedValue * 2 }

// computed.wrappedValue => 20

stored.wrappedValue = 20

// computed.wrappedValue => 40 (automatically updated)
```

With swift-state-graph, you can build complex, reactive data flows that are difficult to achieve with just the `Observable` protocol.

## Using StateGraph Outside of SwiftUI

StateGraph provides a powerful way to observe and respond to state changes outside of SwiftUI's view hierarchy. This is particularly useful for non-UI logic, background processing, or when working with other UI frameworks.

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
var availabilitySubscription: StateGraphSubscription? 

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
