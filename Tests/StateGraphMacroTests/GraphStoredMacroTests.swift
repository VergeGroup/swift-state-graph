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
            initializes: $__init_count,
            accesses: $count
          )
          init(initialValue) {
            $__init_count = .init()
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

        @GraphIgnored private nonisolated(unsafe) var $__init_count: GraphStoredInitMarker = .init()

      }
      """
    }
  }

  func test_initialized_class_property_infers_type_from_static_member() {
    assertMacro {
      """
      final class Model {

        @GraphStored
        var createdAt = Date.now

      }
      """
    } expansion: {
      """
      final class Model {
        var createdAt {
          @storageRestrictions(
            initializes: $__init_createdAt,
            accesses: $createdAt
          )
          init(initialValue) {
            $__init_createdAt = .init()
            $createdAt.wrappedValue = initialValue
          }
          get {
            return $createdAt.wrappedValue
          }
          set {
            $createdAt.wrappedValue = newValue
          }
        }

        @GraphIgnored let $createdAt = StateGraph::Stored(name: "createdAt", wrappedValue: Date.now)

        @GraphIgnored private nonisolated(unsafe) var $__init_createdAt: GraphStoredInitMarker = .init()

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
            initializes: $__init_value,
            accesses: $value
          )
          init(initialValue) {
            $__init_value = .init()
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

        @GraphIgnored private nonisolated(unsafe) var $__init_value: GraphStoredInitMarker = .init()
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
            initializes: $__init_count,
            accesses: $count
          )
          init(initialValue) {
            $__init_count = .init()
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

        @GraphIgnored private nonisolated(unsafe) var $__init_count: GraphStoredInitMarker = .init()

      }
      """
    }
  }

  func test_initialized_struct_property_infers_type_and_uses_nonmutating_set() {
    assertMacro {
      """
      struct ViewState {

        @GraphStored
        var count = 0

      }
      """
    } expansion: {
      """
      struct ViewState {
        var count {
          @storageRestrictions(
            initializes: $__init_count,
            accesses: $count
          )
          init(initialValue) {
            $__init_count = .init()
            $count.wrappedValue = initialValue
          }
          get {
            return $count.wrappedValue
          }
          nonmutating set {
            $count.wrappedValue = newValue
          }
        }

        @GraphIgnored let $count = StateGraph::Stored(name: "count", wrappedValue: 0)

        @GraphIgnored private nonisolated(unsafe) var $__init_count: GraphStoredInitMarker = .init()

      }
      """
    }
  }

  func test_initialized_property_infers_storage_type_from_factory_or_optional_expression() throws {
    for (initializer, propertyName) in [
      ("makeValue()", "value"),
      ("Optional<Int>.none", "optionalValue"),
    ] {
      let peers = try expandGraphStoredPeersInClass(
        from: parseVariableDecl("@GraphStored var \(propertyName) = \(initializer)")
      )
      let expectedStorage = try parseVariableDecl(
        "@GraphIgnored let $\(propertyName) = StateGraph::Stored(name: \"\(propertyName)\", wrappedValue: \(initializer))"
      )

      XCTAssertEqual(
        peers.first?.tokens(viewMode: .sourceAccurate).map(\.text),
        expectedStorage.tokens(viewMode: .sourceAccurate).map(\.text)
      )
      XCTAssertTrue(peers.contains { $0.description.contains("$__init_\(propertyName)") })
    }
  }

  func test_initialized_static_property_infers_storage_type_without_init_marker() throws {
    let peers = try expandGraphStoredPeersInClass(
      from: parseVariableDecl("@GraphStored static var count = 0")
    )
    let expectedStorage = try parseVariableDecl(
      "@GraphIgnored static let $count = StateGraph::Stored(name: \"count\", wrappedValue: 0)"
    )

    XCTAssertEqual(
      peers.map { $0.tokens(viewMode: .sourceAccurate).map(\.text) },
      [expectedStorage.tokens(viewMode: .sourceAccurate).map(\.text)]
    )
  }

  func test_initialized_top_level_property_infers_storage_type_without_init_marker() throws {
    let peers = try expandGraphStoredPeers(
      from: parseVariableDecl("@GraphStored var count = 0"),
      context: BasicMacroExpansionContext(lexicalContext: [])
    )
    let expectedStorage = try parseVariableDecl(
      "@GraphIgnored let $count = StateGraph::Stored(name: \"count\", wrappedValue: 0)"
    )

    XCTAssertEqual(
      peers.map { $0.tokens(viewMode: .sourceAccurate).map(\.text) },
      [expectedStorage.tokens(viewMode: .sourceAccurate).map(\.text)]
    )
  }

  func test_property_without_type_annotation_or_initializer_is_rejected() throws {
    let context = BasicMacroExpansionContext(lexicalContext: [])
    let peers = try expandGraphStoredPeers(
      from: parseVariableDecl("@GraphStored var count"),
      context: context
    )

    XCTAssertTrue(peers.isEmpty)
    XCTAssertEqual(
      context.diagnostics.map(\.message),
      ["@GraphStored requires a type annotation or an initial value"]
    )
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
            initializes: $__init_count,
            accesses: $count
          )
          init(initialValue) {
            $__init_count = .init()
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

        @GraphIgnored private nonisolated(unsafe) var $__init_count: GraphStoredInitMarker = .init()

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
            initializes: $__init_community,
            accesses: $community
          )
          init(initialValue) {
            $__init_community = .init()
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

        @GraphIgnored private nonisolated(unsafe) var $__init_community: GraphStoredInitMarker = .init()

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
        let previousValue: Int = $count._valueForGraphStoredAssignment
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
        let previousValue: Int = $count._valueForGraphStoredAssignment
        $count.wrappedValue = __graphStoredNewValue
        do {
          history.append((previousValue, count))
        }
      }
      """
    )
  }

  func test_inferred_property_observers_infer_their_value_types() throws {
    let accessors = try expandGraphStoredAccessors(
      from: parseVariableDecl(
        #"""
        @GraphStored
        var count = 0 {
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
          let nextValue = __graphStoredNewValue
          history.append((count, nextValue))
        }
        let previousValue = $count._valueForGraphStoredAssignment
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

  func test_rejected_properties_do_not_declare_init_marker() throws {
    let accepted = try expandGraphStoredPeersInClass(
      from: parseVariableDecl("@GraphStored var value: Int = 0")
    )
    XCTAssertTrue(accepted.contains { $0.description.contains("$__init_value") })

    for source in [
      "@GraphStored let value: Int = 0",
      "@GraphStored weak var value: AnyObject?",
      "@GraphStored unowned var value: AnyObject",
    ] {
      let peers = try expandGraphStoredPeersInClass(from: parseVariableDecl(source))
      XCTAssertFalse(peers.contains { $0.description.contains("$__init_") }, source)
    }
  }

  private func expandGraphStoredPeersInClass(
    from variableDecl: VariableDeclSyntax
  ) throws -> [DeclSyntax] {
    let classDecl = try XCTUnwrap(
      Parser.parse(source: "final class Model {}").statements.first?.item.as(ClassDeclSyntax.self)
    )

    return try expandGraphStoredPeers(
      from: variableDecl,
      context: BasicMacroExpansionContext(lexicalContext: [Syntax(classDecl)])
    )
  }

  private func expandGraphStoredPeers(
    from variableDecl: VariableDeclSyntax,
    context: BasicMacroExpansionContext
  ) throws -> [DeclSyntax] {
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
      providingPeersOf: variableDecl,
      in: context
    )
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
