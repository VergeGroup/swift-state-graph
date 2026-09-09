import MacroTesting
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest
@testable import StateGraphMacro

final class GraphComputedMacroTests: XCTestCase {

  override func invokeTest() {
    withMacroTesting(
      record: false,
      macros: [
        "GraphComputed": GraphComputedMacro.self,
      ]
    ) {
      super.invokeTest()
    }
  }

  #if compiler(>=6.4)
  func test_public_property_preserves_projected_access_control() {
    assertMacro {
      """
      public final class Model {
        @GraphComputed
        public var doubled: Int {
          count * 2
        }
      }
      """
    } expansion: {
      """
      public final class Model {
        public var doubled: Int {
          return $doubled.wrappedValue
        }

        @GraphIgnored
        private let _doubled: GraphComputedBacking<Model, Int> = .init(name: "doubled", ownerType: Model.self) { owner, context in
          owner._compute_doubled(&context)
        }

        @GraphIgnored
        public var $doubled: Computed<Int> {
          _doubled.node(owner: self)
        }

        @GraphIgnored
        private func _compute_doubled(_ context: inout Computed<Int>.Context) -> Int {
          count * 2
        }
      }
      """
    }
  }

  func test_computed_body_property() {
    assertMacro {
      """
      final class Model {
        @GraphComputed
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
        private let _doubled: GraphComputedBacking<Model, Int> = .init(name: "doubled", ownerType: Model.self) { owner, context in
          owner._compute_doubled(&context)
        }

        @GraphIgnored
        var $doubled: Computed<Int> {
          _doubled.node(owner: self)
        }

        @GraphIgnored
        private func _compute_doubled(_ context: inout Computed<Int>.Context) -> Int {
          count * 2
        }
      }
      """
    }
  }

  func test_top_level_computed_body_property() {
    assertMacro {
      """
      @GraphComputed
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
      private let _doubled: GraphComputedGlobalBacking<Int> = .init(name: "doubled") { context in
        _compute_doubled(&context)
      }

      @GraphIgnored
      var $doubled: Computed<Int> {
        _doubled.node()
      }

      @GraphIgnored
      private func _compute_doubled(_ context: inout Computed<Int>.Context) -> Int {
        count * 2
      }
      """
    }
  }

  func test_static_computed_body_property() {
    assertMacro {
      """
      enum Model {
        @GraphComputed
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
        private static let _doubled: GraphComputedGlobalBacking<Int> = .init(name: "doubled") { context in
          _compute_doubled(&context)
        }

        @GraphIgnored
        static var $doubled: Computed<Int> {
          _doubled.node()
        }

        @GraphIgnored
        private static func _compute_doubled(_ context: inout Computed<Int>.Context) -> Int {
          count * 2
        }
      }
      """
    }
  }
  #endif
}
