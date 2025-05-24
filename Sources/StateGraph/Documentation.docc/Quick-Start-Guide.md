# Quick Start Guide

Get started with Swift State Graph in minutes.

## Overview

This guide will walk you through the basics of Swift State Graph, from installation to creating your first reactive model. By the end, you'll understand how to use stored and computed properties to build reactive applications.

## Installation

Add Swift State Graph to your project using Swift Package Manager:

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

## Your First Reactive Model

Let's create a simple counter that automatically tracks whether the count is even or odd:

```swift
import StateGraph

final class CounterViewModel {
  @GraphStored
  var count: Int = 0

  @GraphComputed
  var isEven: Bool

  @GraphComputed
  var displayText: String

  init() {
    // Define how isEven is computed
    self.$isEven = .init { [$count] _ in
      $count.wrappedValue % 2 == 0
    }

    // Define how displayText is computed
    self.$displayText = .init { [$count, $isEven] _ in
      let number = $count.wrappedValue
      let parity = $isEven.wrappedValue ? "even" : "odd"
      return "Count: \(number) (\(parity))"
    }
  }

  func increment() {
    count += 1
    // isEven and displayText automatically update!
  }

  func decrement() {
    count -= 1
    // isEven and displayText automatically update!
  }
}
```

## Understanding the Magic

When you change `count`, here's what happens automatically:

1. **Dependency Detection**: Swift State Graph knows that `isEven` depends on `count`
2. **Cascade Updates**: When `count` changes, `isEven` is marked for recalculation
3. **Efficient Computation**: `displayText` depends on both `count` and `isEven`, so it updates too
4. **Lazy Evaluation**: Values are only recalculated when actually accessed

## Using with SwiftUI

Swift State Graph integrates seamlessly with SwiftUI:

```swift
import SwiftUI
import StateGraph

struct CounterView: View {
  @State private var viewModel = CounterViewModel()

  var body: some View {
    VStack(spacing: 20) {
      Text(viewModel.displayText)
        .font(.title)

      HStack {
        Button("−", action: viewModel.decrement)
        Button("+", action: viewModel.increment)
      }
      .buttonStyle(.borderedProminent)

      // Direct binding support
      Stepper("Count", value: viewModel.$count.binding, in: 0...100)
    }
    .padding()
  }
}
```

## Key Benefits You Just Experienced

- **No Manual Updates**: You never called `updateDisplayText()` - it just works
- **Type Safety**: Compile-time guarantees about your dependencies  
- **Performance**: Only recomputes what's necessary, when it's needed
- **Declarative**: Your computed properties clearly express what they depend on

## Next Steps

Now that you've seen the basics, explore:

- <doc:Core-Concepts> - Understand stored vs computed nodes in depth
- <doc:Describing-Models> - Build more complex reactive models
- <doc:SwiftUI-Integration> - Learn advanced SwiftUI patterns
- <doc:Migration-from-Observable> - Migrate from `@Observable` if you're already using it

## Common First Questions

### Q: How is this different from `@Observable`?
**A:** Swift State Graph adds computed properties with automatic dependency tracking. With `@Observable`, you'd need to manually call update methods.

### Q: What about performance?
**A:** Swift State Graph is designed for performance - it only recalculates what's needed, when it's needed, using intelligent caching.

### Q: Can I use this with UIKit?
**A:** Absolutely! Use `withGraphTracking` to observe changes. See <doc:UIKit-Integration> for details. 