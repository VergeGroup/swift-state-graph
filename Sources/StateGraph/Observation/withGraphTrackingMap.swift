
/**
 Tracks graph nodes accessed during projection and calls onChange when filtered values change.

 This function enables reactive processing where you project (compute) a derived value from
 multiple nodes, and receive change notifications only for distinct values. It's similar to
 `withGraphTrackingGroup`, but adds value projection and filtering capabilities.

 ## Behavior
 - Must be called within a `withGraphTracking` scope
 - The `applier` closure is executed initially and re-executed whenever any accessed nodes change
 - Only nodes accessed during `applier` execution are tracked
 - The projected value is passed through a `DistinctFilter` (for `Equatable` types)
 - `onChange` is only called when the filtered value passes through (i.e., when it's different)

 ## Example: Computed Value Tracking
 ```swift
 let firstName = Stored(wrappedValue: "John")
 let lastName = Stored(wrappedValue: "Doe")
 let age = Stored(wrappedValue: 30)

 withGraphTracking {
   // Track full name changes, ignore age changes
   withGraphTrackingMap {
     "\(firstName.wrappedValue) \(lastName.wrappedValue)"
   } onChange: { fullName in
     print("Name changed to: \(fullName)")  // Only called when name actually changes
   }
 }

 firstName.wrappedValue = "Jane"  // ✓ Triggers: "Jane Doe"
 lastName.wrappedValue = "Smith"  // ✓ Triggers: "Jane Smith"
 age.wrappedValue = 31            // ✗ Doesn't trigger (age not accessed in applier)
 firstName.wrappedValue = "Jane"  // ✗ Doesn't trigger (same value, filtered by DistinctFilter)
 ```

 ## Use Cases
 - Derived state tracking: Monitor computed values from multiple nodes
 - UI state calculation: Compute view states from multiple data sources
 - Performance optimization: Only update when computed values actually change
 - Conditional dependencies: Dynamically track different nodes based on conditions

 - Parameter applier: Closure that computes the projected value by accessing nodes
 - Parameter onChange: Handler called with the filtered projected value
 - Parameter isolation: Actor isolation context for execution

 - Important: This variant automatically uses `DistinctFilter`, only triggering for distinct values
 */
public func withGraphTrackingMap<Projection>(
  _ applier: @escaping () -> Projection,
  onChange: @escaping (Projection) -> Void,
  isolation: isolated (any Actor)? = #isolation
) where Projection : Equatable {
  withGraphTrackingMap(applier, filter: DistinctFilter(), onChange: onChange)
}

/**
 Tracks graph nodes accessed during projection with custom filtering.

 This is the fully customizable variant of `withGraphTrackingMap` that allows you to specify
 a custom filter for controlling when `onChange` is triggered. This is useful when you need
 filtering logic beyond simple equality comparison.

 ## Custom Filter Example
 ```swift
 // Only notify on significant percentage changes
 struct SignificantChangeFilter: Filter {
   private var lastValue: Double?
   private let threshold: Double = 0.1  // 10% change

   mutating func send(value: Double) -> Double? {
     guard let last = lastValue else {
       lastValue = value
       return value
     }
     let change = abs((value - last) / last)
     if change >= threshold {
       lastValue = value
       return value
     }
     return nil
   }
 }

 let progress = Stored(wrappedValue: 0.0)

 withGraphTracking {
   withGraphTrackingMap(
     { progress.wrappedValue },
     filter: SignificantChangeFilter()
   ) { value in
     print("Significant progress change: \(value)")
   }
 }

 progress.wrappedValue = 0.05  // ✗ Not significant (< 10%)
 progress.wrappedValue = 0.15  // ✓ Significant (>= 10%)
 ```

 ## Advanced Use Case: Debouncing
 ```swift
 struct DebounceFilter<Value>: Filter {
   private var lastTime: Date?
   private let interval: TimeInterval

   mutating func send(value: Value) -> Value? {
     let now = Date()
     if let last = lastTime, now.timeIntervalSince(last) < interval {
       return nil  // Suppress rapid changes
     }
     lastTime = now
     return value
   }
 }
 ```

 - Parameter applier: Closure that computes the projected value by accessing nodes
 - Parameter filter: Custom filter to control when onChange is triggered
 - Parameter onChange: Handler called with the filtered projected value
 - Parameter isolation: Actor isolation context for execution
 */
public func withGraphTrackingMap<Projection>(
  _ applier: @escaping () -> Projection,
  filter: consuming some Filter<Projection>,
  onChange: @escaping (Projection) -> Void,
  isolation: isolated (any Actor)? = #isolation
) {

  guard ThreadLocal.subscriptions.value != nil else {
    assertionFailure("You must call withGraphTracking before calling this method.")
    return
  }

  var filter = filter

  let _handlerBox = OSAllocatedUnfairLock<ClosureBox?>(
    uncheckedState: .init(handler: {
      let result = applier()
      let filtered = filter.send(value: result)
      if let filtered {
        onChange(filtered)
      }
    })
  )

  withContinuousStateGraphTracking(
    apply: {
      _handlerBox.withLock { $0?.handler() }
    },
    didChange: {
      guard !_handlerBox.withLock({ $0 == nil }) else { return .stop }
      return .next
    },
    isolation: isolation
  )

  let cancellabe = AnyCancellable {
    _handlerBox.withLock { $0 = nil }
  }

  ThreadLocal.subscriptions.value!.append(cancellabe)

}

/**
 Tracks graph nodes accessed during dependency projection with automatic distinct filtering.

 This variant automatically uses `DistinctFilter` for Equatable projections, only triggering
 onChange when the projected value actually changes.

 ## Example
 ```swift
 class ViewModel {
   let node = Stored(wrappedValue: 42)
 }

 let viewModel = ViewModel()

 withGraphTracking {
   withGraphTrackingMap(
     from: viewModel,
     map: { vm in vm.node.wrappedValue }
   ) { value in
     print("Value changed: \(value)")
   }
 }
 ```

 - Parameter from: The dependency object to observe (held weakly)
 - Parameter map: Closure that projects a value from the dependency
 - Parameter onChange: Handler called when the projected value changes
 - Parameter isolation: Actor isolation context for execution

 - Note: Tracking automatically stops when the dependency is deallocated
 */
public func withGraphTrackingMap<Dependency: AnyObject, Projection>(
  from: Dependency,
  map: @escaping (Dependency) -> Projection,
  onChange: @escaping (Projection) -> Void,
  isolation: isolated (any Actor)? = #isolation
) where Projection: Equatable {
  withGraphTrackingMap(
    from: from,
    map: map,
    filter: DistinctFilter(),
    onChange: onChange,
    isolation: isolation
  )
}

/**
 Tracks graph nodes accessed during dependency projection with custom filtering.

 This function enables reactive processing where you project (compute) a derived value from
 nodes accessed through a dependency object. The dependency is held weakly, and tracking
 automatically stops when the dependency is deallocated.

 ## Behavior
 - Must be called within a `withGraphTracking` scope
 - The `map` closure is only executed when the dependency exists
 - Only nodes accessed during `map` execution are tracked
 - Tracking stops automatically when the dependency is deallocated
 - The projected value is passed through the provided filter
 - `onChange` is only called when the filtered value passes through

 ## Example with Custom Filter
 ```swift
 struct ThresholdFilter: Filter {
   private var lastValue: Int?
   private let threshold: Int = 5

   mutating func send(value: Int) -> Int? {
     guard let last = lastValue else {
       lastValue = value
       return value
     }
     if abs(value - last) >= threshold {
       lastValue = value
       return value
     }
     return nil
   }
 }

 class ViewModel {
   let counter = Stored(wrappedValue: 0)
 }

 let viewModel = ViewModel()

 withGraphTracking {
   withGraphTrackingMap(
     from: viewModel,
     map: { vm in vm.counter.wrappedValue },
     filter: ThresholdFilter()
   ) { value in
     print("Significant change: \(value)")
   }
 }
 ```

 - Parameter from: The dependency object to observe (held weakly)
 - Parameter map: Closure that projects a value from the dependency
 - Parameter filter: Custom filter to control when onChange is triggered
 - Parameter onChange: Handler called with the filtered projected value
 - Parameter isolation: Actor isolation context for execution

 - Note: Tracking automatically stops when the dependency is deallocated
 */
public func withGraphTrackingMap<Dependency: AnyObject, Projection>(
  from: Dependency,
  map: @escaping (Dependency) -> Projection,
  filter: consuming some Filter<Projection>,
  onChange: @escaping (Projection) -> Void,
  isolation: isolated (any Actor)? = #isolation
) {

  guard ThreadLocal.subscriptions.value != nil else {
    assertionFailure("You must call withGraphTracking before calling this method.")
    return
  }

  weak var weakDependency = from

  var filter = filter

  let _handlerBox = OSAllocatedUnfairLock<ClosureBox?>(
    uncheckedState: .init(handler: {
      guard let dependency = weakDependency else {
        return
      }
      let result = map(dependency)
      let filtered = filter.send(value: result)
      if let filtered {
        onChange(filtered)
      }
    })
  )

  withContinuousStateGraphTracking(
    apply: {
      guard weakDependency != nil else {
        _handlerBox.withLock { $0 = nil }
        return
      }
      _handlerBox.withLock { $0?.handler() }
    },
    didChange: {
      guard !_handlerBox.withLock({ $0 == nil }) else { return .stop }
      guard weakDependency != nil else { return .stop }
      return .next
    },
    isolation: isolation
  )

  let cancellable = AnyCancellable {
    _handlerBox.withLock { $0 = nil }
  }

  ThreadLocal.subscriptions.value!.append(cancellable)
}

private struct ClosureBox {
  let handler: () -> Void

  init(handler: @escaping () -> Void) {
    self.handler = handler
  }
}
