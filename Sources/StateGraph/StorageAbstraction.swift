import Foundation

#if canImport(Observation)
  import Observation
#endif

// MARK: - Storage Protocol

public protocol Storage<Value>: Sendable {
  
  associatedtype Value
      
  mutating func loaded(context: StorageContext)
  
  func unloaded() 
  
  var value: Value { get set }
  
}

public struct StorageContext: Sendable {
  
  private let onStorageUpdated: @Sendable () -> Void
    
  init(onStorageUpdated: @Sendable @escaping () -> Void) {
    self.onStorageUpdated = onStorageUpdated
  }
  
  public func notifyStorageUpdated() {
    onStorageUpdated()
  }
  
}

// MARK: - Concrete Storage Implementations

public struct InMemoryStorage<Value>: Storage {
  
  nonisolated(unsafe)
  public var value: Value
  
  public init(initialValue: consuming Value) {
    self.value = initialValue
  }
    
  public func loaded(context: StorageContext) {
    
  }
  
  public func unloaded() {
    
  }
    
}

public final class UserDefaultsStorage<Value: UserDefaultsStorable>: Storage, Sendable {
  
  nonisolated(unsafe)
  private let userDefaults: UserDefaults
  private let key: String
  private let defaultValue: Value
  
  nonisolated(unsafe)
  private var subscription: NSObjectProtocol?
  
  nonisolated(unsafe)
  private var cachedValue: Value?
  
  public var value: Value {
    get {
      if let cachedValue {
        return cachedValue
      }
      let loadedValue = Value._getValue(
        from: userDefaults,
        forKey: key,
        defaultValue: defaultValue
      )
      cachedValue = loadedValue
      return loadedValue
    }
    set {
      cachedValue = newValue
      newValue._setValue(to: userDefaults, forKey: key)
    }
  }
  
  nonisolated(unsafe)
  private var previousValue: Value?
  
  public init(
    userDefaults: UserDefaults,
    key: String,
    defaultValue: Value
  ) {
    self.userDefaults = userDefaults
    self.key = key
    self.defaultValue = defaultValue
  }
     
  public func loaded(context: StorageContext) {
    
    previousValue = value
    
    subscription = NotificationCenter.default
      .addObserver(
        forName: UserDefaults.didChangeNotification,
        object: userDefaults,
        queue: nil,
        using: { [weak self] _ in                      
          guard let self else { return }
          
          // Invalidate cache and reload value
          self.cachedValue = nil
          let value = self.value
          guard self.previousValue != value else {
            return
          }
          
          self.previousValue = value
          
          context.notifyStorageUpdated()
        }
      )
  }  
  
  public func unloaded() {
    guard let subscription else { return }
    NotificationCenter.default.removeObserver(subscription)
  }
}

// MARK: - Base Stored Node

public final class _Stored<Value, S: Storage<Value>>: Node, Observable, CustomDebugStringConvertible {
  
  public let lock: NodeLock
  
  nonisolated(unsafe)
  private var storage: S
  
#if canImport(Observation)
  @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
  private var observationRegistrar: ObservationRegistrar {
    return .shared
  }
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
    get {
      
#if canImport(Observation)
      if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
        observationRegistrar.access(PointerKeyPathRoot.shared, keyPath: _keyPath(self))        
      }
#endif
      
      lock.lock()
      defer { lock.unlock() }

      // record dependency
      if let currentNode = ThreadLocal.currentNode.value {
        let edge = Edge(from: self, to: currentNode)
        outgoingEdges.append(edge)
        currentNode.incomingEdges.append(edge)
      }
      // record tracking
      if let registration = ThreadLocal.registration.value {
        self.trackingRegistrations.insert(registration)
      }
      // record trace
      if let collector = ThreadLocal.traceCollector.value {
        collector.append(self)
      }

      return storage.value
    }
    set {
      
#if canImport(Observation)
      if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) { 
        withMainActor { [observationRegistrar, keyPath = _keyPath(self)] in     
          observationRegistrar.willSet(PointerKeyPathRoot.shared, keyPath: keyPath)   
        }
      }
      
      defer {
        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
          withMainActor { [observationRegistrar, keyPath = _keyPath(self)] in     
            observationRegistrar.didSet(PointerKeyPathRoot.shared, keyPath: keyPath)
          }
        }
      }
#endif
      
      lock.lock()

      storage.value = newValue

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
  
  private func notifyStorageUpdated() {
#if canImport(Observation)
    if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
      // Workaround: SwiftUI will not trigger update if we call only didSet.
      // as here is where the value already updated.
      withMainActor { [observationRegistrar, keyPath = _keyPath(self)] in   
        observationRegistrar.willSet(PointerKeyPathRoot.shared, keyPath: keyPath)
        observationRegistrar.didSet(PointerKeyPathRoot.shared, keyPath: keyPath)  
      }
    }
#endif
    
    lock.lock()

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
    name: StaticString? = nil,
    storage: consuming S
  ) {
    self.info = .init(
      name: name,
      sourceLocation: .init(file: file, line: line, column: column)
    )
    self.lock = .init()
    self.storage = storage
           
    self.storage.loaded(context: .init(onStorageUpdated: { [weak self] in      
      self?.notifyStorageUpdated()      
    }))
    
#if DEBUG
    Task {
      await NodeStore.shared.register(node: self)
    }
#endif
  }
  
  deinit {
//    Log.generic.debug("Deinit StoredNode: \(self.info.name.map(String.init) ?? "noname")")
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
    let value = storage.value
    let typeName = _typeName(type(of: self))    
    return "\(typeName)(name=\(info.name.map(String.init) ?? "noname"), value=\(String(describing: value)))"
  }
  
  /// Accesses the value with thread-safe locking.
  ///
  /// - Parameter body: A closure that takes an inout parameter of the value
  /// - Returns: The result of the closure
  public borrowing func withLock<Result, E>(
    _ body: (inout Value) throws(E) -> Result
  ) throws(E) -> Result where E : Error {
    lock.lock()
    defer {
      lock.unlock()
    }
    let result = try body(&storage.value)
    return result
  }
  
} 
