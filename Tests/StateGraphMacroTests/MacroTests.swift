import MacroTesting
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest
@testable import StateGraphMacro

final class MacroTests: XCTestCase {
  
  override func invokeTest() {
    withMacroTesting(
      record: false,
      macros: [
        "GraphStored": StoredMacro.self,
      ]
    ) {
      super.invokeTest()
    }
  }
  
  func test_primitive() {
    
    assertMacro {
      """
      final class Model {
      
        @GraphStored
        var count: Int = 0
      
        init() {
        
        }
      
      }
      """
    } expansion: {
      """
      final class Model {
        var count: Int {
          get {
            return $count.wrappedValue
          }
          set {
            $count.wrappedValue = newValue
          }
        }

        @GraphIgnored let $count: Stored<Int> = .init(group: "Model", name: "count", wrappedValue: 0)

        init() {
        
        }

      }
      """
    }
    
  }
 
  func test_weak_reference() {
    
    assertMacro {
      """
      public final class A {
      
        @GraphStored
        public weak var weak_variable: AnyObject?             
        
        @GraphStored
        unowned var unowned_variable: AnyObject
        
        unowned let unowned_constant: AnyObject
      
      }
      """
    } expansion: {
      """
      public final class A {
        public weak var weak_variable: AnyObject? {             
          @storageRestrictions(
            initializes: $weak_variable
          )
          init(initialValue) {
            $weak_variable = .init(wrappedValue: .init(initialValue))
          }
          get {
            return $weak_variable.wrappedValue.value
          }
          set {
            $weak_variable.wrappedValue.value = newValue
          }
        }

        @GraphIgnored
          public let $weak_variable: Stored<Weak<AnyObject>>

        unowned var unowned_variable: AnyObject {
          @storageRestrictions(
            initializes: $unowned_variable
          )
          init(initialValue) {
            $unowned_variable = .init(wrappedValue: .init(initialValue))
          }
          get {
            return $unowned_variable.wrappedValue.value
          }
          set {
            $unowned_variable.wrappedValue.value = newValue
          }
        }

        @GraphIgnored let $unowned_variable: Stored<Unowned<AnyObject>>
        
        unowned let unowned_constant: AnyObject

      }
      """
    }
    
  }
}
