# Swift State Graph

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/vergegroup/swift-state-graph)

A powerful reactive state management library for Swift applications that uses a Directed Acyclic Graph (DAG) to manage data flow and dependencies.

## Key Features

- 🔄 **Automatic Dependency Tracking** - Nodes automatically track which other nodes they depend on
- 🚀 **Lazy Evaluation** - Computed values only recalculate when accessed after dependencies change
- 🛡️ **Thread Safe** - Built-in concurrency protection with NSRecursiveLock
- 📱 **Platform Support** - Works seamlessly with SwiftUI, UIKit, and AppKit
- 💾 **Persistent Storage** - Optional backing storage with UserDefaults
- 🧩 **Swift Macros** - Clean syntax with @GraphStored and @GraphComputed

## Requirements

- Swift 5.9+
- iOS 13.0+ / macOS 10.15+ / tvOS 13.0+ / watchOS 6.0+
- Xcode 15.0+

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

## 🚀 Quick Start

Here's a glimpse of how Swift State Graph simplifies state management:

```swift
import StateGraph

final class CounterModel {
  // @GraphStored creates a mutable stored property
  @GraphStored
  var count: Int

  // @GraphComputed creates a derived property that updates automatically
  @GraphComputed
  var isEven: Bool

  init(count: Int) {
    self.count = count
    
    // Define how isEven is computed from count
    // The [$count] syntax captures the dependency
    self.$isEven = .init { [$count] _ in
      $count.wrappedValue % 2 == 0
    }
  }  
}

struct CounterView: View {
  let model: CounterModel
  
  var body: some View {
    VStack {
      // The view automatically updates when count changes
      Text("Count: \(model.count)")
      Text("Is even: \(model.isEven ? "Yes" : "No")")
      
      Button("Increment") {
        // Changing count automatically updates isEven
        model.count += 1
      }
    }
  }
}

```


## Table of Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [🚀 Quick Start](#-quick-start)
- [Core Concepts](#core-concepts)
- [Backing Storage](#backing-storage)
- [Describing Models](#describing-models)
- [SwiftUI Integration](#swiftui-integration)
  - [Environment Integration with GraphObject](#environment-integration-with-graphobject)
- [UIKit Integration](#uikit-integration)
- [Advanced Usage](#advanced-usage)
- [Comparing with Observable Protocol](#comparing-with-observable-protocol)
- [Migration from Observable](#migration-from-observable)
- [Data Normalization](#data-normalization)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)
- [Contributing](#contributing)

## Core Concepts

Swift State Graph is built around two primary types of nodes:

### Stored Value Nodes

Stored nodes act as containers for values that can be set directly:

```swift
// Direct API usage
let counter = Stored(wrappedValue: 0)
print(counter.wrappedValue)  // 0
counter.wrappedValue = 1
print(counter.wrappedValue)  // 1

// Property wrapper usage (recommended)
final class Model {
  @GraphStored var counter: Int = 0
}

let model = Model()
model.counter = 1  // Clean syntax with property wrapper
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
// Example: Shopping cart totals
let price = Stored(wrappedValue: 10.0)
let quantity = Stored(wrappedValue: 3)
let taxRate = Stored(wrappedValue: 0.08)

// Subtotal depends on price and quantity
let subtotal = Computed { _ in
    price.wrappedValue * Double(quantity.wrappedValue)
}

// Tax depends on subtotal and taxRate
let tax = Computed { _ in
    subtotal.wrappedValue * taxRate.wrappedValue
}

// Total depends on subtotal and tax
let total = Computed { _ in
    subtotal.wrappedValue + tax.wrappedValue
}

print("Initial total: $\(total.wrappedValue)")  // $32.40

// Change quantity - all dependent values update
quantity.wrappedValue = 5
print("New total: $\(total.wrappedValue)")     // $54.00
```

### Automatic Dependency Tracking

The power of Swift State Graph lies in its automatic dependency tracking:

1. When a computed node accesses another node's value, a dependency is automatically recorded
2. When a node's value changes, all dependent nodes are marked as "potentially dirty"
3. When a potentially dirty node's value is accessed, it recalculates its value first

This creates a reactive system where changes propagate automatically through the dependency graph.


## Backing Storage

Swift State Graph provides flexible backing storage options for your stored properties, allowing you to persist data beyond in-memory storage.

### In-Memory Storage (Default)

By default, `@GraphStored` properties use in-memory storage:

```swift
final class ViewModel {
  @GraphStored var count: Int = 0  // In-memory storage
}
```

### UserDefaults Storage

You can back your stored properties with UserDefaults for automatic persistence:

```swift
final class SettingsViewModel {
  // Basic UserDefaults storage
  @GraphStored(backed: .userDefaults(key: "theme")) 
  var theme: String = "light"
  
  // UserDefaults with custom suite
  @GraphStored(backed: .userDefaults(suite: "com.myapp.settings", key: "apiUrl"))
  var apiUrl: String = "https://api.example.com"
  
  // All GraphStored features work with backing storage
  @GraphComputed
  var isDarkMode: Bool
  
  init() {
    self.$isDarkMode = .init { [$theme] _ in
      $theme.wrappedValue == "dark"
    }
  }
}
```

### Reactive Persistence

Backing storage integrates seamlessly with the reactive system:

```swift
final class UserPreferencesViewModel {
  @GraphStored(backed: .userDefaults(key: "userName"))
  var userName: String = ""
  
  @GraphStored(backed: .userDefaults(key: "notificationsEnabled"))
  var notificationsEnabled: Bool = true
  
  @GraphComputed
  var welcomeMessage: String
  
  init() {
    self.$welcomeMessage = .init { [$userName] _ in
      let name = $userName.wrappedValue
      return name.isEmpty ? "Welcome!" : "Welcome, \(name)!"
    }
  }
  
  // Changes are automatically persisted to UserDefaults
  func updateUserName(_ name: String) {
    userName = name  // Automatically saved to UserDefaults
  }
}
```

### SwiftUI Integration with Backing Storage

Backing storage works seamlessly with SwiftUI bindings:

```swift
struct SettingsView: View {
  let viewModel: SettingsViewModel
  
  var body: some View {
    Form {
      Section("Appearance") {
        Picker("Theme", selection: viewModel.$theme.binding) {
          Text("Light").tag("light")
          Text("Dark").tag("dark")
        }
        
        Text("Dark mode: \(viewModel.isDarkMode ? "On" : "Off")")
      }
      
      Section("Network") {
        TextField("API URL", text: viewModel.$apiUrl.binding)
      }
    }
    // Changes are automatically persisted!
  }
}
```

### Storage Types

Swift State Graph supports multiple backing storage types through the `GraphStorageBacking` enum:

```swift
public enum GraphStorageBacking {
  case memory                                          // In-memory (default)
  case userDefaults(key: String)                      // UserDefaults with key
  case userDefaults(suite: String, key: String)       // UserDefaults with suite
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

Swift State Graph integrates seamlessly with SwiftUI's reactive paradigm:

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

### Environment Integration with GraphObject

Swift State Graph provides seamless integration with SwiftUI's Environment system through the `GraphObject` protocol. This allows you to pass state objects through the SwiftUI view hierarchy, much like native Observable objects but with the added benefits of automatic dependency tracking.

#### Defining a GraphObject

To make your state object compatible with SwiftUI's Environment, conform to the `GraphObject` protocol:

```swift
import SwiftUI
import StateGraph

@available(iOS 17.0, *)
final class AppState: GraphObject {
  @GraphStored var count: Int = 0
  @GraphStored var userName: String = ""
  
  @GraphComputed var displayName: String
  
  init() {
    self.$displayName = .init { [$userName] _ in
      $userName.wrappedValue.isEmpty ? "Anonymous" : $userName.wrappedValue
    }
  }
}
```

#### Injecting State into the Environment

Pass your GraphObject into the SwiftUI environment using the standard `.environment()` modifier:

```swift
struct ParentView: View {
  let appState: AppState
  
  var body: some View {
    VStack {
      ChildView()
      
      Button("Increment") {
        appState.count += 1
      }
    }
    .environment(appState) // Inject the state object
  }
}
```

#### Accessing State from Child Views

Child views can access the injected state using the standard `@Environment` property wrapper:

```swift
struct ChildView: View {
  @Environment(AppState.self) private var appState
  
  var body: some View {
    VStack {
      Text("Count: \(appState.count)")
      Text("User: \(appState.displayName)")
      
      TextField("Enter name", text: appState.$userName.binding)
    }
  }
}
```

#### Key Benefits

- **Standard SwiftUI patterns**: Works exactly like Observable objects
- **Automatic reactivity**: Changes automatically update the UI
- **Computed properties**: Derived state updates automatically when dependencies change
- **Type safety**: Full type checking and autocomplete support
- **Performance**: Efficient dependency tracking and minimal re-renders

#### Complete Example

```swift
@available(iOS 17.0, *)
@Observable
final class ShoppingCartModel: GraphObject {
  @GraphStored var items: [CartItem] = []
  @GraphStored var taxRate: Double = 0.08
  
  @GraphComputed var subtotal: Double
  @GraphComputed var tax: Double
  @GraphComputed var total: Double
  
  init() {
    self.$subtotal = .init { [$items] _ in
      $items.wrappedValue.reduce(0) { $0 + $1.price }
    }
    
    self.$tax = .init { [$subtotal, $taxRate] _ in
      $subtotal.wrappedValue * $taxRate.wrappedValue
    }
    
    self.$total = .init { [$subtotal, $tax] _ in
      $subtotal.wrappedValue + $tax.wrappedValue
    }
  }
}

struct ShoppingCartApp: View {
  let cartModel: ShoppingCartModel
  
  var body: some View {
    NavigationView {
      CartView()
        .environment(cartModel)
    }
  }
}

struct CartView: View {
  @Environment(ShoppingCartModel.self) private var cart
  
  var body: some View {
    List {
      ForEach(cart.items) { item in
        Text(item.name)
      }
      
      Section("Summary") {
        HStack {
          Text("Subtotal")
          Spacer()
          Text("$\(cart.subtotal, specifier: "%.2f")")
        }
        
        HStack {
          Text("Tax")
          Spacer()
          Text("$\(cart.tax, specifier: "%.2f")")
        }
        
        HStack {
          Text("Total")
          Spacer()
          Text("$\(cart.total, specifier: "%.2f")")
        }
      }
    }
  }
}
```

**Note**: GraphObject requires iOS 17.0 or later as it builds on Swift's `Observable` protocol.

## UIKit Integration

While Swift State Graph doesn't have direct UIKit-specific APIs, its reactive nature and tools like `withGraphTracking` make it easy to manage state in UIKit applications:

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

final class StoreViewModel {
  @GraphStored var stockLevel: Int = 10  // Current stock
  @GraphStored var itemsInCart: Int = 0  // Items in user's cart
}

let viewModel = StoreViewModel()

// Create a subscription to track multiple nodes at once
var availabilitySubscription: AnyCancellable?

availabilitySubscription = withGraphTracking {
  // 1. Create a computed value that depends on multiple nodes
  Computed { _ in
    viewModel.stockLevel > viewModel.itemsInCart
  }
  .onChange { isAvailable in
    // Called whenever the computed value changes
    if isAvailable {
      print("✅ Product is available")
    } else {
      print("⚠️ Product unavailable")
    }
  }

  // 2. Track individual property changes
  viewModel.$stockLevel.onChange { newStock in
    print("📦 Stock updated: \(newStock)")
  }

  viewModel.$itemsInCart.onChange { items in
    print("🛒 Cart updated: \(items) items")
  }
}

// Example usage:
viewModel.itemsInCart = 5   // Triggers: "🛒 Cart updated: 5 items"
viewModel.stockLevel = 3    // Triggers: "📦 Stock updated: 3" AND "⚠️ Product unavailable"

// Clean up when done
availabilitySubscription = nil
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

## Comparing with Observable Protocol

The primary differentiator for Swift State Graph over Swift's standard `Observable` protocol is its sophisticated approach to computed properties and automatic dependency tracking.

While Observable provides basic observation of stored properties, Swift State Graph introduces graph-based computed nodes that automatically derive their values from other nodes, track dependencies, and update reactively when source nodes change.

### Feature Comparison

| Feature | Observable | Swift State Graph |
|---------|------------|------------------|
| Stored Properties | ✅ @Observable | ✅ @GraphStored |
| Computed Properties | ❌ Manual updates | ✅ Automatic with @GraphComputed |
| Dependency Tracking | ❌ Manual | ✅ Automatic |
| Lazy Evaluation | ❌ | ✅ |
| Backing Storage | ❌ | ✅ UserDefaults, etc. |
| Thread Safety | ⚠️ Actor isolation | ✅ Built-in locks |

### Example: Computed Properties

```swift
// Observable approach - manual updates needed
@Observable
class PriceModel {
  var basePrice: Double = 100
  var taxRate: Double = 0.08
  var total: Double = 108  // Must manually update
  
  func updateTotal() {
    total = basePrice * (1 + taxRate)
  }
}

// Swift State Graph - automatic updates
class PriceModel {
  @GraphStored var basePrice: Double = 100
  @GraphStored var taxRate: Double = 0.08
  @GraphComputed var total: Double
  
  init() {
    self.$total = .init { [$basePrice, $taxRate] _ in
      $basePrice.wrappedValue * (1 + $taxRate.wrappedValue)
    }
  }
}
```

## Migration from Observable

If you're currently using Swift's `@Observable` protocol, migrating to Swift State Graph can enhance your state management capabilities through automatic dependency tracking and powerful computed properties.

### Basic Observable Class Migration

**Before: Using @Observable**
```swift
import Observation

@Observable
final class UserViewModel {
  var name: String = ""
  var email: String = ""
  var isValid: Bool = false
  
  func updateValidation() {
    isValid = !name.isEmpty && email.contains("@")
  }
}
```

**After: Using Swift State Graph**
```swift
import StateGraph

final class UserViewModel {
  @GraphStored
  var name: String = ""
  
  @GraphStored
  var email: String = ""
  
  @GraphComputed
  var isValid: Bool
  
  init() {
    self.$isValid = .init { [$name, $email] _ in
      !$name.wrappedValue.isEmpty && $email.wrappedValue.contains("@")
    }
  }
}
```

**Benefits of the migration:**
- **Automatic computation**: `isValid` is automatically updated when `name` or `email` changes
- **No manual validation calls**: No need to call `updateValidation()` manually
- **Dependency tracking**: The framework automatically knows when to recalculate

### ObservationTracking Migration

**Before: Using withObservationTracking**
```swift
import Observation

final class ViewController {
  private let viewModel = UserViewModel()
  private var observationTask: Task<Void, Never>?
  
  func setupObservation() {
    observationTask = Task {
      while !Task.isCancelled {
        await withObservationTracking {
          // Read values to establish tracking
          _ = viewModel.name
          _ = viewModel.email
          _ = viewModel.isValid
        } onChange: {
          await MainActor.run {
            updateUI()
          }
        }
      }
    }
  }
  
  private func updateUI() {
    // Update UI based on viewModel state
  }
}
```

**After: Using withGraphTracking**
```swift
import StateGraph

final class ViewController {
  private let viewModel = UserViewModel()
  private var subscription: AnyCancellable?
  
  func setupObservation() {
    subscription = withGraphTracking {
      viewModel.$name.onChange { [weak self] name in
        self?.updateNameLabel(name)
      }
      
      viewModel.$email.onChange { [weak self] email in
        self?.updateEmailField(email)
      }
      
      viewModel.$isValid.onChange { [weak self] isValid in
        self?.updateSubmitButton(isValid)
      }
    }
  }
  
  private func updateNameLabel(_ name: String) { /* Update name label */ }
  private func updateEmailField(_ email: String) { /* Update email field */ }
  private func updateSubmitButton(_ isValid: Bool) { /* Update submit button */ }
}
```

**Benefits of the migration:**
- **Granular callbacks**: Separate callbacks for each property change
- **Simpler lifecycle**: No need for Task management
- **Automatic cleanup**: Subscription automatically manages memory

### Complex Dependencies Migration

**Before: Manual dependency management**
```swift
@Observable
final class ShoppingCartViewModel {
  var items: [CartItem] = []
  var taxRate: Double = 0.08
  var subtotal: Double = 0.0
  var tax: Double = 0.0
  var total: Double = 0.0
  
  func recalculateAll() {
    subtotal = items.reduce(0) { $0 + ($1.price * Double($1.quantity)) }
    tax = subtotal * taxRate
    total = subtotal + tax
  }
}
```

**After: Automatic dependency tracking**
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
    self.$subtotal = .init { [$items] _ in
      $items.wrappedValue.reduce(0) { $0 + ($1.price * Double($1.quantity)) }
    }
    
    self.$tax = .init { [$subtotal, $taxRate] _ in
      $subtotal.wrappedValue * $taxRate.wrappedValue
    }
    
    self.$total = .init { [$subtotal, $tax] _ in
      $subtotal.wrappedValue + $tax.wrappedValue
    }
  }
}
```

**Benefits of the migration:**
- **Cascade updates**: Changes to `items` automatically update `subtotal`, which updates `tax` and `total`
- **Efficient computation**: Only recalculates what's necessary
- **Clear dependencies**: Each computed property explicitly declares its dependencies

### SwiftUI Integration Migration

**Before: Observable in SwiftUI**
```swift
import SwiftUI
import Observation

struct ContentView: View {
  let viewModel: UserViewModel
  
  var body: some View {
    VStack {
      TextField("Name", text: $viewModel.name)
        .onChange(of: viewModel.name) { _, _ in
          viewModel.updateValidation()
        }
      
      TextField("Email", text: $viewModel.email)
        .onChange(of: viewModel.email) { _, _ in
          viewModel.updateValidation()
        }
      
      Button("Submit") {
        submitForm()
      }
      .disabled(!viewModel.isValid)
    }
  }
}
```

**After: Swift State Graph in SwiftUI**
```swift
import SwiftUI
import StateGraph

struct ContentView: View {
  let viewModel: UserViewModel
  
  var body: some View {
    VStack {
      TextField("Name", text: viewModel.$name.binding)
      TextField("Email", text: viewModel.$email.binding)
      
      Button("Submit") {
        submitForm()
      }
      .disabled(!viewModel.isValid)
    }
  }
}
```

**Benefits of the migration:**
- **Automatic validation**: No need for manual `onChange` handlers
- **Direct binding**: Use `.binding` property for SwiftUI integration
- **Cleaner code**: Less boilerplate, more declarative

### Migration Checklist

1. **Replace @Observable with @GraphStored**: Convert stored properties to use `@GraphStored`
2. **Convert computed properties**: Replace computed properties with `@GraphComputed` 
3. **Remove manual updates**: Delete manual calculation methods
4. **Update observation logic**: Replace `withObservationTracking` with `withGraphTracking`
5. **Simplify SwiftUI bindings**: Use `.binding` property instead of manual state management
6. **Test reactivity**: Verify that all dependencies update correctly

### Common Pitfalls and Solutions

#### Pitfall: Forgetting to declare dependencies
```swift
// ❌ Wrong: Dependencies not declared
self.$computed = .init { _ in
  someGlobalValue + otherValue  // These won't be tracked
}

// ✅ Correct: Explicitly capture dependencies
self.$computed = .init { [$storedProperty] _ in
  $storedProperty.wrappedValue + otherValue
}
```

#### Pitfall: Circular dependencies
```swift
// ❌ Wrong: Circular dependency
self.$a = .init { [$b] _ in $b.wrappedValue + 1 }
self.$b = .init { [$a] _ in $a.wrappedValue + 1 }

// ✅ Correct: Break circular dependencies
self.$a = .init { [$source] _ in $source.wrappedValue + 1 }
self.$b = .init { [$a] _ in $a.wrappedValue + 1 }
```

### When to Consider Migration

Consider migrating from Observable to Swift State Graph when you need:

- Complex computed properties with multiple dependencies
- Automatic dependency tracking
- Cascading updates across multiple properties
- Better performance than manual state management
- More declarative state relationships

The migration process is typically straightforward and results in cleaner, more maintainable code with automatic reactivity.

## Data Normalization

Swift State Graph provides a normalization module to efficiently manage relational data. The `StateGraphNormalization` module helps you organize your data in a normalized structure, making it easier to handle complex relationships between entities.

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
2. **Efficient Updates**: Changes to an entity are automatically reflected in all dependent computed properties
3. **Relationship Management**: Easily handle one-to-many and many-to-many relationships
4. **Performance**: Optimized for fast lookups and updates through ID-based access
5. **Reactivity**: Combined with automatic dependency tracking for seamless UI updates

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

## Troubleshooting

### Common Issues

#### "Cannot find 'GraphStored' in scope"
Make sure you've imported the StateGraph module:
```swift
import StateGraph
```

#### Circular dependency errors
Swift State Graph detects circular dependencies. Restructure your computed properties to avoid cycles:
```swift
// ❌ Wrong: Circular dependency
self.$a = .init { [$b] _ in $b.wrappedValue + 1 }
self.$b = .init { [$a] _ in $a.wrappedValue + 1 }

// ✅ Correct: Break circular dependencies
self.$a = .init { [$source] _ in $source.wrappedValue + 1 }
self.$b = .init { [$a] _ in $a.wrappedValue + 1 }
```

#### SwiftUI views not updating
Ensure your model conforms to `GraphObject` for iOS 17+ or use proper observation patterns:
```swift
// iOS 17+
final class MyModel: GraphObject {
  @GraphStored var value: Int = 0
}

// iOS 16 and below
final class MyModel: ObservableObject {
  @GraphStored var value: Int = 0
  // Manually trigger objectWillChange when needed
}
```

#### Performance issues with large graphs
- Use lazy evaluation by accessing computed properties only when needed
- Consider breaking large models into smaller, focused components
- Profile your app to identify bottlenecks in dependency chains

## FAQ

### Q: How does Swift State Graph differ from Combine?
A: While Combine focuses on event streams and publishers, Swift State Graph specializes in state management with automatic dependency tracking. It's more like a reactive property system than a stream processing framework.

### Q: Can I use Swift State Graph with existing Observable classes?
A: Yes! Swift State Graph is designed to work alongside Observable. You can gradually migrate parts of your codebase while keeping existing Observable infrastructure.

### Q: Is Swift State Graph thread-safe?
A: Yes, all node operations are protected by NSRecursiveLock, making it safe to use from multiple threads.

### Q: Does it work with SwiftUI previews?
A: Absolutely. Swift State Graph works great in SwiftUI previews. Just create your models as you normally would in the preview provider.

### Q: What's the performance overhead?
A: Swift State Graph uses lazy evaluation and efficient dependency tracking. The overhead is minimal - computed values are only recalculated when their dependencies change AND when they're accessed.

### Q: Can I persist computed values?
A: Computed values are derived and cannot be persisted directly. However, you can persist their source stored values using backing storage like UserDefaults.

## Contributing

We welcome contributions to Swift State Graph! Here's how you can help:

1. **Report Issues**: Found a bug? [Open an issue](https://github.com/VergeGroup/swift-state-graph/issues)
2. **Suggest Features**: Have an idea? Start a discussion in issues
3. **Submit PRs**: Fork the repo, make your changes, and submit a pull request

### Development Setup

1. Clone the repository
2. Open `Package.swift` in Xcode
3. Run tests with `cmd+U`

### Code Style

- Follow Swift API Design Guidelines
- Ensure all public APIs have documentation comments
- Add tests for new features
- Keep PRs focused and atomic

### Running Tests

```bash
swift test
```

## License

Swift State Graph is released under the MIT license. See [LICENSE](LICENSE) for details.
