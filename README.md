# Swift State Graph

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/vergegroup/swift-state-graph)

## Introduction

Navigating the complexities of data and state in Swift applications can often feel like a maze, especially as your project grows. If you're seeking a more intuitive and robust way to approach **Swift state management**, you're in the right place. Traditional methods frequently lead to tangled dependencies, excessive boilerplate, and specific challenges when synchronizing **SwiftUI state** or managing **UIKit state**. This can make it difficult to **manage Swift app state** cohesively and effectively across your application.

Swift State Graph emerges as a powerful **Swift reactive library**, offering a refreshing graph-based approach to **reactive programming Swift**. It's engineered to untangle these complexities, providing a clear and declarative path to managing your application's data flow.

With Swift State Graph, you can:
*   Achieve crystal-clear, declarative state logic thanks to automatic **Swift dependency tracking**.
*   Effortlessly **manage Swift app state** and derive dynamic information with powerful **Swift computed properties**.
*   Streamline development across Apple platforms with unified strategies for both **SwiftUI state management** and **UIKit state management**.

Dive in to discover how Swift State Graph can transform your approach to state.

## 🚀 Quick Start

Here's a glimpse of how Swift State Graph simplifies state management:

```swift
import StateGraph

final class CounterModel {
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
}

struct SettingsView: View {
  let model: CounterModel
  
  var body: some View {
    // 👨🏻 Only view updates when `model.count` changed.
    Text("\(model.count)")
    Button("Up") {
      model.count += 1
    }
  }
}

```

### Universal Swift Application Support

Swift State Graph is designed to work seamlessly across all types of Swift applications, helping you **manage Swift app state** consistently:

- **SwiftUI Applications**: Native integration with SwiftUI's reactive system, enhancing your **SwiftUI state** handling, and offering excellent **Swift Observable compatibility**.
- **UIKit Applications**: Brings robust **reactive programming Swift** capabilities to simplify complex UI updates, data binding, and overall **UIKit state** management.
- **macOS Applications**: Perfect for both AppKit and SwiftUI-based macOS applications, providing a unified approach to state.

### SwiftUI Observable Compatibility

Swift State Graph provides excellent **Swift Observable compatibility**, enhancing Apple's native tools:

- **Seamless Integration**: Works alongside existing `@Observable` classes without conflicts
- **Enhanced Reactivity**: Adds powerful **Swift computed properties** and automatic **Swift dependency tracking** to Observable objects.
- **Migration Path**: Easy migration from `Observable` to Swift State Graph with minimal code changes.
- **Performance Benefits**: More efficient **Swift dependency tracking** compared to manual observation patterns.

The framework's reactive nature and automatic **Swift dependency tracking** make it particularly effective for applications demanding complex state relationships and real-time data synchronization. This contributes to a more **declarative Swift state** approach, beneficial regardless of the UI framework or platform in use.

## Table of Contents

- [Introduction](#introduction)
- [🚀 Quick Start](#-quick-start)
- [Core Concepts](#core-concepts)
- [Installation](#installation)
- [Backing Storage](#backing-storage)
- [Describing Models](#describing-models)
- [SwiftUI Integration](#swiftui-integration)
- [UIKit Integration](#uikit-integration)
- [Advanced Usage](#advanced-usage)
- [Comparing with Swift's Observable Protocol](#comparing-with-swifts-observable-protocol)
- [Migration from Observable](#migration-from-observable)
- [Data Normalization](#data-normalization)

## Core Concepts

At its heart, this **Swift reactive library** is built around two primary types of nodes, which promote a **declarative Swift state** approach:

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

**Swift computed properties** (or Computed nodes) derive their values from other nodes and automatically update when dependencies change:

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

### Automatic Swift Dependency Tracking

The power of Swift State Graph lies in its automatic **Swift dependency tracking**:

1. When a computed node accesses another node's value, a dependency is automatically recorded
2. When a node's value changes, all dependent nodes are marked as "potentially dirty"
3. When a potentially dirty node's value is accessed, it recalculates its value first

This creates a reactive system where changes propagate automatically through the dependency graph.

## Installation

To integrate this **Swift reactive library** into your project, use the Swift Package Manager.

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

## Backing Storage

Effective **Swift state management** often requires persistence. Swift State Graph provides flexible backing storage options for your stored properties, allowing you to persist data beyond in-memory storage.

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

Swift State Graph makes it easy to define reactive data models, helping you **manage Swift app state** effectively. It's particularly useful when dealing with complex object relationships, promoting a more **declarative Swift state** representation in your applications. Here's an example of a library management system:

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

Swift State Graph offers robust **SwiftUI state management** capabilities, integrating seamlessly with SwiftUI's reactive paradigm. This allows developers to manage **SwiftUI state** with more power and flexibility.

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

Swift State Graph provides seamless integration with SwiftUI's Environment system through the `GraphObject` protocol. This allows you to pass state objects through the SwiftUI view hierarchy, simplifying **SwiftUI state management** further, much like native Observable objects but with the added benefits of **Swift dependency tracking** and **Swift computed properties**.

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

For **UIKit state management**, Swift State Graph brings the power of **reactive programming Swift** to your UIKit applications. While it doesn't have direct UIKit-specific APIs, its reactive nature and tools like `withGraphTracking` make it easy to manage **UIKit state** and simplify complex UI updates.

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

The advanced features of Swift State Graph further enhance your ability to handle sophisticated **Swift state management** scenarios, leveraging the full potential of **reactive programming Swift**.

### Subscribing to Multiple Nodes with `withGraphTracking`

The `withGraphTracking` function allows you to create a subscription that observes multiple nodes at once, a core aspect of powerful **Swift state management**:

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

### Reactive Processing with `withGraphTrackingGroup`

The `withGraphTrackingGroup` function enables **Computed-like reactive processing** where code is executed immediately and re-executed whenever any accessed nodes change. Unlike Computed nodes which return values, this executes side effects and operations based on node values, dynamically tracking only the nodes that are actually accessed during execution.

```swift
// Example: Conditional data processing based on feature flags and user state

final class DataProcessingService {
  @GraphStored var rawData: [DataItem] = []
  @GraphStored var isProcessingEnabled: Bool = false
  @GraphStored var currentUser: User?
}

let service = DataProcessingService()

// Reactive processing that adapts to runtime conditions
let subscription = withGraphTracking {
  withGraphTrackingGroup {
    // Only process data when feature is enabled
    if service.isProcessingEnabled {
      let data = service.rawData
      print("Processing \(data.count) items...")
      
      // Only perform expensive analytics for premium users
      if service.currentUser?.isPremium == true {
        performAdvancedAnalytics(data)
      } else {
        performBasicAnalytics(data)
      }
    }
    
    // Always update UI regardless of processing state
    updateDataCountDisplay(service.rawData.count)
  }
}
```

**Key Features:**
- **Immediate Execution**: The handler runs synchronously on initial call and re-runs when dependencies change
- **Dynamic Dependency Tracking**: Only nodes accessed during execution are tracked - if a node is inside a conditional that evaluates to false, it won't be tracked until the condition becomes true
- **Conditional Processing**: Different code paths create different dependency graphs at runtime
- **Actor Isolation**: Preserves the actor context where tracking was initiated
- **Automatic Cleanup**: All subscriptions are managed automatically through the returned cancellable

**How It Works:**
1. Must be called within a `withGraphTracking` scope
2. The handler closure executes immediately
3. Any nodes accessed during execution are automatically tracked
4. When any tracked node changes, the entire handler re-executes
5. Dependencies can change dynamically based on runtime conditions

**Use Cases:**
- Feature flag-based conditional logic
- User permission-dependent operations  
- Dynamic UI updates based on complex state combinations
- Performance-sensitive reactive processing where you want to avoid tracking expensive computations when not needed

**Important Notes:**
- Always call within a `withGraphTracking` block (will assert in debug mode if not)
- The handler should be side-effect focused rather than returning values (use `Computed` for value derivation)
- Supports proper actor isolation for concurrent environments

## Comparing with Swift's Observable Protocol

Understanding **Swift Observable compatibility** is key when choosing a state management solution. The primary differentiator for Swift State Graph over Swift's standard `Observable` protocol is its sophisticated approach to **Swift computed properties** and automatic **Swift dependency tracking**.

While the standard `Observable` protocol in Swift provides a basic foundation for **reactive programming Swift** by observing changes to stored properties, Swift State Graph significantly enhances this.

It introduces graph-based **Swift computed properties** (Computed nodes) that automatically derive their values from other nodes. These nodes meticulously track dependencies and update reactively when any source nodes change, enabling more powerful, granular, and **declarative Swift state** relationships. This advanced **Swift state management** capability simplifies complex data flows.

**Example:**

```swift
let stored = Stored(wrappedValue: 10)

let computed = Computed { _ in stored.wrappedValue * 2 }

// computed.wrappedValue => 20

stored.wrappedValue = 20

// computed.wrappedValue => 40 (automatically updated)
```

With Swift State Graph, you can build complex, reactive data flows that are difficult to achieve with just the `Observable` protocol.

## Migration from Observable

If you're currently using Swift's `@Observable` protocol, migrating to Swift State Graph can significantly enhance your **Swift state management** capabilities, offering improved reactivity through automatic **Swift dependency tracking** and powerful **Swift computed properties**. This guide will help you transition your existing code to a more robust **reactive programming Swift** model.

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

Consider migrating from Observable to Swift State Graph when you need more advanced **Swift state management** features, such as:

- Complex **Swift computed properties** with multiple dependencies.
- Robust and automatic **Swift dependency tracking**.
- Cascading updates across multiple properties for a truly reactive system.
- Performance concerns with manual state management under `Observable`.
- A more **declarative Swift state** approach to **reactive programming Swift**.

The migration process is typically straightforward and results in cleaner, more maintainable code with automatic reactivity.

## Data Normalization

Effectively managing relational data is a common challenge in **Swift state management**. Swift State Graph provides a normalization module to efficiently **manage Swift app state** when dealing with structured, related data. The `StateGraphNormalization` module helps you organize your data in a normalized structure, making it easier to handle complex relationships between entities.

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

Using the normalization module provides several advantages for robust **Swift state management**:

1. **Single Source of Truth**: Entities are stored once, preventing duplication and inconsistencies, which is crucial to **manage Swift app state** reliably.
2. **Efficient Updates**: Changes to an entity are automatically reflected in all computed properties that depend on them.
3. **Relationship Management**: Easily handle one-to-many and many-to-many relationships with clear definitions.
4. **Performance**: Optimized for fast lookups and updates through ID-based access.
5. **Reactivity**: Combined with Swift State Graph's automatic **Swift dependency tracking** for seamless UI updates and reactive data flows.

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
