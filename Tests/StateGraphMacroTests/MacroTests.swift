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
        "GraphView": GraphViewMacro.self,
        "GraphStored": StoredMacro.self,
      ]
    ) {
      super.invokeTest()
    }
  }
  
  func test_primitive() {
    
    assertMacro {
      """
      @GraphView
      final class Model {
      
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

        @GraphIgnored let $count: StoredNode<Int> = .init(wrappedValue: 0)

        init() {
        
        }

      }

      extension Model: GraphViewType {
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
          public let $weak_variable: StoredNode<Weak<AnyObject>>

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

        @GraphIgnored let $unowned_variable: StoredNode<Unowned<AnyObject>>
        
        unowned let unowned_constant: AnyObject

      }
      """
    }
    
  }
}
