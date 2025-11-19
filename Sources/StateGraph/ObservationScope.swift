import SwiftUI

/**
 A wrapper view that creates an observation boundary in SwiftUI's view hierarchy.

 ## Purpose

 `ObservationScope` serves two main purposes:

 1. **Activates observation tracking in UIHostingController**
 2. **Isolates view updates to prevent unnecessary parent re-renders**

 ## Problem: UIHostingController and Observation

 SwiftUI's observation system requires that property access occurs during `View.body` evaluation.
 However, `UIHostingController` takes a view instance as a parameter, not a closure.
 When you pass a view that accesses Observable models, the observation framework cannot detect the access.

 ```swift
 // ❌ Observable access happens outside body evaluation
 let model: Model
 UIHostingController(rootView: Text(model.count))
 ```

 ## Solution: Defer Observable Access

 By wrapping content in `ObservationScope`, you defer the observable access until the view's body is evaluated:

 ```swift
 // ✅ Observable access happens during body evaluation
 let model: Model
 UIHostingController(rootView: ObservationScope {
   Text(model.count)
 })
 ```

 ## Problem: Unnecessary Parent Re-renders

 When a child view accesses observable state directly, SwiftUI may re-render the parent view unnecessarily:

 ```swift
 // ❌ Both Parent and Child re-render when stored changes
 struct Parent: View {
   let stored: Stored<Int>

   var body: some View {
     VStack {
       Text("Parent")
       Child(value: stored.wrappedValue) // Access here causes Parent to re-render
     }
   }
 }
 ```

 ## Solution: Isolate Observable Access

 Wrap the child in `ObservationScope` to create an observation boundary:

 ```swift
 // ✅ Only Child re-renders when stored changes
 struct Parent: View {
   let stored: Stored<Int>

   var body: some View {
     VStack {
       Text("Parent")
       ObservationScope {
         Child(value: stored.wrappedValue) // Access deferred to Child's body
       }
     }
   }
 }
 ```

 ## How It Works

 `ObservationScope` works by deferring content creation to its own `body` evaluation.
 This creates a new observation tracking context, isolating observable accesses to only affect
 the views inside the scope.

 ## When to Use

 - When using `UIHostingController` with Observable models
 - When you want to prevent parent views from re-rendering due to child observable accesses
 - When optimizing performance by minimizing view update scope

 ## Performance Impact

 By isolating observable accesses, `ObservationScope` reduces unnecessary view updates,
 improving performance in complex view hierarchies.
 */
public struct ObservationScope<Content: View>: View {
  
  private let content: () -> Content
  
  public init(@ViewBuilder content: @escaping () -> Content) {
    self.content = content
  }
  
  public var body: some View {
    content()
  }
  
}

/**
 $s10StateGraph0027ObservationScopeswift_ovFAhfMX36_0_016_5BD379E435491D9E15F498990F6E59B91Ll7PreviewfMf_15PreviewRegistryfMu_.Parent: @self changed.
 $s10StateGraph0027ObservationScopeswift_ovFAhfMX36_0_016_5BD379E435491D9E15F498990F6E59B91Ll7PreviewfMf_15PreviewRegistryfMu_.Child: @self changed.
 // after click "up"
 $s10StateGraph0027ObservationScopeswift_ovFAhfMX36_0_016_5BD379E435491D9E15F498990F6E59B91Ll7PreviewfMf_15PreviewRegistryfMu_.Child: @self changed.
 $s10StateGraph0027ObservationScopeswift_ovFAhfMX36_0_016_5BD379E435491D9E15F498990F6E59B91Ll7PreviewfMf_15PreviewRegistryfMu_.Child: @self changed.
 */
#Preview {
  
  struct Parent: View {
    
    let stored: Stored<Int>
    
    var body: some View {
      let _ = Self._printChanges()
      VStack {
        Text("Parent") 
        Button("Up") {
          stored.wrappedValue += 1
        }
        ObservationScope {
          Child(value: stored.wrappedValue)
        }
      }
    }
  }
  
  struct Child: View {
    
    let value: Int
    
    var body: some View {
      let _ = Self._printChanges()
      Text("\(value)")
    }
    
  }
  
  return Parent(stored: .init(wrappedValue: 0))
  
}
