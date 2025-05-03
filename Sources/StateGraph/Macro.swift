
//@attached(member, names: named(sink))
@attached(extension, conformances: StateViewType)
@attached(memberAttribute)
public macro StateView() = #externalMacro(module: "StateGraphMacro", type: "StateViewMacro")

@attached(accessor, names: named(init), named(get), named(set))
@attached(peer, names: prefixed(`$`))
public macro _Stored() = #externalMacro(module: "StateGraphMacro", type: "StoredMacro")

@attached(accessor, names: named(init), named(get), named(set))
@attached(peer, names: prefixed(_backing_), prefixed(_has_registered))
public macro _StoredWeak() = #externalMacro(module: "StateGraphMacro", type: "StoredMacro")

@attached(body)
@attached(peer, names: prefixed(_backing_))
public macro _Computed() = #externalMacro(module: "StateGraphMacro", type: "ComputedMacro")

@attached(peer)
public macro _Ignored() = #externalMacro(module: "StateGraphMacro", type: "IgnoredMacro")

@_exported import os.lock

#if DEBUG

import os.lock

@StateView
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
  
  @_Ignored
  weak var weak_variable: AnyObject?
  
  @_Ignored
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
