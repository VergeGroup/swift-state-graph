# Migration from Observable

Complete guide for migrating from Swift's `@Observable` to Swift State Graph.

## Overview

If you're currently using Swift's `@Observable` protocol, migrating to Swift State Graph can provide enhanced reactivity and automatic dependency tracking. This guide provides step-by-step instructions and practical examples to help you transition your existing code.

## Why Migrate?

Swift State Graph offers several advantages over the standard `@Observable` approach:

- **Automatic Dependency Tracking**: No need to manually track relationships between properties
- **Computed Properties**: Define derived state that updates automatically  
- **Performance Optimization**: Only recalculates what's necessary
- **Declarative Code**: Express what values depend on, not how to update them
- **Reduced Boilerplate**: Less manual state synchronization code

## Basic Observable Class Migration

### Before: Using @Observable

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

// Usage requires manual validation calls
let viewModel = UserViewModel()
viewModel.name = "John"
viewModel.updateValidation() // Manual call required
```

### After: Using Swift State Graph

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

// Usage is automatic
let viewModel = UserViewModel()
viewModel.name = "John" 
// isValid automatically updates - no manual calls needed!
```

### Benefits of the Migration

- **Automatic computation**: `isValid` updates automatically when `name` or `email` changes
- **No manual validation calls**: No need to remember to call `updateValidation()`
- **Dependency tracking**: The framework automatically knows when to recalculate
- **Type safety**: Compile-time guarantees about dependencies

## ObservationTracking Migration

### Before: Using withObservationTracking

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
    nameLabel.text = viewModel.name
    emailLabel.text = viewModel.email
    submitButton.isEnabled = viewModel.isValid
  }
  
  deinit {
    observationTask?.cancel()
  }
}
```

### After: Using withGraphTracking

```swift
import StateGraph

final class ViewController {
  private let viewModel = UserViewModel()
  private var subscription: AnyCancellable?
  
  func setupObservation() {
    subscription = withGraphTracking {
      viewModel.$name.onChange { [weak self] name in
        self?.nameLabel.text = name
      }
      
      viewModel.$email.onChange { [weak self] email in
        self?.emailLabel.text = email
      }
      
      viewModel.$isValid.onChange { [weak self] isValid in
        self?.submitButton.isEnabled = isValid
      }
    }
  }
  
  // No explicit cleanup needed - subscription handles it
}
```

### Benefits of the Migration

- **Granular callbacks**: Separate callbacks for each property change
- **Simpler lifecycle**: No need for Task management
- **Automatic cleanup**: Subscription automatically manages memory
- **Better performance**: Only specific properties trigger their callbacks

## Complex Dependencies Migration

### Before: Manual Dependency Management

```swift
@Observable
final class ShoppingCartViewModel {
  var items: [CartItem] = [] {
    didSet { recalculateAll() }
  }
  
  var taxRate: Double = 0.08 {
    didSet { recalculateAll() }
  }
  
  var subtotal: Double = 0.0
  var tax: Double = 0.0
  var total: Double = 0.0
  
  func recalculateAll() {
    subtotal = items.reduce(0) { $0 + ($1.price * Double($1.quantity)) }
    tax = subtotal * taxRate
    total = subtotal + tax
  }
  
  init() {
    recalculateAll()
  }
}
```

### After: Automatic Dependency Tracking

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

### Benefits of the Migration

- **Cascade updates**: Changes to `items` automatically update `subtotal` → `tax` → `total`
- **Efficient computation**: Only recalculates what's necessary
- **Clear dependencies**: Each computed property explicitly declares its dependencies
- **No manual coordination**: No need to remember which calculations to trigger

## SwiftUI Integration Migration

### Before: Observable in SwiftUI

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
  
  private func submitForm() {
    // Handle form submission
  }
}
```

### After: Swift State Graph in SwiftUI

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
  
  private func submitForm() {
    // Handle form submission
  }
}
```

### Benefits of the Migration

- **Automatic validation**: No need for manual `onChange` handlers
- **Direct binding**: Use `.binding` property for SwiftUI integration
- **Cleaner code**: Less boilerplate, more declarative
- **Better performance**: Fewer view updates

## Step-by-Step Migration Process

### Step 1: Replace @Observable with @GraphStored

```swift
// Before
@Observable
final class ViewModel {
  var count: Int = 0
}

// After
final class ViewModel {
  @GraphStored
  var count: Int = 0
}
```

### Step 2: Convert Computed Properties

```swift
// Before
@Observable
final class ViewModel {
  var count: Int = 0
  
  var isEven: Bool {
    count % 2 == 0
  }
}

// After
final class ViewModel {
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
```

### Step 3: Remove Manual Update Methods

```swift
// Before
func updateCalculations() {
  // Manual calculation code
}

// After
// Delete this method - calculations are automatic
```

### Step 4: Update Observation Logic

```swift
// Before
withObservationTracking { ... } onChange: { ... }

// After  
withGraphTracking { 
  node.onChange { value in ... }
}
```

### Step 5: Update SwiftUI Bindings

```swift
// Before
TextField("Text", text: $viewModel.property)

// After
TextField("Text", text: viewModel.$property.binding)
```

## Migration Checklist

Use this checklist to ensure complete migration:

- [ ] **Replace @Observable**: Convert classes to use `@GraphStored` properties
- [ ] **Convert computed properties**: Replace computed properties with `@GraphComputed`
- [ ] **Remove manual updates**: Delete manual calculation and update methods
- [ ] **Update observation logic**: Replace `withObservationTracking` with `withGraphTracking`
- [ ] **Simplify SwiftUI bindings**: Use `.binding` property for form controls
- [ ] **Test reactivity**: Verify that all dependencies update correctly
- [ ] **Remove didSet/willSet**: Replace property observers with computed dependencies
- [ ] **Update tests**: Modify tests to work with new reactive behavior

## Common Migration Pitfalls

### Pitfall 1: Forgetting to Declare Dependencies

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

### Pitfall 2: Circular Dependencies

```swift
// ❌ Wrong: Circular dependency
self.$a = .init { [$b] _ in $b.wrappedValue + 1 }
self.$b = .init { [$a] _ in $a.wrappedValue + 1 }

// ✅ Correct: Break circular dependencies
self.$a = .init { [$source] _ in $source.wrappedValue + 1 }
self.$b = .init { [$a] _ in $a.wrappedValue + 1 }
```

### Pitfall 3: Not Removing Manual Updates

```swift
// ❌ Wrong: Still calling manual updates
viewModel.count += 1
viewModel.updateCalculations() // Remove this

// ✅ Correct: Let automatic updates handle it
viewModel.count += 1
// Computed properties update automatically
```

## Performance Considerations

### Before Migration: All Properties Update

```swift
@Observable
class ViewModel {
  var a: Int = 0 { didSet { updateAll() } }
  var b: Int = 0 { didSet { updateAll() } }
  var c: Int = 0 { didSet { updateAll() } }
  
  func updateAll() {
    // All calculations run even if only one property changed
  }
}
```

### After Migration: Selective Updates

```swift
class ViewModel {
  @GraphStored var a: Int = 0
  @GraphStored var b: Int = 0
  @GraphStored var c: Int = 0
  
  @GraphComputed var sumAB: Int
  @GraphComputed var sumBC: Int
  
  init() {
    self.$sumAB = .init { [$a, $b] _ in $a.wrappedValue + $b.wrappedValue }
    self.$sumBC = .init { [$b, $c] _ in $b.wrappedValue + $c.wrappedValue }
  }
  
  // Only necessary computations run when properties change
}
```

## When to Consider Migration

Consider migrating from Observable to Swift State Graph when you have:

- **Complex computed properties** with multiple dependencies
- **Need for automatic dependency tracking**
- **Cascading updates** across multiple properties
- **Performance concerns** with manual state management
- **Desire for more declarative** reactive programming

## Gradual Migration Strategy

You don't need to migrate everything at once:

1. **Start with new features**: Use Swift State Graph for new view models
2. **Migrate isolated components**: Begin with self-contained view models
3. **Replace manual calculations**: Focus on areas with complex computed state
4. **Update UI integration**: Migrate SwiftUI integration last

The migration process is typically straightforward and results in cleaner, more maintainable code with automatic reactivity. 