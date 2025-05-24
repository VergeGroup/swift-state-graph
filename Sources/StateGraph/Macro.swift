
//@attached(extension, conformances: GraphViewType)
//@attached(memberAttribute)
//public macro GraphView() = #externalMacro(module: "StateGraphMacro", type: "GraphViewMacro")

@attached(accessor, names: named(init), named(get), named(set))
@attached(peer, names: prefixed(`$`))
public macro GraphStored() = #externalMacro(module: "StateGraphMacro", type: "StoredMacro")

@attached(accessor, names: named(get), named(set))
@attached(peer, names: prefixed(`$`))
public macro GraphComputed() = #externalMacro(module: "StateGraphMacro", type: "ComputedMacro")

@attached(accessor, names: named(get), named(set))
@attached(peer, names: prefixed(`$`))
public macro GraphUserDefaultsStored(key: String) = #externalMacro(module: "StateGraphMacro", type: "UserDefaultsStoredMacro")

@attached(accessor, names: named(get), named(set))
@attached(peer, names: prefixed(`$`))
public macro GraphUserDefaultsStored(suite: String, key: String) = #externalMacro(module: "StateGraphMacro", type: "UserDefaultsStoredMacro")

@attached(accessor, names: named(get), named(set))
@attached(peer, names: prefixed(`$`))
public macro GraphUserDefaultsStored(suite: String, key: String, name: String) = #externalMacro(module: "StateGraphMacro", type: "UserDefaultsStoredMacro")

@attached(peer)
public macro GraphIgnored() = #externalMacro(module: "StateGraphMacro", type: "IgnoredMacro")

@_exported import os.lock

#if DEBUG

import os.lock

final class UserDefaultsModel {
  
  @GraphUserDefaultsStored(key: "value") var value: Int = 0
  @GraphUserDefaultsStored(key: "value2") var value2: String? = nil
  @GraphUserDefaultsStored(key: "maxRetries") var maxRetries: Int = 3
  
}

final class ImplicitInitializers {
  @GraphStored
  var value: Int?
  
  @GraphStored
  var value2: Int!
  
  @GraphStored
  weak var weak_object: AnyObject?
  
  static func run() {
    let obj = ImplicitInitializers()
    

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
