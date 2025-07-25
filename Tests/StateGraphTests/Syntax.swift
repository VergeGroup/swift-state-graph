import StateGraph

#if DEBUG

import os.lock

// Test top-level property - this should not have init accessor but should have get/set
@GraphStored
private var testTopLevel: Int = 123

private enum Static {
  @GraphStored
  static var staticValue: Int = 0
  
  @GraphStored
  static var staticValue2: String? = nil
}

final class UserDefaultsModel {
  
  @GraphStored(backed: .userDefaults(key: "value")) var value: Int = 0
  @GraphStored(backed: .userDefaults(key: "value2")) var value2: String? = nil
  @GraphStored(backed: .userDefaults(key: "maxRetries")) var maxRetries: Int = 3
  
}

final class PrivateExample {
  
  @GraphStored 
  private var private_value: Int = 0
  
  @GraphStored 
  private(set) var _private_set_value: Int = 0
  
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
  var value: Int? = nil
  
  @GraphStored
  var value2: Int! = nil
    
  init() {
    
  }
  
  static func run() {
    _ = ImplicitInitializers()
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
  
  @GraphStored
  var optional_variable_init: Int? = nil
   
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
    self.optional_variable = 0
    unowned_constant = NSObject()
    self.unowned_variable = NSObject()
    
  }
  
}

#endif
