import Foundation

#if canImport(Observation)
  import Observation
#endif

// MARK: - Storage Protocol

public protocol Storage<Value>: Sendable {
  
  associatedtype Value
  
  mutating func loaded(host node: Weak<_StoredNode<Value, Self>>)
  
  func unloaded() 
  
  func getValue() -> Value
  
  mutating func setValue(_ value: Value)
}

// MARK: - Concrete Storage Implementations

public struct InMemoryStorage<Value>: Storage {
  
  nonisolated(unsafe)
  private var _value: Value
  
  public init(initialValue: Value) {
    self._value = initialValue
  }
  
  public func getValue() -> Value {
    return _value
  }
  
  public mutating func setValue(_ value: Value) {
    _value = value
  }
  
  public func loaded(host node: Weak<_StoredNode<Value, InMemoryStorage<Value>>>) {
    
  }
  
  public func unloaded() {
    
  }
    
}

public struct UserDefaultsStorage<Value: UserDefaultsStorable>: Storage, Sendable {
  
  nonisolated(unsafe)
  private let userDefaults: UserDefaults
  private let key: String
  private let defaultValue: Value
  
  nonisolated(unsafe)
  private var subscription: NSObjectProtocol?
  
  public init(
    userDefaults: UserDefaults,
    key: String,
    defaultValue: Value
  ) {
    self.userDefaults = userDefaults
    self.key = key
    self.defaultValue = defaultValue
  }
  
  public func getValue() -> Value {
    return Value.getValue(from: userDefaults, forKey: key, defaultValue: defaultValue)
  }
  
  public func setValue(_ value: Value) {
    value.setValue(to: userDefaults, forKey: key)
  }
  
  public mutating func loaded(
    host node: Weak<_StoredNode<Value, UserDefaultsStorage<Value>>>
  ) {
      
    subscription = NotificationCenter.default
      .addObserver(
        forName: UserDefaults.didChangeNotification,
        object: userDefaults,
        queue: nil,
        using: { [self] _ in              
          node.value?.wrappedValue = getValue()
        }
      )    
    
  }
  
  public func unloaded() {
    guard let subscription else { return }
    NotificationCenter.default.removeObserver(subscription)
  }
}

// MARK: - Base Stored Node

/// ストレージを抽象化した共通のStoredNodeベースクラス
public final class _StoredNode<Value, S: Storage<Value>>: Node, Observable, CustomDebugStringConvertible {
  
  public let lock: NodeLock
  
  nonisolated(unsafe)
  private var storage: S
  
#if canImport(Observation)
  @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
  private var observationRegistrar: ObservationRegistrar {
    _observationRegistrar as! ObservationRegistrar
  }
  private let _observationRegistrar: (Any & Sendable)?
#endif
  
  public var potentiallyDirty: Bool {
    get {
      return false
    }
    set {
      fatalError()
    }
  }
  
  public let info: NodeInfo
  
  public var wrappedValue: Value {
    _read {
      
#if canImport(Observation)
      if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
        observationRegistrar.access(self, keyPath: \.self)
      }
#endif
      
      lock.lock()
      defer { lock.unlock() }
      
      // record dependency
      if let currentNode = TaskLocals.currentNode {
        let edge = Edge(from: self, to: currentNode)
        outgoingEdges.append(edge)
        currentNode.incomingEdges.append(edge)
      }
      // record tracking
      if let registration = TrackingRegistration.registration {
        self.trackingRegistrations.insert(registration)
      }
      
      let value = storage.getValue()
      yield value
    }
    _modify {
      
#if canImport(Observation)
      if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) { 
        observationRegistrar.willSet(self, keyPath: \.self)
      }
      
      defer {
        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
          observationRegistrar.didSet(self, keyPath: \.self)
        }
      }
#endif
      
      lock.lock()
      
      var value = storage.getValue()
      yield &value
      
      // ストレージに値を保存
      storage.setValue(value)
      
      let _outgoingEdges = outgoingEdges
      let _trackingRegistrations = trackingRegistrations
      self.trackingRegistrations.removeAll()
      
      lock.unlock()
      
      for registration in _trackingRegistrations {
        registration.perform()
      }
      
      for edge in _outgoingEdges {
        edge.isPending = true
        edge.to.potentiallyDirty = true
      }
    }
  }
  
  public var incomingEdges: ContiguousArray<Edge> {
    get {
      fatalError()
    }
    set {
      fatalError()
    }
  }
  
  nonisolated(unsafe)
  public var outgoingEdges: ContiguousArray<Edge> = []
  
  nonisolated(unsafe)
  public var trackingRegistrations: Set<TrackingRegistration> = []
  
  public init(
    _ file: StaticString = #fileID,
    _ line: UInt = #line,
    _ column: UInt = #column,
    group: String? = nil,
    name: String? = nil,
    storage: consuming S
  ) {
    self.info = .init(
      type: Value.self,
      group: group,
      name: name,
      id: makeUniqueNumber(),
      sourceLocation: .init(file: file, line: line, column: column)
    )
    self.lock = sharedLock
    self.storage = storage
    
    if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
      self._observationRegistrar = ObservationRegistrar()
    } else {
      self._observationRegistrar = nil
    }
    
    self.storage.loaded(host: .init(self))
    
#if DEBUG
    Task {
      await NodeStore.shared.register(node: self)
    }
#endif
  }
  
  deinit {
    Log.generic.debug("Deinit StoredNode: \(self.info.name ?? "noname")")
    for edge in outgoingEdges {
      edge.to.incomingEdges.removeAll(where: { $0 === edge })
    }
    outgoingEdges.removeAll()
    storage.unloaded()
  }
  
  public func recomputeIfNeeded() {
    // no operation
  }
  
  public var debugDescription: String {
    let value = storage.getValue()
    return "StoredNode<\(Value.self)>(id=\(info.id), name=\(info.name ?? "noname"), value=\(String(describing: value)))"
  }
  
  /// Accesses the value with thread-safe locking.
  ///
  /// - Parameter body: A closure that takes an inout parameter of the value
  /// - Returns: The result of the closure
  public func withLock<Result, E>(
    _ body: (inout Value) throws(E) -> Result
  ) throws(E) -> Result where E : Error {
    lock.lock()
    defer {
      lock.unlock()
    }
    var value = storage.getValue()
    let result = try body(&value)
    storage.setValue(value)
    return result
  }
} 
