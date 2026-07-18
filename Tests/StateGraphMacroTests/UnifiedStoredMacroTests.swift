import MacroTesting
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest
@testable import StateGraphMacro

final class UnifiedStoredMacroTests: XCTestCase {
    
  override func invokeTest() {
    withMacroTesting(
      record: false,
      macros: [
        "GraphStored": UnifiedStoredMacro.self,
      ]
    ) {
      super.invokeTest()
    }
  }
  
  func test_private_set_modifier() {
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
  
  func test_private_modifier() {
    assertMacro {
      """
      final class Model {
        @GraphStored
        private var value: Int = 0
      }
      """
    } expansion: {
      """
      final class Model {
        private var value: Int {
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

  // MARK: - Memory Storage Tests
  
  func test_memory_storage_default() {
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

  func test_memory_storage_didSet_accessor_expansion() throws {
    let accessors = try expandGraphStoredAccessors(
      from: parseVariableDecl(
        """
        @GraphStored
        var count: Int = 0 {
          didSet {
            history.append((oldValue, count))
          }
        }
        """
      )
    )

    XCTAssertEqual(
      accessors.map(\.trimmed.description).joined(separator: "\n\n"),
      """
      get {
        return $count.wrappedValue
      }

      set(__graphStoredNewValue) {
        $count._setGraphStoredValue(
          __graphStoredNewValue,
          didSet: { __graphStoredOriginalValue, _ in
            let oldValue: Int = __graphStoredOriginalValue
            do {
              history.append((oldValue, count))
            }
          }
        )
      }
      """
    )
  }

  func test_memory_storage_willSet_accessor_expansion() throws {
    let accessors = try expandGraphStoredAccessors(
      from: parseVariableDecl(
        """
        @GraphStored
        var count: Int = 0 {
          willSet {
            history.append((count, newValue))
          }
        }
        """
      )
    )

    XCTAssertEqual(
      accessors.map(\.trimmed.description).joined(separator: "\n\n"),
      """
      get {
        return $count.wrappedValue
      }

      set(__graphStoredNewValue) {
        $count._setGraphStoredValue(
          __graphStoredNewValue,
          willSet: { _, __graphStoredFinalValue in
            do {
              let newValue: Int = __graphStoredFinalValue
              history.append((count, newValue))
            }
          }
        )
      }
      """
    )
  }

  func test_memory_storage_willSet_accessor_expansion_with_custom_new_value_name() throws {
    let accessors = try expandGraphStoredAccessors(
      from: parseVariableDecl(
        """
        @GraphStored
        var count: Int = 0 {
          willSet(nextValue) {
            history.append((count, nextValue))
          }
        }
        """
      )
    )

    XCTAssertEqual(
      accessors.map(\.trimmed.description).joined(separator: "\n\n"),
      """
      get {
        return $count.wrappedValue
      }

      set(__graphStoredNewValue) {
        $count._setGraphStoredValue(
          __graphStoredNewValue,
          willSet: { _, __graphStoredFinalValue in
            do {
              let nextValue: Int = __graphStoredFinalValue
              history.append((count, nextValue))
            }
          }
        )
      }
      """
    )
  }

  func test_memory_storage_willSet_and_didSet_accessor_expansion() throws {
    let accessors = try expandGraphStoredAccessors(
      from: parseVariableDecl(
        """
        @GraphStored
        var count: Int = 0 {
          willSet {
            history.append(("will", count, newValue))
          }
          didSet {
            history.append(("did", oldValue, count))
          }
        }
        """
      )
    )

    XCTAssertEqual(
      accessors.map(\.trimmed.description).joined(separator: "\n\n"),
      """
      get {
        return $count.wrappedValue
      }

      set(__graphStoredNewValue) {
        $count._setGraphStoredValue(
          __graphStoredNewValue,
          willSet: { _, __graphStoredFinalValue in
            do {
              let newValue: Int = __graphStoredFinalValue
              history.append(("will", count, newValue))
            }
          },
          didSet: { __graphStoredOriginalValue, _ in
            let oldValue: Int = __graphStoredOriginalValue
            do {
              history.append(("did", oldValue, count))
            }
          }
        )
      }
      """
    )
  }

  func test_memory_storage_observers_capture_instance_self() {
    assertMacro {
      """
      final class Model {
        @GraphStored
        var count: Int = 0 {
          willSet {
            history.append((count, newValue))
          }
          didSet {
            history.append((oldValue, count))
          }
        }

        var history: [(Int, Int)] = []
      }
      """
    } expansion: {
      """
      final class Model {
        var count: Int {
          willSet {
            history.append((count, newValue))
          }
          didSet {
            history.append((oldValue, count))
          }
          @storageRestrictions(
            accesses: $count
          )
          init(initialValue) {
            $count.wrappedValue = initialValue
          }

          get {
            return $count.wrappedValue
          }

          set(__graphStoredNewValue) {
            $count._setGraphStoredValue(
              __graphStoredNewValue,
              willSet: { [self] _, __graphStoredFinalValue in
                do {
                  let newValue: Int = __graphStoredFinalValue
                  history.append((count, newValue))
                }
              },
              didSet: { [self] __graphStoredOriginalValue, _ in
                let oldValue: Int = __graphStoredOriginalValue
                do {
                  history.append((oldValue, count))
                }
              }
            )
          }
        }

        @GraphIgnored let $count: Stored<Int> = .init(name: "count", wrappedValue: 0)

        var history: [(Int, Int)] = []
      }
      """
    }
  }

  func test_memory_storage_didSet_accessor_expansion_with_custom_old_value_name() throws {
    let accessors = try expandGraphStoredAccessors(
      from: parseVariableDecl(
        """
        @GraphStored
        var count: Int = 0 {
          didSet(previousValue) {
            history.append((previousValue, count))
          }
        }
        """
      )
    )

    XCTAssertEqual(
      accessors.map(\.trimmed.description).joined(separator: "\n\n"),
      """
      get {
        return $count.wrappedValue
      }

      set(__graphStoredNewValue) {
        $count._setGraphStoredValue(
          __graphStoredNewValue,
          didSet: { __graphStoredOriginalValue, _ in
            let previousValue: Int = __graphStoredOriginalValue
            do {
              history.append((previousValue, count))
            }
          }
        )
      }
      """
    )
  }

  func test_userdefaults_storage_didSet_accessor_expansion() throws {
    let accessors = try expandGraphStoredAccessors(
      from: parseVariableDecl(
        #"""
        @GraphStored(backed: .userDefaults(key: "username"))
        var username: String = "anonymous" {
          didSet {
            history.append((oldValue, username))
          }
        }
        """#
      )
    )

    XCTAssertEqual(
      accessors.map(\.trimmed.description).joined(separator: "\n\n"),
      """
      get {
        return $username.wrappedValue
      }

      set(__graphStoredNewValue) {
        $username._setGraphStoredValue(
          __graphStoredNewValue,
          didSet: { __graphStoredOriginalValue, _ in
            let oldValue: String = __graphStoredOriginalValue
            do {
              history.append((oldValue, username))
            }
          }
        )
      }
      """
    )
  }

  func test_userdefaults_storage_willSet_accessor_expansion() throws {
    let accessors = try expandGraphStoredAccessors(
      from: parseVariableDecl(
        #"""
        @GraphStored(backed: .userDefaults(key: "username"))
        var username: String = "anonymous" {
          willSet {
            history.append((username, newValue))
          }
        }
        """#
      )
    )

    XCTAssertEqual(
      accessors.map(\.trimmed.description).joined(separator: "\n\n"),
      """
      get {
        return $username.wrappedValue
      }

      set(__graphStoredNewValue) {
        $username._setGraphStoredValue(
          __graphStoredNewValue,
          willSet: { _, __graphStoredFinalValue in
            do {
              let newValue: String = __graphStoredFinalValue
              history.append((username, newValue))
            }
          }
        )
      }
      """
    )
  }

  func test_memory_storage_in_struct_uses_nonmutating_set() {
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

  func test_memory_storage_explicit() {
    assertMacro {
      """
      final class Model {
      
        @GraphStored(backed: .memory)
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
  
  func test_memory_storage_optional() {
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

  // MARK: - UserDefaults Storage Tests
  
  func test_userdefaults_storage_basic() {
    assertMacro {
      """
      final class Settings {
      
        @GraphStored(backed: .userDefaults(key: "username"))
        var username: String = "anonymous"

      }
      """
    } expansion: {
      """
      final class Settings {
        var username: String {
          get {
            return $username.wrappedValue
          }
          set {
            $username.wrappedValue = newValue
          }
        }

        @GraphIgnored let $username: UserDefaultsStored<String> = .init(name: "username", key: "username", defaultValue: "anonymous")

      }
      """
    }
  }

  func test_userdefaults_storage_with_suite() {
    assertMacro {
      """
      final class Settings {
      
        @GraphStored(backed: .userDefaults(suite: "com.example.app", key: "theme"))
        var theme: String = "light"

      }
      """
    } expansion: {
      """
      final class Settings {
        var theme: String {
          get {
            return $theme.wrappedValue
          }
          set {
            $theme.wrappedValue = newValue
          }
        }

        @GraphIgnored let $theme: UserDefaultsStored<String> = .init(name: "theme", suite: "com.example.app", key: "theme", defaultValue: "light")

      }
      """
    }
  }
  
  func test_userdefaults_storage_requires_default_value() {
    assertMacro {
      """
      final class Settings {
      
        @GraphStored(backed: .userDefaults(key: "value"))
        var value: Int

      }
      """
    } diagnostics: {
      """
      final class Settings {
      
        @GraphStored(backed: .userDefaults(key: "value"))
        ╰─ 🛑 @GraphStored with UserDefaults backing requires a default value
        var value: Int

      }
      """
    }
  }
  
  func test_userdefaults_storage_optional_with_nil_default() {
    assertMacro {
      """
      final class Settings {
      
        @GraphStored(backed: .userDefaults(key: "optionalValue"))
        var optionalValue: String? = nil

      }
      """
    } expansion: {
      """
      final class Settings {
        var optionalValue: String? {
          get {
            return $optionalValue.wrappedValue
          }
          set {
            $optionalValue.wrappedValue = newValue
          }
        }

        @GraphIgnored let $optionalValue: UserDefaultsStored<String?> = .init(name: "optionalValue", key: "optionalValue", defaultValue: nil)

      }
      """
    }
  }
  
  // MARK: - Mixed Usage Tests
  
  func test_mixed_storage_types() {
    assertMacro {
      """
      final class MixedModel {
      
        @GraphStored
        var memoryValue: Int = 0
        
        @GraphStored(backed: .userDefaults(key: "persistedValue"))
        var persistedValue: String = "default"

      }
      """
    } expansion: {
      """
      final class MixedModel {
        var memoryValue: Int {
          @storageRestrictions(
            accesses: $memoryValue
          )
          init(initialValue) {
            $memoryValue.wrappedValue = initialValue
          }
          get {
            return $memoryValue.wrappedValue
          }
          set {
            $memoryValue.wrappedValue = newValue
          }
        }

        @GraphIgnored let $memoryValue: Stored<Int> = .init(name: "memoryValue", wrappedValue: 0)

        var persistedValue: String {
          get {
            return $persistedValue.wrappedValue
          }
          set {
            $persistedValue.wrappedValue = newValue
          }
        }

        @GraphIgnored let $persistedValue: UserDefaultsStored<String> = .init(name: "persistedValue", key: "persistedValue", defaultValue: "default")

      }
      """
    }
  }

  // MARK: - Additional UserDefaults Tests (Edge Cases)
  
  func test_userdefaults_storage_with_all_parameters() {
    assertMacro {
      """
      final class Settings {
      
        @GraphStored(backed: .userDefaults(suite: "com.example.app", key: "api_url", name: "customApiUrl"))
        var apiUrl: String = "https://default.com"

      }
      """
    } expansion: {
      """
      final class Settings {
        var apiUrl: String {
          get {
            return $apiUrl.wrappedValue
          }
          set {
            $apiUrl.wrappedValue = newValue
          }
        }

        @GraphIgnored let $apiUrl: UserDefaultsStored<String> = .init(name: "customApiUrl", suite: "com.example.app", key: "api_url", defaultValue: "https://default.com")

      }
      """
    }
  }
  
  func test_userdefaults_storage_different_types() {
    assertMacro {
      """
      final class Settings {
      
        @GraphStored(backed: .userDefaults(key: "count"))
        var count: Int = 0
        
        @GraphStored(backed: .userDefaults(key: "isEnabled"))
        var isEnabled: Bool = false
        
        @GraphStored(backed: .userDefaults(key: "temperature"))
        var temperature: Double = 0.0

      }
      """
    } expansion: {
             """
       final class Settings {
         var count: Int {
           get {
             return $count.wrappedValue
           }
           set {
             $count.wrappedValue = newValue
           }
         }

         @GraphIgnored let $count: UserDefaultsStored<Int> = .init(name: "count", key: "count", defaultValue: 0)

         var isEnabled: Bool {
           get {
             return $isEnabled.wrappedValue
           }
           set {
             $isEnabled.wrappedValue = newValue
           }
         }

         @GraphIgnored let $isEnabled: UserDefaultsStored<Bool> = .init(name: "isEnabled", key: "isEnabled", defaultValue: false)

         var temperature: Double {
           get {
             return $temperature.wrappedValue
           }
           set {
             $temperature.wrappedValue = newValue
           }
         }

         @GraphIgnored let $temperature: UserDefaultsStored<Double> = .init(name: "temperature", key: "temperature", defaultValue: 0.0)

       }
       """
    }
  }

  func test_userdefaults_storage_access_control() {
    assertMacro {
      """
      final class Settings {
      
        @GraphStored(backed: .userDefaults(key: "publicValue"))
        public var publicValue: String = "default"
        
        @GraphStored(backed: .userDefaults(key: "privateValue"))
        private var privateValue: String = "default"

      }
      """
    } expansion: {
             """
       final class Settings {
         public var publicValue: String {
           get {
             return $publicValue.wrappedValue
           }
           set {
             $publicValue.wrappedValue = newValue
           }
         }

         @GraphIgnored
           public let $publicValue: UserDefaultsStored<String> = .init(name: "publicValue", key: "publicValue", defaultValue: "default")

         private var privateValue: String {
           get {
             return $privateValue.wrappedValue
           }
           set {
             $privateValue.wrappedValue = newValue
           }
         }

         @GraphIgnored
           private let $privateValue: UserDefaultsStored<String> = .init(name: "privateValue", key: "privateValue", defaultValue: "default")

       }
       """
    }
  }

  func test_userdefaults_storage_in_struct() {
    assertMacro {
      """
      struct Config {
      
        @GraphStored(backed: .userDefaults(key: "setting"))
        var setting: String = "default"

      }
      """
    } expansion: {
      """
      struct Config {
        var setting: String {
          get {
            return $setting.wrappedValue
          }
          nonmutating set {
            $setting.wrappedValue = newValue
          }
        }

        @GraphIgnored let $setting: UserDefaultsStored<String> = .init(name: "setting", key: "setting", defaultValue: "default")

      }
      """
    }
  }

  // MARK: - Legacy Tests (from MacroTests.swift)
  
  func test_optional_stored_property_with_init() {
    assertMacro {
      """
      final class Model {
      
        @GraphStored
        var count: Int? = 0

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

        @GraphIgnored let $count: Stored<Int?> = .init(name: "count", wrappedValue: 0)

      }
      """
    }
  }
  
  func test_optional_stored_property_with_implicit_init() {
    assertMacro {
      """
      final class Model {
      
        @GraphStored
        var count: Int?
      
        init() {
        
        }
      
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

        init() {
        
        }

      }
      """
    }
  }
  
  func test_weak_optional_stored_property_with_implicit_init() {
    assertMacro {
      """
      final class Model {
      
        @GraphStored
        weak var count: Ref?
      
        init() {
        
        }
      
      }
      """
    } diagnostics: {
      """
      final class Model {

        @GraphStored
        ╰─ 🛑 weak variables are not supported with @GraphStored
        weak var count: Ref?

        init() {
        
        }

      }
      """
    } 
  }
  
  func test_optional_init() {
    assertMacro {
      """
      final class Model {
      
        @GraphStored
        var count: Int?
      
        @GraphStored
        weak var weak_object: AnyObject?
              
      }
      """
    } diagnostics: {
      """
      final class Model {

        @GraphStored
        var count: Int?

        @GraphStored
        ╰─ 🛑 weak variables are not supported with @GraphStored
        weak var weak_object: AnyObject?
              
      }
      """
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

        init() {
        
        }

      }
      """
    }
  }
  
  func test_implicitly_unwrapped_optional() {
    assertMacro {
      """
      final class Model {
      
        @GraphStored
        var community: Community!
      
        init() {
        
        }
      
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

        init() {
        
        }

      }
      """
    }
  }
  
  func test_implicitly_unwrapped_optional_with_initializer() {
    assertMacro {
      """
      final class Model {
      
        @GraphStored
        var community: Community! = Community()
      
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

        @GraphIgnored let $community: Stored<Community?> = .init(name: "community", wrappedValue: Community())

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
    } diagnostics: {
      """
      public final class A {

        @GraphStored
        ╰─ 🛑 weak variables are not supported with @GraphStored
        public weak var weak_variable: AnyObject?             
        
        @GraphStored
        ╰─ 🛑 unowned variables are not supported with @GraphStored
        unowned var unowned_variable: AnyObject
        
        unowned let unowned_constant: AnyObject

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

    return try UnifiedStoredMacro.expansion(
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
