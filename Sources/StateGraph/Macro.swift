
//@attached(member, names: named(sink))
@attached(extension, conformances: GraphViewType)
@attached(memberAttribute)
public macro GraphView() = #externalMacro(module: "StateGraphMacro", type: "GraphViewMacro")

@attached(accessor, names: named(init), named(get), named(set))
@attached(peer, names: prefixed(`$`))
public macro _Stored() = #externalMacro(module: "StateGraphMacro", type: "StoredMacro")

@attached(accessor, names: named(init), named(get), named(set))
@attached(peer, names: prefixed(`$`))
public macro GraphStored() = #externalMacro(module: "StateGraphMacro", type: "StoredMacro")

@attached(accessor, names: named(init), named(get), named(set))
@attached(peer, names: prefixed(_backing_), prefixed(_has_registered))
public macro _StoredWeak() = #externalMacro(module: "StateGraphMacro", type: "StoredMacro")

//@attached(body)
//@attached(peer, names: prefixed(_backing_))
//@attached(accessor, names: named(init), named(get), named(set))
//public macro _Computed() = #externalMacro(module: "StateGraphMacro", type: "ComputedMacro")

@attached(peer)
public macro StageGraphIgnored() = #externalMacro(module: "StateGraphMacro", type: "IgnoredMacro")

@_exported import os.lock

#if DEBUG

import os.lock

final class A {
  
  @GraphStored
  weak var weak_variable: AnyObject?
  
  @GraphStored
  unowned var unowned_variable: AnyObject
    
  unowned let unowned_constant: AnyObject

  init(weak_variable: AnyObject? = nil, unowned_variable: AnyObject, unowned_constant: AnyObject) {
    self.weak_variable = weak_variable
    self.unowned_variable = unowned_variable
    self.unowned_constant = unowned_constant
  }  
}

@GraphView
final class StateViewModel {
  
  let constant_init: Int = 0
  
  var variable_init: Int = 0
  
  let optional_constant_init: Int? = 0
    
  var optional_variable_init: Int? = 0
  
  let optional_constant: Int?
  
  var optional_variable: Int?
  
  var computed: Int {
    0
  }
  
  @StageGraphIgnored
  weak var weak_variable: AnyObject?
  
  @StageGraphIgnored
  unowned var unowned_variable: AnyObject
  
  unowned let unowned_constant: AnyObject
  
  init() {
    self.optional_constant = 0
    self.optional_variable = 0
        
    unowned_constant = NSObject()
    self.unowned_variable = NSObject()
  }
  
}

/*
import SwiftData

@Model
final class SwiftDataModel {
  
  let constant: Int = 0
  
  var variable: Int = 0
  
  var optional_variable: Int?
  
  var computed: Int {
    0
  }
  
  weak var weak_variable: AnyObject?
    
  unowned var unowned_variable: AnyObject
  

  unowned let unowned_constant: AnyObject
  
  init() {
    
  }
  
}
*/
#endif
