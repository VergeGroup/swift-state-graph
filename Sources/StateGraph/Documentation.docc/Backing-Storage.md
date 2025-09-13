# Backing Storage

Flexible storage options for persisting your reactive state beyond memory.

## Overview

Swift State Graph provides a powerful backing storage system that allows you to persist your state in various storage backends while maintaining full reactivity and automatic dependency tracking. By default, all `@GraphStored` properties use in-memory storage, but you can easily configure them to use persistent storage like UserDefaults.

## Storage Types

The framework supports multiple storage backends through the `GraphStorageBacking` enumeration:

### In-Memory Storage (Default)

The default storage type keeps values in memory only:

```swift
final class ViewModel {
  @GraphStored var count: Int = 0
  // Equivalent to:
  // @GraphStored(backed: .memory) var count: Int = 0
}
```

### UserDefaults Storage

Store values in UserDefaults for automatic persistence across app launches:

```swift
final class SettingsModel {
  // Basic UserDefaults storage with key
  @GraphStored(backed: .userDefaults(key: "theme"))
  var theme: String = "light"
  
  // UserDefaults storage with custom suite
  @GraphStored(backed: .userDefaults(suite: "com.myapp.settings", key: "apiEndpoint"))
  var apiEndpoint: String = "https://api.production.com"
}
```

## Reactive Persistence

Backing storage integrates seamlessly with Swift State Graph's reactive system. Changes to backed properties automatically trigger updates to dependent computed properties and persist to the storage backend.

### Basic Example

```swift
final class UserPreferencesModel {
  @GraphStored(backed: .userDefaults(key: "userName"))
  var userName: String = ""
  
  @GraphStored(backed: .userDefaults(key: "fontSize"))
  var fontSize: Double = 16.0
  
  @GraphComputed
  var displayName: String
  
  @GraphComputed
  var accessibilityFontSize: Double
  
  init() {
    // Computed properties work with backed storage
    self.$displayName = .init { [$userName] _ in
      let name = $userName.wrappedValue
      return name.isEmpty ? "Anonymous User" : name
    }
    
    self.$accessibilityFontSize = .init { [$fontSize] _ in
      max(12.0, min(32.0, $fontSize.wrappedValue))
    }
  }
}
```

### Complex State Management

```swift
final class AppConfigurationModel {
  // Feature flags
  @GraphStored(backed: .userDefaults(key: "enableExperimentalFeatures"))
  var enableExperimentalFeatures: Bool = false
  
  @GraphStored(backed: .userDefaults(key: "debugMode"))
  var debugMode: Bool = false
  
  // User preferences
  @GraphStored(backed: .userDefaults(suite: "com.myapp.preferences", key: "notificationsEnabled"))
  var notificationsEnabled: Bool = true
  
  @GraphStored(backed: .userDefaults(suite: "com.myapp.preferences", key: "autoSaveInterval"))
  var autoSaveInterval: TimeInterval = 300 // 5 minutes
  
  // Derived configuration
  @GraphComputed
  var shouldShowDebugOptions: Bool
  
  @GraphComputed
  var effectiveAutoSaveInterval: TimeInterval
  
  init() {
    self.$shouldShowDebugOptions = .init { [$debugMode, $enableExperimentalFeatures] _ in
      $debugMode.wrappedValue || $enableExperimentalFeatures.wrappedValue
    }
    
    self.$effectiveAutoSaveInterval = .init { [$autoSaveInterval, $debugMode] _ in
      // Faster auto-save in debug mode
      $debugMode.wrappedValue ? 60.0 : $autoSaveInterval.wrappedValue
    }
  }
}
```

## SwiftUI Integration

Backed properties work seamlessly with SwiftUI's binding system:

### Settings Screen Example

```swift
struct SettingsView: View {
  let model: AppConfigurationModel
  
  var body: some View {
    NavigationView {
      Form {
        Section("Debug") {
          Toggle("Debug Mode", isOn: model.$debugMode.binding)
          Toggle("Experimental Features", isOn: model.$enableExperimentalFeatures.binding)
          
          if model.shouldShowDebugOptions {
            Text("Debug options are available")
              .foregroundColor(.orange)
          }
        }
        
        Section("Preferences") {
          Toggle("Notifications", isOn: model.$notificationsEnabled.binding)
          
          VStack(alignment: .leading) {
            Text("Auto-save interval: \(Int(model.autoSaveInterval)) seconds")
            Slider(
              value: model.$autoSaveInterval.binding,
              in: 60...600,
              step: 60
            )
          }
          
          Text("Effective interval: \(Int(model.effectiveAutoSaveInterval)) seconds")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }
      .navigationTitle("Settings")
    }
  }
}
```

### Data Synchronization

```swift
struct UserProfileView: View {
 　let preferences: UserPreferencesModel
  
  var body: some View {
    VStack(spacing: 20) {
      // User name input - automatically persisted
      TextField("Enter your name", text: preferences.$userName.binding)
        .textFieldStyle(.roundedBorder)
      
      // Display name updates reactively
      Text("Hello, \(preferences.displayName)!")
        .font(.title)
      
      // Font size control
      VStack {
        Text("Font Size")
        Slider(value: preferences.$fontSize.binding, in: 12...32, step: 1)
        Text("Sample text at \(Int(preferences.fontSize))pt")
          .font(.system(size: preferences.accessibilityFontSize))
      }
    }
    .padding()
  }
}
```

## Advanced Patterns

### State Restoration

Use backing storage to restore application state across launches:

```swift
final class DocumentEditorModel {
  @GraphStored(backed: .userDefaults(key: "lastOpenedDocument"))
  var lastOpenedDocumentPath: String? = nil
  
  @GraphStored(backed: .userDefaults(key: "editorSettings"))
  var editorSettings: [String: Any] = [:]
  
  @GraphStored
  var currentDocument: Document? = nil
  
  @GraphComputed
  var canRestoreSession: Bool
  
  init() {
    self.$canRestoreSession = .init { [$lastOpenedDocumentPath, $currentDocument] _ in
      $lastOpenedDocumentPath.wrappedValue != nil && $currentDocument.wrappedValue == nil
    }
    
    // Automatically restore session on launch
    if canRestoreSession, let path = lastOpenedDocumentPath {
      loadDocument(at: path)
    }
  }
  
  func saveDocument(_ document: Document, at path: String) {
    currentDocument = document
    lastOpenedDocumentPath = path
    // lastOpenedDocumentPath is automatically persisted to UserDefaults
  }
  
  private func loadDocument(at path: String) {
    // Load document implementation
  }
}
```

### Configuration Management

```swift
final class NetworkConfigurationModel {
  // Environment-specific settings
  @GraphStored(backed: .userDefaults(suite: "com.myapp.network", key: "environment"))
  var environment: String = "production"
  
  @GraphStored(backed: .userDefaults(suite: "com.myapp.network", key: "customEndpoints"))
  var customEndpoints: [String: String] = [:]
  
  @GraphStored(backed: .userDefaults(suite: "com.myapp.network", key: "timeoutInterval"))
  var timeoutInterval: TimeInterval = 30.0
  
  // Computed configuration
  @GraphComputed
  var apiBaseURL: String
  
  @GraphComputed
  var requestConfiguration: URLSessionConfiguration
  
  init() {
    self.$apiBaseURL = .init { [$environment, $customEndpoints] _ in
      let env = $environment.wrappedValue
      let endpoints = $customEndpoints.wrappedValue
      
      // Check for custom endpoint first
      if let customURL = endpoints[env] {
        return customURL
      }
      
      // Default endpoints
      switch env {
      case "development":
        return "https://api-dev.myapp.com"
      case "staging":
        return "https://api-staging.myapp.com"
      case "production":
        return "https://api.myapp.com"
      default:
        return "https://api.myapp.com"
      }
    }
    
    self.$requestConfiguration = .init { [$timeoutInterval] _ in
      let config = URLSessionConfiguration.default
      config.timeoutIntervalForRequest = $timeoutInterval.wrappedValue
      config.timeoutIntervalForResource = $timeoutInterval.wrappedValue * 2
      return config
    }
  }
}
```

## Type Support

Backing storage supports any type that can be stored in UserDefaults:

### Supported Types

- **Primitive types**: `Bool`, `Int`, `Double`, `String`
- **Collections**: `Array`, `Dictionary`, `Set` (with supported element types)
- **Optional types**: Any supported type wrapped in `Optional`
- **Codable types**: Custom types that conform to `Codable`

### Custom Type Example

```swift
struct UserTheme: Codable {
  let name: String
  let primaryColor: String
  let accentColor: String
}

final class ThemeModel {
  @GraphStored(backed: UserDefaultsMarker.userDefaults(key: "selectedTheme"))
  var selectedTheme: UserTheme = UserTheme(
    name: "Default",
    primaryColor: "#007AFF",
    accentColor: "#FF9500"
  )
  
  @GraphComputed
  var isDarkTheme: Bool
  
  init() {
    self.$isDarkTheme = .init { [$selectedTheme] _ in
      $selectedTheme.wrappedValue.name.lowercased().contains("dark")
    }
  }
}
```

## Performance Considerations

### Efficient Updates

Backing storage only persists values when they actually change:

```swift
final class PerformanceOptimizedModel {
  @GraphStored(backed: .userDefaults(key: "counter"))
  var counter: Int = 0
  
  func incrementIfNeeded() {
    let newValue = counter + 1
    if newValue != counter {
      counter = newValue  // Only persists if value actually changes
    }
  }
}
```

### Batch Updates

For multiple related changes, consider grouping them:

```swift
final class ProfileModel {
  @GraphStored(backed: .userDefaults(key: "firstName"))
  var firstName: String = ""
  
  @GraphStored(backed: .userDefaults(key: "lastName"))
  var lastName: String = ""
  
  @GraphStored(backed: .userDefaults(key: "email"))
  var email: String = ""
  
  func updateProfile(firstName: String, lastName: String, email: String) {
    // These updates will be batched efficiently
    self.firstName = firstName
    self.lastName = lastName
    self.email = email
  }
}
```

## Testing

Backing storage makes testing easier by providing predictable persistence:

```swift
import XCTest
@testable import YourApp

class BackingStorageTests: XCTestCase {
  
  func testUserPreferencesPersistence() {
    let model = UserPreferencesModel()
    
    // Change a value
    model.userName = "Test User"
    
    // Create a new instance - should restore the persisted value
    let newModel = UserPreferencesModel()
    XCTAssertEqual(newModel.userName, "Test User")
    
    // Computed properties work with persisted values
    XCTAssertEqual(newModel.displayName, "Test User")
  }
  
  func testComputedPropertiesWithBackingStorage() {
    let config = AppConfigurationModel()
    
    // Test initial state
    XCTAssertFalse(config.shouldShowDebugOptions)
    
    // Enable debug mode
    config.debugMode = true
    XCTAssertTrue(config.shouldShowDebugOptions)
    
    // Verify persistence
    let newConfig = AppConfigurationModel()
    XCTAssertTrue(newConfig.debugMode)
    XCTAssertTrue(newConfig.shouldShowDebugOptions)
  }
  
  override func tearDown() {
    // Clean up UserDefaults after tests
    let defaults = UserDefaults.standard
    defaults.removeObject(forKey: "userName")
    defaults.removeObject(forKey: "debugMode")
    // ... remove other test keys
    super.tearDown()
  }
}
```

## Best Practices

### Naming Conventions

Use descriptive keys that won't conflict with other parts of your app:

```swift
final class FeatureModel {
  // ✅ Good: Descriptive, namespaced keys
  @GraphStored(backed: .userDefaults(key: "com.myapp.feature.isEnabled"))
  var isEnabled: Bool = false
  
  @GraphStored(backed: .userDefaults(suite: "com.myapp.features", key: "experimentalMode"))
  var experimentalMode: Bool = false
  
  // ❌ Avoid: Generic keys that might conflict
  // @GraphStored(backed: .userDefaults(key: "enabled"))
  // var isEnabled: Bool = false
}
```

### Suites for Organization

Use UserDefaults suites to organize related settings:

```swift
final class OrganizedSettingsModel {
  // UI preferences
  @GraphStored(backed: .userDefaults(suite: "com.myapp.ui", key: "theme"))
  var theme: String = "auto"
  
  @GraphStored(backed: .userDefaults(suite: "com.myapp.ui", key: "compactMode"))
  var compactMode: Bool = false
  
  // Network settings
  @GraphStored(backed: .userDefaults(suite: "com.myapp.network", key: "cachePolicy"))
  var cachePolicy: String = "automatic"
  
  @GraphStored(backed: .userDefaults(suite: "com.myapp.network", key: "timeout"))
  var timeout: TimeInterval = 30.0
}
```

### Default Values

Always provide sensible default values:

```swift
final class RobustSettingsModel {
  @GraphStored(backed: .userDefaults(key: "maxRetries"))
  var maxRetries: Int = 3  // Sensible default
  
  @GraphStored(backed: .userDefaults(key: "serverURL"))
  var serverURL: String = "https://api.myapp.com"  // Production default
  
  @GraphStored(backed: .userDefaults(key: "enableAnalytics"))
  var enableAnalytics: Bool = true  // Opt-in by default
}
```

Backing storage in Swift State Graph provides a powerful way to persist your reactive state while maintaining the framework's key benefits of automatic dependency tracking and reactive updates. 