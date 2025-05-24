import MacroTesting
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest
@testable import StateGraphMacro

final class UserDefaultsStoredMacroTests: XCTestCase {
  
  override func invokeTest() {
    withMacroTesting(
      record: false,
      macros: [
        "UserDefaultsStored": UserDefaultsStoredMacro.self,
      ]
    ) {
      super.invokeTest()
    }
  }

  func test_basic_userdefaults_stored_property() {
    assertMacro {
      """
      final class Settings {
      
        @UserDefaultsStored(key: "username")
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

        @GraphIgnored let $username: UserDefaultsStored<String> = .init(group: "Settings", name: "username", key: "username", defaultValue: "anonymous")

      }
      """
    }
  }
  
  func test_userdefaults_stored_with_suite() {
    assertMacro {
      """
      final class Settings {
      
        @UserDefaultsStored(suite: "com.example.app", key: "theme")
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

        @GraphIgnored let $theme: UserDefaultsStored<String> = .init(group: "Settings", name: "theme", suite: "com.example.app", key: "theme", defaultValue: "light")

      }
      """
    }
  }
  

  
  func test_userdefaults_stored_int_value() {
    assertMacro {
      """
      final class Settings {
      
        @UserDefaultsStored(key: "maxRetries")
        var maxRetries: Int = 3

      }
      """
    } expansion: {
      """
      final class Settings {
        var maxRetries: Int {
          get {
            return $maxRetries.wrappedValue
          }
          set {
            $maxRetries.wrappedValue = newValue
          }
        }

        @GraphIgnored let $maxRetries: UserDefaultsStored<Int> = .init(group: "Settings", name: "maxRetries", key: "maxRetries", defaultValue: 3)

      }
      """
    }
  }
} 