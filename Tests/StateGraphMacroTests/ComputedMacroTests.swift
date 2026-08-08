import MacroTesting
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest
@testable import StateGraphMacro

final class ComputedMacroTests: XCTestCase {

  override func invokeTest() {
    withMacroTesting(
      record: false,
      macros: [
        "GraphComputed": ComputedMacro.self,
        "GraphComputedBody": ComputedMacro.self,
      ]
    ) {
      super.invokeTest()
    }
  }

  #if compiler(>=6.4) && SSG_ENABLE_COMPUTED_BODY_TESTS
  func test_computed_body_property() {
    assertMacro {
      """
      final class Model {
        @GraphComputedBody
        var doubled: Int {
          count * 2
        }
      }
      """
    } expansion: {
      """
      final class Model {
        var doubled: Int {
          return $doubled.wrappedValue
        }

        @GraphIgnored
        private let _graphComputedBacking_doubled: GraphComputedBacking<Model, Int> = .init(name: "doubled", ownerType: Model.self) { owner, context in
          owner.__graphCompute_doubled(&context)
        }

        @GraphIgnored
        var $doubled: Computed<Int> {
          _graphComputedBacking_doubled.node(owner: self)
        }

        @GraphIgnored
        private func __graphCompute_doubled(_ context: inout Computed<Int>.Context) -> Int {
          count * 2
        }
      }
      """
    }
  }

  func test_top_level_computed_body_property() {
    assertMacro {
      """
      @GraphComputedBody
      var doubled: Int {
        count * 2
      }
      """
    } expansion: {
      """
      var doubled: Int {
        return $doubled.wrappedValue
      }

      @GraphIgnored
      private let _graphComputedBacking_doubled: GraphComputedGlobalBacking<Int> = .init(name: "doubled") { context in
        __graphCompute_doubled(&context)
      }

      @GraphIgnored
      var $doubled: Computed<Int> {
        _graphComputedBacking_doubled.node()
      }

      @GraphIgnored
      private func __graphCompute_doubled(_ context: inout Computed<Int>.Context) -> Int {
        count * 2
      }
      """
    }
  }

  func test_static_computed_body_property() {
    assertMacro {
      """
      enum Model {
        @GraphComputedBody
        static var doubled: Int {
          count * 2
        }
      }
      """
    } expansion: {
      """
      enum Model {
        static var doubled: Int {
          return $doubled.wrappedValue
        }

        @GraphIgnored
        private static let _graphComputedBacking_doubled: GraphComputedGlobalBacking<Int> = .init(name: "doubled") { context in
          __graphCompute_doubled(&context)
        }

        @GraphIgnored
        static var $doubled: Computed<Int> {
          _graphComputedBacking_doubled.node()
        }

        @GraphIgnored
        private static func __graphCompute_doubled(_ context: inout Computed<Int>.Context) -> Int {
          count * 2
        }
      }
      """
    }
  }
  #endif
}
