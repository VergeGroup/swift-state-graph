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
        "StateView": StateViewMacro.self,
        "_Stored" : StoredMacro.self,
      ]
    ) {
      super.invokeTest()
    }
  }
  
  func test_primitive() {
    
    assertMacro {
      """
      @StateView
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

        @_Ignored private let $count: StoredNode<Int> = .init(wrappedValue: 0)

        init() {
        
        }

        internal var sink: Sink<Void> = .init()

      }

      extension Model: StateViewType {
      }
      """
    }
    
  }
 
  
}
