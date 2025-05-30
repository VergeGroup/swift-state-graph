import MacroTesting
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
          set {
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
    } expansion: {
      """
      final class Model {
        weak var count: Ref? {
          @storageRestrictions(
            accesses: $count
          )
          init(initialValue) {
            $count.wrappedValue.value = initialValue
          }
          get {
            return $count.wrappedValue.value
          }
          set {
            $count.wrappedValue.value = newValue
          }
        }

        @GraphIgnored let $count: Stored<Weak<Ref>> = .init(name: "count", wrappedValue: .init(nil))

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
        weak var weak_object: AnyObject? {
          @storageRestrictions(
            accesses: $weak_object
          )
          init(initialValue) {
            $weak_object.wrappedValue.value = initialValue
          }
          get {
            return $weak_object.wrappedValue.value
          }
          set {
            $weak_object.wrappedValue.value = newValue
          }
        }

        @GraphIgnored let $weak_object: Stored<Weak<AnyObject>> = .init(name: "weak_object", wrappedValue: .init(nil))
              
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
    } expansion: {
      """
      public final class A {
        public weak var weak_variable: AnyObject? {             
          @storageRestrictions(
            accesses: $weak_variable
          )
          init(initialValue) {
            $weak_variable.wrappedValue.value = initialValue
          }
          get {
            return $weak_variable.wrappedValue.value
          }
          set {
            $weak_variable.wrappedValue.value = newValue
          }
        }

        @GraphIgnored
          public let $weak_variable: Stored<Weak<AnyObject>> = .init(name: "weak_variable", wrappedValue: .init(nil))

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
