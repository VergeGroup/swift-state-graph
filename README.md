# Swift State Graph

A graph-based reactive state management library for Swift.

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/vergegroup/swift-state-graph)
![Swift 6.0+](https://img.shields.io/badge/Swift-6.0+-orange.svg)
![iOS 17+](https://img.shields.io/badge/iOS-17+-blue.svg)

## Quick Start

```swift
import StateGraph

final class Counter {
  @GraphStored var count: Int = 0
  @GraphComputed var isEven: Bool

  init() {
    $isEven = .init { [$count] _ in
      $count.wrappedValue % 2 == 0
    }
  }
}

// Usage
let counter = Counter()
counter.count = 5
print(counter.isEven) // false - automatically computed
```

## Why Swift State Graph?

### Automatic Dependency Tracking

Computed properties automatically track their dependencies and update when source values change:

```swift
@GraphStored var firstName: String = "John"
@GraphStored var lastName: String = "Doe"
@GraphComputed var fullName: String

init() {
  $fullName = .init { [$firstName, $lastName] _ in
    "\($firstName.wrappedValue) \($lastName.wrappedValue)"
  }
}
// Change firstName → fullName updates automatically
```

### Works with SwiftUI and UIKit

Native integration with SwiftUI's reactive system and UIKit through tracking APIs:

```swift
// SwiftUI - just use the properties
struct CounterView: View {
  let counter: Counter
  var body: some View {
    Text("\(counter.count)")
    Button("Up") { counter.count += 1 }
  }
}

// UIKit - use withGraphTracking
subscription = withGraphTracking {
  withGraphTrackingGroup {
    print(counter.count)    
  }
}
```

### Drop-in Observable Enhancement

Migrate from `@Observable` and gain automatic computed property updates:

```swift
// Before: Manual validation updates
@Observable class UserViewModel {
  var name = ""
  var isValid = false
  func validate() { isValid = !name.isEmpty }
}

// After: Automatic reactivity
final class UserViewModel {
  @GraphStored var name = ""
  @GraphComputed var isValid: Bool
  init() {
    $isValid = .init { [$name] _ in !$name.wrappedValue.isEmpty }
  }
}
```

### Persistent Storage Built-in

Back your state with UserDefaults seamlessly:

```swift
@GraphStored(backed: .userDefaults(key: "theme"))
var theme: String = "light"
```

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
  .package(url: "https://github.com/VergeGroup/swift-state-graph.git", from: "1.0.0")
]
```

```swift
.target(
  name: "YourTarget",
  dependencies: ["StateGraph"]
)
```

## Core Concepts

### Stored Nodes (`@GraphStored`)

Mutable containers that hold values and notify dependents when changed:

```swift
@GraphStored var count: Int = 0
count = 10  // Dependents are notified
```

### Computed Nodes (`@GraphComputed`)

Read-only values derived from other nodes. They:
- Automatically track dependencies
- Recalculate lazily when dependencies change
- Cache results until invalidated

```swift
@GraphComputed var doubled: Int
$doubled = .init { [$count] _ in $count.wrappedValue * 2 }
```

### Reactive Tracking

Observe changes without SwiftUI:

```swift
let subscription = withGraphTracking {
  withGraphTrackingGroup {
    print("Changed: \(model.count), \(model.name)")
  }
}
```

## SwiftUI Integration

### Basic Usage

Properties are automatically observed in SwiftUI views:

```swift
struct ItemListView: View {
  let store: ItemStore

  var body: some View {
    List(store.items) { item in
      Text(item.name)
    }
    TextField("New Item", text: store.$newItemName.binding)
  }
}
```

### Environment Integration

Use `GraphObject` protocol for environment propagation:

```swift
final class AppState: GraphObject {
  @GraphStored var user: User?
  @GraphComputed var isLoggedIn: Bool

  init() {
    $isLoggedIn = .init { [$user] _ in $user.wrappedValue != nil }
  }
}

// Inject
ContentView().environment(appState)

// Access
@Environment(AppState.self) private var appState
```

## UIKit Integration

Use `withGraphTracking` to observe state changes:

```swift
class ViewController: UIViewController {
  private let viewModel = ViewModel()
  private var subscription: AnyCancellable?

  override func viewDidLoad() {
    super.viewDidLoad()

    subscription = withGraphTracking {
      withGraphTrackingMap {
        viewModel.items
      } onChange: { [weak self] items in
        self?.tableView.reloadData()
      }
    }
  }
}
```

## Documentation

For detailed guides, see the [Documentation](Sources/StateGraph/Documentation.docc/):

- [Core Concepts](Sources/StateGraph/Documentation.docc/Core-Concepts.md) - Stored, Computed, and dependency tracking
- [SwiftUI Integration](Sources/StateGraph/Documentation.docc/SwiftUI-Integration.md) - Bindings, GraphObject, Environment
- [UIKit Integration](Sources/StateGraph/Documentation.docc/UIKit-Integration.md) - withGraphTracking patterns
- [Backing Storage](Sources/StateGraph/Documentation.docc/Backing-Storage.md) - UserDefaults persistence
- [Data Normalization](Sources/StateGraph/Documentation.docc/Data-Normalization.md) - EntityStore for relational data
- [Migration from Observable](Sources/StateGraph/Documentation.docc/Migration-from-Observable.md) - Step-by-step guide

## Advanced Topics

### Nested Tracking

Groups and Maps can be nested. When a parent re-executes, nested children are automatically cancelled and recreated:

```swift
withGraphTrackingGroup {
  if viewModel.featureEnabled {
    withGraphTrackingGroup {
      // Only tracked when featureEnabled is true
      print("Feature value: \(viewModel.featureValue)")
    }
  }
}
```

### State Sharing

Share state between objects by assigning `@GraphStored` references:

```swift
final class ViewModel {
  @GraphStored var items: [Item]

  init(service: DataService) {
    $items = service.$items  // Shares the same node
  }
}
```

## Requirements

- Swift 6.0+
- iOS 17+ / macOS 14+

## License

MIT License
