#if canImport(SwiftUI)

import SwiftUI

// MARK: - GraphObject Protocol

/// A marker protocol that enables objects to be propagated through SwiftUI's Environment system.
/// This protocol itself has no functional meaning and serves only as a marker to indicate
/// compatibility with SwiftUI's @Environment property wrapper.
///
/// # How to use:
/// ```swift
/// class MyModel: GraphObject {
///   @GraphStored var count: Int = 0
/// }
///
/// struct ContentView: View {
///   let model = MyModel()
///   
///   var body: some View {
///     ChildView()
///       .environment(model)
///   }
/// }
///
/// struct ChildView: View {
///   @Environment(MyModel.self) var model
///   
///   var body: some View {
///     Text("\(model.count)")
///   }
/// }
/// ```
@available(iOS 17.0, *)
public protocol GraphObject: Observable {}

extension _Stored {
  
  /**
    Creates a SwiftUI binding from the stored property.
   */
  public var binding: Binding<S.Value> {
    .init(
      get: { self.wrappedValue },
      set: { self.wrappedValue = $0 }
    )
  }
  
}

#if false
extension SwiftUI.View {
  
  public typealias Computed = SwiftUI_Computed
  public typealias Stored = SwiftUI_Stored
}

@propertyWrapper
public struct SwiftUI_Computed<Value>: DynamicProperty {
  
  public var wrappedValue: Value {
    node.wrappedValue.wrappedValue
  }
  
  public var projectedValue: SwiftUI_Computed<Value> {
    return .init(node: node.wrappedValue)
  }
  
  private let node: ObjectEdge<Computed<Value>>
  
  public init(
    _ file: StaticString = #file,
    _ line: UInt = #line,
    _ column: UInt = #column,
    compute: @escaping @Sendable (inout Computed<Value>.Context) -> Value
  ) {
    self.node = .init(
      wrappedValue: .init(
        file,
        line,
        column,
        rule: compute
      ))
  }
  
  public init(
    node: Computed<Value>
  ) {
    self.node = .init(wrappedValue: node)
  }
  
}

@propertyWrapper
public struct SwiftUI_Stored<Value>: DynamicProperty {
  
  public var wrappedValue: Value {
    get { node.wrappedValue.wrappedValue }
    nonmutating set { node.wrappedValue.wrappedValue = newValue }
  }
  
  public var projectedValue: SwiftUI_Stored<Value> {
    .init(node: node.wrappedValue)
  }
  
  private let node: ObjectEdge<Stored<Value>>
  
  public init(
    _ file: StaticString = #file,
    _ line: UInt = #line,
    _ column: UInt = #column,
    wrappedValue initialValue: Value
  ) {
    self.node = .init(wrappedValue: .init(wrappedValue: initialValue))
  }
  
  public init(
    _ file: StaticString = #file,
    _ line: UInt = #line,
    _ column: UInt = #column,
    node: Stored<Value>
  ) {
    self.node = .init(wrappedValue: node)
  }
  
}

// TODO: replace with original
@propertyWrapper
private struct ObjectEdge<O>: DynamicProperty {
  
  @State private var box: Box<O> = .init()
  
  var wrappedValue: O {
    if let value = box.value {
      return value
    } else {
      box.value = factory()
      return box.value!
    }
  }
  
  private let factory: () -> O
  
  init(wrappedValue factory: @escaping @autoclosure () -> O) {
    self.factory = factory
  }
  
  private final class Box<Value> {
    var value: Value?
  }
  
}

#endif

@available(iOS 17, *)
#Preview {
  
  class Model: GraphObject {
    
    @GraphStored var count: Int = 0
        
    init() {
      
    }
  }
  
  struct ChildView: View {
    
    @Environment(Model.self) var model
    
    var body: some View {
      let _ = Self._printChanges()
      Text("\(model.count)")
    }
  }
  
  struct ParentView: View {
    
    @State var model: Model = .init()
    
    var body: some View {  
      VStack {
        ChildView()
          .environment(model)
        
        Button("Increment") {
          model.count += 1
        }
      }
    }
    
  }
  
  return ParentView()
  
}

#endif