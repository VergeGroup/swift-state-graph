import MacroTesting
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest
@testable import StateGraphMacro

final class GraphStoredMacroTests: XCTestCase {

  override func invokeTest() {
    withMacroTesting(
      record: false,
      macros: [
        "GraphStored": GraphStoredMacro.self,
      ]
    ) {
      super.invokeTest()
    }
  }

  func test_initialized_class_property() {
    assertMacro {
      """
      final class Model {

        @GraphStored
        var count: Int = 0

      }
      """
    } expansion: {
      """
      final class Model {
        var count: Int {
          @storageRestrictions(
            accesses: $count
          )
          init(initialValue) {
            $count.wrappedValue = initialValue
          }
          get {
            return $count.wrappedValue
          }
          set {
            $count.wrappedValue = newValue
          }
        }

        @GraphIgnored let $count: Stored<Int> = .init(name: "count", wrappedValue: 0)

      }
      """
    }
  }

  func test_private_set_access_control_is_inherited() {
    assertMacro {
      """
      final class Model {
        @GraphStored
        private(set) var value: Int = 0
      }
      """
    } expansion: {
      """
      final class Model {
        private(set) var value: Int {
          @storageRestrictions(
            accesses: $value
          )
          init(initialValue) {
            $value.wrappedValue = initialValue
          }
          get {
            return $value.wrappedValue
          }
          set {
            $value.wrappedValue = newValue
          }
        }

        @GraphIgnored
          private let $value: Stored<Int> = .init(name: "value", wrappedValue: 0)
      }
      """
    }
  }

  func test_struct_property_uses_nonmutating_set() {
    assertMacro {
      """
      struct ViewState {

        @GraphStored
        var count: Int = 0

      }
      """
    } expansion: {
      """
      struct ViewState {
        var count: Int {
          @storageRestrictions(
            accesses: $count
          )
          init(initialValue) {
            $count.wrappedValue = initialValue
          }
          get {
            return $count.wrappedValue
          }
          nonmutating set {
            $count.wrappedValue = newValue
          }
        }

        @GraphIgnored let $count: Stored<Int> = .init(name: "count", wrappedValue: 0)

      }
      """
    }
  }

  func test_property_without_initializer_uses_initializing_accessor() {
    assertMacro {
      """
      final class Model {

        @GraphStored
        var count: Int

        init(count: Int) {
          self.count = count
        }

      }
      """
    } expansion: {
      """
      final class Model {
        var count: Int {
          @storageRestrictions(
            initializes: $count
          )
          init(initialValue) {
            $count = .init(name: "count", wrappedValue: initialValue)
          }
          get {
            return $count.wrappedValue
          }
          set {
            $count.wrappedValue = newValue
          }
        }

        @GraphIgnored let $count: Stored<Int>

        init(count: Int) {
          self.count = count
        }

      }
      """
    }
  }

  func test_optional_property_gets_nil_default() {
    assertMacro {
      """
      final class Model {

        @GraphStored
        var count: Int?

      }
      """
    } expansion: {
      """
      final class Model {
        var count: Int? {
          @storageRestrictions(
            accesses: $count
          )
          init(initialValue) {
            $count.wrappedValue = initialValue
          }
          get {
            return $count.wrappedValue
          }
          set {
            $count.wrappedValue = newValue
          }
        }

        @GraphIgnored let $count: Stored<Int?> = .init(name: "count", wrappedValue: nil)

      }
      """
    }
  }

  func test_implicitly_unwrapped_optional_uses_optional_storage() {
    assertMacro {
      """
      final class Model {

        @GraphStored
        var community: Community!

      }
      """
    } expansion: {
      """
      final class Model {
        var community: Community! {
          @storageRestrictions(
            accesses: $community
          )
          init(initialValue) {
            $community.wrappedValue = initialValue
          }
          get {
            return $community.wrappedValue!
          }
          set {
            $community.wrappedValue = newValue
          }
        }

        @GraphIgnored let $community: Stored<Community?> = .init(name: "community", wrappedValue: nil)

      }
      """
    }
  }

  func test_didSet_accessor_preserves_old_value() throws {
    let accessors = try expandGraphStoredAccessors(
      from: parseVariableDecl(
        #"""
        @GraphStored
        var count: Int = 0 {
          didSet(previousValue) {
            history.append((previousValue, count))
          }
        }
        """#
      )
    )

    XCTAssertEqual(
      accessors.map(\.trimmed.description).joined(separator: "\n\n"),
      """
      get {
        return $count.wrappedValue
      }

      set(__graphStoredNewValue) {
        let previousValue: Int = $count.wrappedValue
        $count.wrappedValue = __graphStoredNewValue
        do {
          history.append((previousValue, count))
        }
      }
      """
    )
  }

  func test_willSet_and_didSet_accessor_order() throws {
    let accessors = try expandGraphStoredAccessors(
      from: parseVariableDecl(
        #"""
        @GraphStored
        var count: Int = 0 {
          willSet(nextValue) {
            history.append((count, nextValue))
          }
          didSet(previousValue) {
            history.append((previousValue, count))
          }
        }
        """#
      )
    )

    XCTAssertEqual(
      accessors.map(\.trimmed.description).joined(separator: "\n\n"),
      """
      get {
        return $count.wrappedValue
      }

      set(__graphStoredNewValue) {
        do {
          let nextValue: Int = __graphStoredNewValue
          history.append((count, nextValue))
        }
        let previousValue: Int = $count.wrappedValue
        $count.wrappedValue = __graphStoredNewValue
        do {
          history.append((previousValue, count))
        }
      }
      """
    )
  }

  func test_weak_and_unowned_properties_are_rejected() {
    assertMacro {
      """
      final class Model {

        @GraphStored
        weak var weakValue: AnyObject?

        @GraphStored
        unowned var unownedValue: AnyObject

      }
      """
    } diagnostics: {
      """
      final class Model {

        @GraphStored
        ╰─ 🛑 weak variables are not supported with @GraphStored
        weak var weakValue: AnyObject?

        @GraphStored
        ╰─ 🛑 unowned variables are not supported with @GraphStored
        unowned var unownedValue: AnyObject

      }
      """
    }
  }

  private func expandGraphStoredAccessors(
    from variableDecl: VariableDeclSyntax
  ) throws -> [AccessorDeclSyntax] {
    let attribute = try XCTUnwrap(
      variableDecl.attributes.compactMap { attribute -> AttributeSyntax? in
        guard case .attribute(let attributeSyntax) = attribute else {
          return nil
        }
        return attributeSyntax
      }.first
    )

    return try GraphStoredMacro.expansion(
      of: attribute,
      providingAccessorsOf: variableDecl,
      in: BasicMacroExpansionContext(lexicalContext: [])
    )
  }

  private func parseVariableDecl(_ source: String) throws -> VariableDeclSyntax {
    let sourceFile = Parser.parse(source: source)

    return try XCTUnwrap(
      sourceFile.statements.compactMap { statement in
        statement.item.as(VariableDeclSyntax.self)
      }.first
    )
  }
}
