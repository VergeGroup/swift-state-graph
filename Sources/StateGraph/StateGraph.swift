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
    group: String? = nil,
    name: String? = nil,
    wrappedValue: Value
  ) {
    let storage = InMemoryStorage(initialValue: wrappedValue)
    self.init(
      file,
      line,
      column,
      group: group,
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
      _observationRegistrar as! ObservationRegistrar
    }
    private let _observationRegistrar: (Any & Sendable)?
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
      let _trackingRegistrations = trackingRegistrations
      trackingRegistrations.removeAll()
      
      lock.unlock()
      
#if canImport(Observation)
      if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
        observationRegistrar.willSet(self, keyPath: \.self)
      }
#endif
      
      for edge in _outgoingEdges {
        edge.to.potentiallyDirty = true
      }
      
      for registration in _trackingRegistrations {
        registration.perform()
      }
            
    }
  }

  nonisolated(unsafe)
  private var _potentiallyDirty: Bool = false

  public let info: NodeInfo

  public var wrappedValue: Value {
    _read {
      #if canImport(Observation)
        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
          observationRegistrar.access(self, keyPath: \.self)
        }
      #endif
      recomputeIfNeeded()
      yield _cachedValue!
    }
  }

  private let descriptor: any ComputedDescriptor<Value>

  nonisolated(unsafe)
  public var incomingEdges: ContiguousArray<Edge> = []
  
  nonisolated(unsafe)
  public var outgoingEdges: ContiguousArray<Edge> = []
  
  nonisolated(unsafe)
  public var trackingRegistrations: Set<TrackingRegistration> = []

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
    name: String? = nil,
    descriptor: some ComputedDescriptor<Value>
  ) {
    self.info = .init(
      type: Value.self,
      group: nil,
      name: name,
      id: makeUniqueNumber(),
      sourceLocation: .init(file: file, line: line, column: column)
    )
    self.descriptor = descriptor
    self.lock = .init()

    if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
      self._observationRegistrar = ObservationRegistrar()
    } else {
      self._observationRegistrar = nil
    }

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
    name: String? = nil,
    rule: @escaping @Sendable (inout Context) -> Value
  ) {
    self.info = .init(
      type: Value.self,
      group: nil,
      name: name,
      id: makeUniqueNumber(),
      sourceLocation: .init(file: file, line: line, column: column)
    )
    self.descriptor = AnyComputedDescriptor(compute: rule, isEqual: { _, _ in false })      
    self.lock = .init()

    if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
      self._observationRegistrar = ObservationRegistrar()
    } else {
      self._observationRegistrar = nil
    }

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
    name: String? = nil,
    rule: @escaping @Sendable (inout Context) -> Value
  ) where Value: Equatable {
    self.info = .init(
      type: Value.self,
      group: nil,
      name: name,
      id: makeUniqueNumber(),
      sourceLocation: .init(file: file, line: line, column: column)
    )
    self.descriptor = AnyComputedDescriptor(compute: rule, isEqual: { $0 == $1 })
    self.lock = .init()

    if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
      self._observationRegistrar = ObservationRegistrar()
    } else {
      self._observationRegistrar = nil
    }

#if DEBUG
    Task {
      await NodeStore.shared.register(node: self)
    }
#endif
  }
  
    deinit {
      Log.generic.debug("Deinit Computed: id=\(self.info.id)")
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
    // record tracking
    if let registration = TrackingRegistration.registration {
      self.trackingRegistrations.insert(registration)
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

        /**
        To prevent adding tracking registration to the incoming nodes.
        Only register the registration to the current node.
        */        
        _cachedValue = TrackingRegistration.$registration.withValue(nil) {
          return descriptor.compute(context: &context)
        }

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
    "Computed<\(Value.self)>(id=\(info.id), name=\(info.name ?? "noname"), value=\(String(describing: _cachedValue)))"
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

public struct Edge: CustomDebugStringConvertible, Equatable {
  
  public static func == (lhs: Edge, rhs: Edge) -> Bool {
    return lhs.state.pointer == rhs.state.pointer
  }

  struct State {
    unowned let from: any TypeErasedNode
    unowned let to: any TypeErasedNode
    var isPending: Bool = false
  }
  
  private let state: ManagedCriticalState<State>
  
  var isPending: Bool {
    get {
      state.withCriticalRegion { state in
        state.isPending
      }
    }
    set {
      state.withCriticalRegion { state in
        state.isPending = newValue        
      }
    }      
  }

  init(from: any TypeErasedNode, to: any TypeErasedNode) {
    self.state = .init(.init(from: from, to: to))
  }

  public var debugDescription: String {
    state.withCriticalRegion { state in
      "\(state.from.debugDescription) -> \(state.to.debugDescription)"
    }
  }
  
}

public typealias NodeLock = NSRecursiveLock

struct ManagedCriticalState<State> {
  private final class LockedBuffer: ManagedBuffer<State, Lock.Primitive> {
    deinit {
      withUnsafeMutablePointerToElements { Lock.deinitialize($0) }
    }
  }
  
  private let buffer: ManagedBuffer<State, Lock.Primitive>
  
  var pointer: UnsafeMutableRawPointer {
    return Unmanaged.passUnretained(buffer).toOpaque()
  }
  
  init(_ initial: State) {
    buffer = LockedBuffer.create(minimumCapacity: 1) { buffer in
      buffer.withUnsafeMutablePointerToElements { Lock.initialize($0) }
      return initial
    }
  }
  
  func withCriticalRegion<R>(_ critical: (inout State) throws -> R) rethrows -> R {
    try buffer.withUnsafeMutablePointers { header, lock in
      Lock.lock(lock)
      defer { Lock.unlock(lock) }
      return try critical(&header.pointee)
    }
  }
}

internal struct Lock {
#if canImport(Darwin)
  typealias Primitive = os_unfair_lock
#elseif canImport(Glibc) || canImport(Musl) || canImport(Bionic)
  typealias Primitive = pthread_mutex_t
#elseif canImport(WinSDK)
  typealias Primitive = SRWLOCK
#else
#error("Unsupported platform")
#endif
  
  typealias PlatformLock = UnsafeMutablePointer<Primitive>
  let platformLock: PlatformLock
  
  private init(_ platformLock: PlatformLock) {
    self.platformLock = platformLock
  }
  
  fileprivate static func initialize(_ platformLock: PlatformLock) {
#if canImport(Darwin)
    platformLock.initialize(to: os_unfair_lock())
#elseif canImport(Glibc) || canImport(Musl) || canImport(Bionic)
    let result = pthread_mutex_init(platformLock, nil)
    precondition(result == 0, "pthread_mutex_init failed")
#elseif canImport(WinSDK)
    InitializeSRWLock(platformLock)
#else
#error("Unsupported platform")
#endif
  }
  
  fileprivate static func deinitialize(_ platformLock: PlatformLock) {
#if canImport(Glibc) || canImport(Musl) || canImport(Bionic)
    let result = pthread_mutex_destroy(platformLock)
    precondition(result == 0, "pthread_mutex_destroy failed")
#endif
    platformLock.deinitialize(count: 1)
  }
  
  fileprivate static func lock(_ platformLock: PlatformLock) {
#if canImport(Darwin)
    os_unfair_lock_lock(platformLock)
#elseif canImport(Glibc) || canImport(Musl) || canImport(Bionic)
    pthread_mutex_lock(platformLock)
#elseif canImport(WinSDK)
    AcquireSRWLockExclusive(platformLock)
#else
#error("Unsupported platform")
#endif
  }
  
  fileprivate static func unlock(_ platformLock: PlatformLock) {
#if canImport(Darwin)
    os_unfair_lock_unlock(platformLock)
#elseif canImport(Glibc) || canImport(Musl) || canImport(Bionic)
    let result = pthread_mutex_unlock(platformLock)
    precondition(result == 0, "pthread_mutex_unlock failed")
#elseif canImport(WinSDK)
    ReleaseSRWLockExclusive(platformLock)
#else
#error("Unsupported platform")
#endif
  }
  
  static func allocate() -> Lock {
    let platformLock = PlatformLock.allocate(capacity: 1)
    initialize(platformLock)
    return Lock(platformLock)
  }
  
  func deinitialize() {
    Lock.deinitialize(platformLock)
    platformLock.deallocate()
  }
  
  func lock() {
    Lock.lock(platformLock)
  }
  
  func unlock() {
    Lock.unlock(platformLock)
  }
  
  /// Acquire the lock for the duration of the given block.
  ///
  /// This convenience method should be preferred to `lock` and `unlock` in
  /// most situations, as it ensures that the lock will be released regardless
  /// of how `body` exits.
  ///
  /// - Parameter body: The block to execute while holding the lock.
  /// - Returns: The value returned by the block.
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    self.lock()
    defer {
      self.unlock()
    }
    return try body()
  }
  
  // specialise Void return (for performance)
  func withLockVoid(_ body: () throws -> Void) rethrows -> Void {
    try self.withLock(body)
  }
}
