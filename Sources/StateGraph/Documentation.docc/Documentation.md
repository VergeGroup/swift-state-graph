# ``StateGraph``

State management framework for reactive programming with automatic dependency tracking.

## Overview

Swift State Graph is a framework designed for managing application state using a graph-based approach. It provides tools for creating and managing stored and computed properties, enabling efficient and reactive data flow within an application.

Unlike traditional state management approaches, Swift State Graph automatically tracks dependencies between your data and updates dependent values reactively. This eliminates manual state synchronization and reduces bugs while improving performance through intelligent caching and lazy evaluation.

### Key Features

- **Automatic Dependency Tracking**: The framework automatically detects when one value depends on another
- **Reactive Updates**: Changes propagate automatically through the dependency graph
- **Computed Properties**: Define derived values that update automatically when their dependencies change  
- **SwiftUI Integration**: Seamless integration with SwiftUI's binding system
- **Memory Efficient**: Lazy evaluation and intelligent caching optimize performance
- **Type Safe**: Full Swift type safety with compile-time dependency verification

### Quick Example

```swift
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

  func increment() {
    count += 1 // isEven automatically updates
  }
}
```

## Topics

### Getting Started

- <doc:Quick-Start-Guide>
- <doc:Installation>
- <doc:Core-Concepts>

### Core Components

- ``Stored``
- ``Computed``
- ``Node``
- ``GraphStored``
- ``GraphComputed``

### Building Reactive Models

- <doc:Describing-Models>
- <doc:Dependency-Tracking>
- <doc:State-Sharing>

### Framework Integration

- <doc:SwiftUI-Integration>
- <doc:UIKit-Integration>
- <doc:Combine-Integration>

### Advanced Usage

- <doc:Advanced-Patterns>
- <doc:Performance-Optimization>
- <doc:Debugging-State-Graph>

### Migration and Adoption

- <doc:Migration-from-Observable>
- <doc:Best-Practices>

### Data Normalization

- ``EntityStore``
- ``TypedIdentifiable``
- <doc:Data-Normalization>

### Observation and Tracking

- ``withGraphTracking(_:)``
- ``Node/onChange(_:)``
- <doc:Observation-Patterns>

### Utilities

- ``Weak``
- ``Unowned``
- ``NodeStore``
