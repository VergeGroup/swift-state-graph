

@attached(accessor, names: named(get), named(set))
@attached(peer, names: prefixed(`$`))
public macro GraphComputed() = #externalMacro(module: "StateGraphMacro", type: "ComputedMacro")



@attached(peer)
public macro GraphIgnored() = #externalMacro(module: "StateGraphMacro", type: "IgnoredMacro")

// MARK: - Backing Storage Types

/// Represents different types of backing storage for GraphStored properties
public enum GraphStorageBacking {
  /// In-memory storage (default)
  case memory
  /// UserDefaults storage with a key
  case userDefaults(key: String)
  /// UserDefaults storage with suite and key
  case userDefaults(suite: String, key: String)
  /// UserDefaults storage with suite, key, and name
  case userDefaults(suite: String, key: String, name: String)
}

// MARK: - Unified GraphStored Macro

/// Unified macro that supports different backing storage types
/// 
/// Usage:
/// ```swift
/// @GraphStored var count: Int = 0  // Memory storage (default)
/// @GraphStored(backed: .userDefaults(key: "count")) var storedCount: Int = 0
/// @GraphStored(backed: .userDefaults(suite: "com.app", key: "theme")) var theme: String = "light"
/// ```
@attached(accessor, names: named(init), named(get), named(set))
@attached(peer, names: prefixed(`$`))
public macro GraphStored(backed: GraphStorageBacking = .memory) = #externalMacro(module: "StateGraphMacro", type: "UnifiedStoredMacro")

@_exported import os.lock

#if DEBUG

import os.lock

final class UserDefaultsModel {
  
  @GraphStored(backed: .userDefaults(key: "value")) var value: Int = 0
  @GraphStored(backed: .userDefaults(key: "value2")) var value2: String? = nil
  @GraphStored(backed: .userDefaults(key: "maxRetries")) var maxRetries: Int = 3
  
}

// MARK: - Unified Syntax Demo

final class UnifiedSyntaxDemo {
  
  // Memory storage (default)
  @GraphStored var count: Int = 0
  @GraphStored var name: String?
  
  // UserDefaults storage
  @GraphStored(backed: .userDefaults(key: "theme")) var theme: String = "light"
  @GraphStored(backed: .userDefaults(key: "isEnabled")) var isEnabled: Bool = true
  
  // UserDefaults with suite
  @GraphStored(backed: .userDefaults(suite: "com.example.app", key: "apiUrl")) var apiUrl: String = "https://api.example.com"
  
}

final class ImplicitInitializers {
  @GraphStored
  var value: Int?
  
  @GraphStored
  var value2: Int!
  
  @GraphStored
  weak var weak_object: AnyObject?
  
  static func run() {
    _ = ImplicitInitializers()
  }
}


final class A {
  
  @GraphStored
  weak var weak_variable: AnyObject?
  
  @GraphStored
  unowned var unowned_variable: AnyObject
    
  unowned let unowned_constant: AnyObject

  init(weak_variable: AnyObject? = nil, unowned_variable: AnyObject, unowned_constant: AnyObject) {
    self.unowned_variable = unowned_variable
    self.unowned_constant = unowned_constant
    self.weak_variable = weak_variable
  }  
}

final class Box<T> {
  var value: T
  init(_ value: T) {
    self.value = value
  }
}

class Ref {}

final class Demo {
  
  weak var count: Ref? {
    get {
      box.value.value
    }
    set {
      box.value.value = newValue
    }
  }
  
  let box: Box<Weak<Ref>> = .init(.init(nil))
  
  init() {
    self.count = Ref()
  }
}

final class StateViewModel {
    
  let constant_init: Int = 0
  
  var variable_init: Int = 0
    
  let optional_constant_init: Int? = 0
  
  @GraphStored
  var optional_variable_init: Int? = 0
    
  let optional_constant: Int?
  
  @GraphStored
  var optional_variable: Int?
  
  var computed: Int {
    0
  }
  
  @GraphIgnored
  weak var weak_variable: AnyObject?
  
  @GraphIgnored
  unowned var unowned_variable: AnyObject
  
  unowned let unowned_constant: AnyObject
  
  init() {
    self.optional_constant = 0
        
    unowned_constant = NSObject()
    self.unowned_variable = NSObject()
    
    self.optional_variable = 0
  }
  
}

#endif
