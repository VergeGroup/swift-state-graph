# Core Concepts

Understanding the fundamental building blocks of Swift State Graph.

## Overview

Swift State Graph is built around a simple but powerful concept: a graph where nodes represent values and edges represent dependencies. When a value changes, the graph automatically propagates those changes to all dependent values.

The framework provides two primary types of nodes that form the foundation of your reactive data models.

## Stored Value Nodes

Stored nodes are containers for values that can be set directly from the outside. They serve as the foundation of your state graph - the "source of truth" from which all other values are derived.

### Basic Usage

```swift
import StateGraph

// Creating a stored node directly
let counter = Stored(wrappedValue: 0)

// Reading the value
let currentCount = counter.wrappedValue // 0

// Updating the value
counter.wrappedValue = 1
```

### Using the @GraphStored Macro

For cleaner syntax in your classes, use the `@GraphStored` macro:

```swift
final class UserProfile {
  @GraphStored
  var name: String = ""
  
  @GraphStored
  var email: String = ""
  
  @GraphStored
  var age: Int = 0
}

// Usage
let profile = UserProfile()
profile.name = "John Doe"
profile.email = "john@example.com"
profile.age = 30
```

### Persistent Storage

`@GraphStored` properties can also use persistent backing storage like UserDefaults:

```swift
final class AppSettings {
  // This value persists across app launches
  @GraphStored(backed: .userDefaults(key: "userName"))
  var userName: String = ""
  
  // Computed properties work with persistent storage too
  @GraphComputed
  var welcomeMessage: String
  
  init() {
    self.$welcomeMessage = .init { [$userName] _ in
      let name = $userName.wrappedValue
      return name.isEmpty ? "Welcome!" : "Welcome, \(name)!"
    }
  }
}
```

See <doc:Backing-Storage> for comprehensive coverage of storage options.

### Characteristics of Stored Nodes

- **Mutable**: Values can be changed from outside
- **Source Nodes**: They don't depend on other nodes
- **Change Propagation**: When their value changes, all dependent nodes are notified
- **Observable**: They integrate with SwiftUI and other observation systems

## Computed Value Nodes

Computed nodes derive their values from other nodes and automatically update when their dependencies change. They represent the "derived state" in your application.

### Basic Usage

```swift
let firstName = Stored(wrappedValue: "John")
let lastName = Stored(wrappedValue: "Doe")

// This computed node depends on firstName and lastName
let fullName = Computed { _ in
    "\(firstName.wrappedValue) \(lastName.wrappedValue)"
}

print(fullName.wrappedValue) // "John Doe"

// When a dependency changes, the computed value updates automatically
firstName.wrappedValue = "Jane"
print(fullName.wrappedValue) // "Jane Doe"
```

### Using the @GraphComputed Macro

For properties in classes, use the `@GraphComputed` macro:

```swift
final class PersonViewModel {
  @GraphStored
  var firstName: String = ""
  
  @GraphStored
  var lastName: String = ""
  
  @GraphComputed
  var fullName: String
  
  @GraphComputed
  var initials: String
  
  init() {
    // Define how fullName is computed
    self.$fullName = .init { [$firstName, $lastName] _ in
      "\($firstName.wrappedValue) \($lastName.wrappedValue)"
    }
    
    // Define how initials is computed
    self.$initials = .init { [$firstName, $lastName] _ in
      let first = $firstName.wrappedValue.first?.uppercased() ?? ""
      let last = $lastName.wrappedValue.first?.uppercased() ?? ""
      return "\(first)\(last)"
    }
  }
}
```

### Characteristics of Computed Nodes

- **Read-Only**: Their values cannot be set directly
- **Lazy**: Values are computed only when accessed
- **Cached**: Results are cached until dependencies change
- **Dependent**: They automatically track which nodes they depend on
- **Efficient**: Only recalculate when necessary

## Dependency Tracking

The power of Swift State Graph lies in its automatic dependency tracking system:

### How Dependencies Are Tracked

1. **Access Detection**: When a computed node accesses another node's value, a dependency is automatically recorded
2. **Change Notification**: When a node's value changes, all dependent nodes are marked as "potentially dirty"
3. **Lazy Recalculation**: When a potentially dirty node's value is accessed, it recalculates its value first

### Dependency Declaration

In computed properties, you should capture dependencies in the closure's capture list:

```swift
// ✅ Correct: Dependencies explicitly captured
self.$computed = .init { [$dependency1, $dependency2] _ in
  $dependency1.wrappedValue + $dependency2.wrappedValue
}

// ❌ Incorrect: Dependencies not captured (may not be tracked)
self.$computed = .init { _ in
  dependency1 + dependency2  // Global access - not tracked
}
```

### Cascade Updates

Dependencies form a graph, and changes cascade through it automatically:

```swift
final class ShoppingCartViewModel {
  @GraphStored
  var items: [CartItem] = []
  
  @GraphStored
  var taxRate: Double = 0.08
  
  @GraphComputed
  var subtotal: Double
  
  @GraphComputed
  var tax: Double
  
  @GraphComputed
  var total: Double
  
  init() {
    // subtotal depends on items
    self.$subtotal = .init { [$items] _ in
      $items.wrappedValue.reduce(0) { $0 + $1.price }
    }
    
    // tax depends on subtotal and taxRate
    self.$tax = .init { [$subtotal, $taxRate] _ in
      $subtotal.wrappedValue * $taxRate.wrappedValue
    }
    
    // total depends on subtotal and tax
    self.$total = .init { [$subtotal, $tax] _ in
      $subtotal.wrappedValue + $tax.wrappedValue
    }
  }
}

// When items change, subtotal → tax → total all update automatically
```

## The Reactive System

This creates a reactive system where:

- **Changes Flow Automatically**: Update one value, and all derived values update
- **Minimal Computation**: Only values that actually changed are recalculated
- **No Manual Synchronization**: No need to remember to call update methods
- **Declarative**: Your code expresses what values depend on, not how to update them

## Memory Management

Swift State Graph uses weak references and automatic cleanup to prevent memory leaks:

- **Weak Node References**: Dependency edges use weak references
- **Automatic Cleanup**: When nodes are deallocated, they clean up their edges
- **Subscription Management**: Observation subscriptions are automatically managed

## Type Safety

The system is fully type-safe:

- **Compile-Time Checking**: Dependencies are checked at compile time
- **Generic Types**: Full support for Swift's generic system
- **Optional Support**: Proper handling of optional values

## Performance Characteristics

Understanding the performance implications:

- **O(1) Access**: Reading cached computed values is constant time
- **Lazy Evaluation**: Expensive computations only run when needed
- **Batched Updates**: Multiple changes can be batched together
- **Memory Efficient**: Only stores what's necessary

## Next Steps

Now that you understand the core concepts:

- <doc:Describing-Models> - Learn to build complex reactive models
- <doc:Advanced-Patterns> - Explore advanced usage patterns
- <doc:Performance-Optimization> - Optimize your state graphs for performance 