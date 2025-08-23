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
          private let $value: _Stored<InMemoryStorage<Int>> = _Stored(storage: .memory, value: 0)
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
          private let $value: _Stored<InMemoryStorage<Int>> = _Stored(storage: .memory, value: 0)
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

        @GraphIgnored let $count: _Stored<InMemoryStorage<Int>> = _Stored(storage: .memory, value: 0)

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

        @GraphIgnored let $count: _Stored<InMemoryStorage<Int>> = _Stored(storage: .memory, value: 0)

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

        @GraphIgnored let $count: _Stored<InMemoryStorage<Int?>> = _Stored(storage: .memory, value: nil)

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

        @GraphIgnored let $username: _Stored<UserDefaultsStorage<String>> = _Stored(storage: .userDefaults(key: "username"), value: "anonymous")

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

        @GraphIgnored let $theme: _Stored<UserDefaultsStorage<String>> = _Stored(storage: .userDefaults(suite: "com.example.app", key: "theme"), value: "light")

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

        @GraphIgnored let $optionalValue: _Stored<UserDefaultsStorage<String?>> = _Stored(storage: .userDefaults(key: "optionalValue"), value: nil)

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

        @GraphIgnored let $memoryValue: _Stored<InMemoryStorage<Int>> = _Stored(storage: .memory, value: 0)

        var persistedValue: String {
          get {
            return $persistedValue.wrappedValue
          }
          set {
            $persistedValue.wrappedValue = newValue
          }
        }

        @GraphIgnored let $persistedValue: _Stored<UserDefaultsStorage<String>> = _Stored(storage: .userDefaults(key: "persistedValue"), value: "default")

      }
      """
    }
  }

  // MARK: - Additional UserDefaults Tests (Edge Cases)
  
  func test_userdefaults_storage_with_suite_and_key() {
    assertMacro {
      """
      final class Settings {
      
        @GraphStored(backed: .userDefaults(suite: "com.example.app", key: "api_url"))
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

        @GraphIgnored let $apiUrl: _Stored<UserDefaultsStorage<String>> = _Stored(storage: .userDefaults(suite: "com.example.app", key: "api_url"), value: "https://default.com")

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

         @GraphIgnored let $count: _Stored<UserDefaultsStorage<Int>> = _Stored(storage: .userDefaults(key: "count"), value: 0)

         var isEnabled: Bool {
           get {
             return $isEnabled.wrappedValue
           }
           set {
             $isEnabled.wrappedValue = newValue
           }
         }

         @GraphIgnored let $isEnabled: _Stored<UserDefaultsStorage<Bool>> = _Stored(storage: .userDefaults(key: "isEnabled"), value: false)

         var temperature: Double {
           get {
             return $temperature.wrappedValue
           }
           set {
             $temperature.wrappedValue = newValue
           }
         }

         @GraphIgnored let $temperature: _Stored<UserDefaultsStorage<Double>> = _Stored(storage: .userDefaults(key: "temperature"), value: 0.0)

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
           public let $publicValue: _Stored<UserDefaultsStorage<String>> = _Stored(storage: .userDefaults(key: "publicValue"), value: "default")

         private var privateValue: String {
           get {
             return $privateValue.wrappedValue
           }
           set {
             $privateValue.wrappedValue = newValue
           }
         }

         @GraphIgnored
           private let $privateValue: _Stored<UserDefaultsStorage<String>> = _Stored(storage: .userDefaults(key: "privateValue"), value: "default")

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

        @GraphIgnored let $setting: _Stored<UserDefaultsStorage<String>> = _Stored(storage: .userDefaults(key: "setting"), value: "default")

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

        @GraphIgnored let $count: _Stored<InMemoryStorage<Int?>> = _Stored(storage: .memory, value: 0)

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

        @GraphIgnored let $count: _Stored<InMemoryStorage<Int?>> = _Stored(storage: .memory, value: nil)

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

        @GraphIgnored let $count: _Stored<InMemoryStorage<Int>> = _Stored(storage: .memory, value: 0)

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

        @GraphIgnored let $community: _Stored<InMemoryStorage<Community?>> = _Stored(storage: .memory, value: nil)

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

        @GraphIgnored let $community: _Stored<InMemoryStorage<Community?>> = _Stored(storage: .memory, value: Community())

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
} 
