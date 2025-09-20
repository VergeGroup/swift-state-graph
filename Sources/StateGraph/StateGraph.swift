import Foundation.NSLock

#if canImport(Observation)
  import Observation
#endif

/**
 based on
 https://talk.objc.io/episodes/S01E429-attribute-graph-part-1
 */

/// A node that functions as an endpoint in a Directed Acyclic Graph (DAG).
///
/// `Stored` can have its value set directly from the outside, and changes to its value
/// automatically propagate to dependent nodes. This node doesn't perform any computations
/// and serves purely as a value container with in-memory storage.
///
/// - When value changes: Changes propagate to all dependent nodes, triggering recalculations
/// - When value is accessed: Dependencies are recorded, automatically building the graph structure
public typealias Stored<Value> = _Stored<Value, InMemoryStorage<Value>>

extension _Stored where S == InMemoryStorage<Value> {
  /// 便利な初期化メソッド（wrappedValue指定）
  public convenience init(
    _ file: StaticString = #fileID,
    _ line: UInt = #line,
    _ column: UInt = #column,
    name: StaticString? = nil,
    wrappedValue: Value
  ) {
    let storage = InMemoryStorage(initialValue: wrappedValue)
    self.init(
      file,
      line,
      column,
      name: name,
      storage: storage
    )
  }
}

public protocol ComputedDescriptor<Value>: Sendable {
  
  associatedtype Value
  
  func compute(context: inout Computed<Value>.Context) -> Value
  
  func isEqual(lhs: Value, rhs: Value) -> Bool
}

extension ComputedDescriptor {
  
  @Sendable
  public static func any<Value>(
    _ compute: @Sendable @escaping (inout Computed<Value>.Context) -> Value
  ) -> Self where Self == AnyComputedDescriptor<Value> {
    AnyComputedDescriptor(compute: compute, isEqual: { _, _ in false })
  }
  
  @Sendable
  public static func any<Value>(
    _ compute: @Sendable @escaping (
      inout Computed<Value>.Context
    ) -> Value
  ) -> Self where Self == AnyComputedDescriptor<Value>, Value: Equatable {
    AnyComputedDescriptor(compute: compute)
  }
  
}

public struct AnyComputedDescriptor<Value>: ComputedDescriptor {

  private let computeClosure: @Sendable (inout Computed<Value>.Context) -> Value
  private let isEqualClosure: @Sendable (Value, Value) -> Bool
  
  public init(
    compute: @escaping @Sendable (inout Computed<Value>.Context) -> Value,
    isEqual: @escaping @Sendable (Value, Value) -> Bool
  ) {
    self.computeClosure = compute  
    self.isEqualClosure = isEqual
  }
  
  public init(
    compute: @escaping @Sendable (inout Computed<Value>.Context) -> Value
  ) where Value : Equatable {
    self.computeClosure = compute  
    self.isEqualClosure = { $0 == $1 }
  }
      
  public func compute(context: inout Computed<Value>.Context) -> Value {
    computeClosure(&context)
  }
  
  public func isEqual(lhs: Value, rhs: Value) -> Bool {
    isEqualClosure(lhs, rhs)
  }
      
}

public protocol ComputedEnvironmentKey {
  associatedtype Value
}

public struct ComputedEnvironmentValues {
  
  struct AnyMetatypeWrapper: Hashable {
    let metatype: Any.Type
    
    static func ==(lhs: Self, rhs: Self) -> Bool {
      lhs.metatype == rhs.metatype
    }
    
    func hash(into hasher: inout Hasher) {
      hasher.combine(ObjectIdentifier(metatype))
    }    
  }
  
  private var values: [AnyMetatypeWrapper: Any] = [:]
  
  public subscript<K: ComputedEnvironmentKey>(key: K.Type) -> K.Value? {
    get {
      return values[.init(metatype: key)] as? K.Value
    }
    set {
      values[.init(metatype: key)] = newValue      
    }
  }
}

public enum StateGraphGlobal {
  
  public static let computedEnvironmentValues: OSAllocatedUnfairLock<ComputedEnvironmentValues> = .init(
    uncheckedState: .init()
  )
  
}
  
/// A node that computes its value based on other nodes in a Directed Acyclic Graph (DAG).
///
/// `Computed` derives its value from other nodes through a computation rule.
/// When any of its dependencies change, the node becomes dirty and will recalculate
/// its value on the next access. This node caches its computed value for performance.
///
/// - Value is lazily computed: Calculations only occur when the value is accessed
/// - Dependencies are tracked: The node automatically tracks which nodes it depends on
/// - Changes propagate: When this node's value changes, downstream nodes are notified
/// ```
public final class Computed<Value>: Node, Observable, CustomDebugStringConvertible {
    
  public struct Context {
    
    @dynamicMemberLookup
    public struct Environment {
      
      public subscript<T: ComputedEnvironmentKey>(
        dynamicMember keyPath: KeyPath<ComputedEnvironmentValues, T>
      ) -> T {
        StateGraphGlobal.computedEnvironmentValues.withLockUnchecked {
          $0[keyPath: keyPath]
        }
      }

    }
    
    /**
     Use this method to perform actions without tracking dependencies.
     
     This case does not track `isRemoved` property.
     ```swift
     Computed { context in 
       node.filter { 
         context.withoutTracking {
           $0.isRemoved == true
         }
       }
     }
     ```
     */
    public func withoutTracking<R>(_ block: () throws -> R) rethrows -> R{
      try TaskLocals.$currentNode.withValue(nil) {
        try block()
      }
    }
    
    public let environment: Environment
    
  }
    
  public let lock: NodeLock

  nonisolated(unsafe)
    private var _cachedValue: Value?
  
  #if canImport(Observation)
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    private var observationRegistrar: ObservationRegistrar {
      return .shared
    }
  #endif

  public var potentiallyDirty: Bool {
    get {
      lock.lock()
      defer {
        lock.unlock()
      }
      return _potentiallyDirty
    }
    set {
      lock.lock()
          
      let oldValue = _potentiallyDirty
      _potentiallyDirty = newValue
      
      guard _potentiallyDirty, _potentiallyDirty != oldValue else {
        lock.unlock()
        return 
      }
            
      let _outgoingEdges = outgoingEdges

      lock.unlock()

#if canImport(Observation)
      if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
        observationRegistrar.willSet(PointerKeyPathRoot.shared, keyPath: _keyPath(self))
      }
#endif

      for edge in _outgoingEdges {
        edge.to.potentiallyDirty = true
      }
            
    }
  }

  nonisolated(unsafe)
  private var _potentiallyDirty: Bool = false

  public let info: NodeInfo

  public var wrappedValue: Value {
    get {
      #if canImport(Observation)
        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
          observationRegistrar.access(PointerKeyPathRoot.shared, keyPath: _keyPath(self))   
        }
      #endif
      recomputeIfNeeded()
      
      lock.lock()
      defer { lock.unlock() }
      return _cachedValue!
    }
  }

  private let descriptor: any ComputedDescriptor<Value>

  nonisolated(unsafe)
  public var incomingEdges: ContiguousArray<Edge> = []
  
  nonisolated(unsafe)
  public var outgoingEdges: ContiguousArray<Edge> = []
  

  /// Initializes a computed node.
  ///
  /// This initializer uses a comparison function that always returns `false`.
  /// This means updates will always occur regardless of whether the value has changed.
  ///
  /// - Parameters:
  ///   - file: The file where the node is created (defaults to current file)
  ///   - line: The line number where the node is created (defaults to current line)
  ///   - column: The column number where the node is created (defaults to current column)
  ///   - name: The name of the node (defaults to nil)
  ///   - rule: The rule that computes the node's value
  public init(
    _ file: StaticString = #fileID,
    _ line: UInt = #line,
    _ column: UInt = #column,
    name: StaticString? = nil,
    descriptor: some ComputedDescriptor<Value>
  ) {
    self.info = .init(
      name: name,
      sourceLocation: .init(file: file, line: line, column: column)
    )
    self.descriptor = descriptor
    self.lock = .init()

#if DEBUG
    Task {
      await NodeStore.shared.register(node: self)
    }
#endif
  }
  
  /// Initializes a computed node.
  ///
  /// This initializer uses a comparison function that always returns `false`.
  /// This means updates will always occur regardless of whether the value has changed.
  ///
  /// - Parameters:
  ///   - file: The file where the node is created (defaults to current file)
  ///   - line: The line number where the node is created (defaults to current line)
  ///   - column: The column number where the node is created (defaults to current column)
  ///   - name: The name of the node (defaults to nil)
  ///   - rule: The rule that computes the node's value
  public init(
    _ file: StaticString = #fileID,
    _ line: UInt = #line,
    _ column: UInt = #column,
    name: StaticString? = nil,
    rule: @escaping @Sendable (inout Context) -> Value
  ) {
    self.info = .init(
      name: name,
      sourceLocation: .init(file: file, line: line, column: column)
    )
    self.descriptor = AnyComputedDescriptor(compute: rule, isEqual: { _, _ in false })      
    self.lock = .init()

#if DEBUG
    Task {
      await NodeStore.shared.register(node: self)
    }
#endif
  }

  /// Initializes a computed node.
  ///
  /// This initializer uses a comparison function that always returns `false`.
  /// This means updates will always occur regardless of whether the value has changed.
  ///
  /// - Parameters:
  ///   - file: The file where the node is created (defaults to current file)
  ///   - line: The line number where the node is created (defaults to current line)
  ///   - column: The column number where the node is created (defaults to current column)
  ///   - name: The name of the node (defaults to nil)
  ///   - rule: The rule that computes the node's value
  public init(
    _ file: StaticString = #fileID,
    _ line: UInt = #line,
    _ column: UInt = #column,
    name: StaticString? = nil,
    rule: @escaping @Sendable (inout Context) -> Value
  ) where Value: Equatable {
    self.info = .init(
      name: name,
      sourceLocation: .init(file: file, line: line, column: column)
    )
    self.descriptor = AnyComputedDescriptor(compute: rule, isEqual: { $0 == $1 })
    self.lock = .init()
   
#if DEBUG
    Task {
      await NodeStore.shared.register(node: self)
    }
#endif
  }
  
    deinit {
//      Log.generic.debug("Deinit Computed: \(self.info.name.map(String.init) ?? "noname")")
      for edge in incomingEdges {
        edge.from.outgoingEdges.removeAll(where: { $0 === edge })
      }
    }

  public func recomputeIfNeeded() {

    lock.lock()
    defer { lock.unlock() }

    // record dependency
    if let currentNode = TaskLocals.currentNode {
      let edge = Edge(from: self, to: currentNode)
      // TODO: consider removing duplicated edges
      outgoingEdges.append(edge)
      currentNode.incomingEdges.append(edge)
    }

    if !_potentiallyDirty && _cachedValue != nil { return }

    for edge in incomingEdges {
      edge.from.recomputeIfNeeded()
    }

    let hasPendingIncomingEdge = incomingEdges.contains(where: \.isPending)

    if hasPendingIncomingEdge || _cachedValue == nil {

      TaskLocals.$currentNode.withValue(self) { () -> Void in
        let previousValue = _cachedValue
        removeIncomingEdges()
        var context = Context(environment: .init())

        _cachedValue = descriptor.compute(context: &context)

        // propagate changes to dependent nodes
        do {

            if let previousValue = previousValue,
               descriptor.isEqual(lhs: previousValue, rhs: _cachedValue!) == false
            {
              for edge in outgoingEdges {
                edge.isPending = true
              }
            }

        }
      }

    }

    _potentiallyDirty = false

  }

  private func removeIncomingEdges() {
    for edge in incomingEdges {
      edge.from.lock.lock()
      edge.from.outgoingEdges.removeAll(where: { $0 === edge })
      edge.from.lock.unlock()
    }
    incomingEdges.removeAll()
  }
   
  public var debugDescription: String {
    "Computed<\(Value.self)>(name=\(info.name.map(String.init) ?? "noname"), value=\(String(describing: _cachedValue)))"
  }
  
}

extension Computed {
  
  /**
    Create a computed value node that depends on a stored node.
   */
  public convenience init(_ stored: Stored<Value>) {
    self.init(name: "embedded", rule: { _ in 
      stored.wrappedValue
    })
  }
  
  /**
    Create a computed value node that depends on a computed node.    
   */
  public convenience init(_ computed: Computed<Value>) {
    self.init(name: "embedded", rule: { _ in 
      computed.wrappedValue
    })
  }
  
  /**
    Create from a constant value.
   */
  public convenience init(constant: consuming sending Value) {    
    let sendable = UnsafeSendable(constant)
    self.init(
      name: "constant",
      rule: { _ in 
        sendable._value
      }
    )
  }
  
  /**
   Create from a constant value.
   */
  public convenience init(constant: Value) where Value : Sendable {
    self.init(
      name: "constant",
      rule: { _ in
        constant
      }
    )
  }
  
}

@DebugDescription
public final class Edge: CustomDebugStringConvertible {

  unowned let from: any TypeErasedNode
  unowned let to: any TypeErasedNode
  
  private let lock: OSAllocatedUnfairLock<Void> = .init()
  
  var isPending: Bool {
    _read {
      lock.lock()
      defer { lock.unlock() }
      yield _isPending
    }
    _modify {
      lock.lock()
      defer { lock.unlock() }
      yield &_isPending
    }
  }

  private var _isPending: Bool = false

  init(from: any TypeErasedNode, to: any TypeErasedNode) {
    self.from = from
    self.to = to
  }

  public var debugDescription: String {
    "\(from.debugDescription) -> \(to.debugDescription)"
  }

  deinit {
//    Log.generic.debug("Deinit Edge")
  }
  
}

public typealias NodeLock = NSRecursiveLock
