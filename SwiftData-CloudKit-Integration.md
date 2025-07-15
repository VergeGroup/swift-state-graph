# SwiftData + CloudKit Integration with GraphStored

This document explains how to use SwiftData with CloudKit as a backing store for `@GraphStored` properties, providing automatic synchronization across devices while maintaining synchronous access patterns.

## Overview

The SwiftData + CloudKit integration allows you to:
- Store `@GraphStored` properties in a local SQLite database (via SwiftData)
- Automatically sync changes to CloudKit in the background
- Maintain synchronous read/write semantics (no async/await required)
- Get automatic conflict resolution and merge handling
- Support complex Codable types with JSON serialization

## Setup

### 1. CloudKit Entitlements

In Xcode, enable CloudKit for your app:
1. Go to **Signing & Capabilities**
2. Add **CloudKit** capability
3. Create or select a CloudKit container

### 2. SwiftData Container Setup

```swift
import SwiftData
import StateGraph

@MainActor
class SwiftDataManager: ObservableObject {
    static let shared = SwiftDataManager()
    
    let container: ModelContainer
    let context: ModelContext
    
    private init() {
        do {
            // Create schema with CloudKit sync enabled
            let schema = Schema([KVBlob.self])
            let config = ModelConfiguration(
                schema: schema,
                cloudKitDatabase: .automatic  // Enables CloudKit sync
            )
            
            self.container = try ModelContainer(
                for: schema,
                configurations: [config]
            )
            self.context = container.mainContext
        } catch {
            fatalError("Failed to create SwiftData container: \(error)")
        }
    }
}

// Global access to model context
var globalModelContext: ModelContext {
    SwiftDataManager.shared.context
}
```

### 3. Custom Types

Define your custom types conforming to `SwiftDataStorable`:

```swift
struct UserSettings: SwiftDataStorable {
    var theme: String
    var fontSize: Double
    var notificationsEnabled: Bool
    
    init(theme: String = "light", fontSize: Double = 16.0, notificationsEnabled: Bool = true) {
        self.theme = theme
        self.fontSize = fontSize
        self.notificationsEnabled = notificationsEnabled
    }
}
```

## Usage

### Basic Usage

```swift
final class AppSettingsModel {
    // These values automatically sync to CloudKit
    @GraphStored(backed: .swiftData(key: "userSettings"))
    var userSettings: UserSettings = UserSettings()
    
    @GraphStored(backed: .swiftData(key: "selectedCalendar"))
    var selectedCalendar: String = ""
    
    @GraphStored(backed: .swiftData(key: "darkMode"))
    var darkMode: Bool = false
    
    // Computed properties work seamlessly with SwiftData backing
    @GraphComputed
    var isDarkTheme: Bool
    
    init() {
        self.$isDarkTheme = .init { [$darkMode, $userSettings] _ in
            $darkMode.wrappedValue || $userSettings.wrappedValue.theme == "dark"
        }
    }
}
```

### SwiftUI Integration

```swift
struct SettingsView: View {
    @State private var settingsModel = AppSettingsModel()
    
    var body: some View {
        Form {
            Toggle("Dark Mode", isOn: settingsModel.$darkMode.binding)
            
            TextField("Calendar", text: settingsModel.$selectedCalendar.binding)
            
            // Complex type binding
            Slider(
                value: Binding(
                    get: { settingsModel.userSettings.fontSize },
                    set: { newValue in
                        var settings = settingsModel.userSettings
                        settings.fontSize = newValue
                        settingsModel.userSettings = settings
                    }
                ),
                in: 12...32
            )
        }
        .preferredColorScheme(settingsModel.isDarkTheme ? .dark : .light)
    }
}
```

### App Setup

```swift
@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            SettingsView()
                .modelContainer(SwiftDataManager.shared.container)
        }
    }
}
```

## How It Works

### Architecture

1. **Local Storage**: Values are stored in SQLite via SwiftData's `KVBlob` model
2. **JSON Serialization**: Complex types are JSON-encoded for storage
3. **CloudKit Sync**: SwiftData automatically mirrors changes to CloudKit
4. **Change Notifications**: SwiftData change notifications trigger graph updates
5. **Conflict Resolution**: CloudKit handles merge conflicts automatically

### Data Flow

```
@GraphStored Property
    ↓ (write)
SwiftDataStorage
    ↓ (JSON encode)
KVBlob (SQLite)
    ↓ (automatic)
CloudKit Private Database
    ↓ (sync to other devices)
Other Device KVBlob
    ↓ (change notification)
SwiftDataStorage
    ↓ (JSON decode)
@GraphStored Property
```

## Supported Types

### Built-in Types
- `Bool`, `Int`, `Double`, `String`, `Data`, `Date`
- `Array<T>` where `T: SwiftDataStorable`
- `Dictionary<String, T>` where `T: SwiftDataStorable`
- `Optional<T>` where `T: SwiftDataStorable`

### Custom Types
Any type conforming to `SwiftDataStorable` (which requires `Codable`, `Sendable`, `Equatable`):

```swift
struct AppConfiguration: SwiftDataStorable {
    var apiEndpoint: String
    var maxRetries: Int
    var enableAnalytics: Bool
}
```

## Advanced Features

### Custom JSON Encoding

```swift
struct CustomType: SwiftDataStorable {
    var value: String
    
    static var jsonEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
    
    static var jsonDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
```

### Multiple Containers

```swift
// Different data domains can use different containers
@GraphStored(backed: .swiftData(key: "userPrefs"))
var userPrefs: UserSettings = UserSettings()

@GraphStored(backed: .swiftData(key: "appConfig"))
var appConfig: AppConfiguration = AppConfiguration()
```

## Performance Considerations

### Advantages
- **Local-first**: All reads/writes are synchronous SQLite operations
- **Automatic caching**: SwiftDataStorage caches values in memory
- **Efficient updates**: Only changed values trigger CloudKit syncs
- **Background sync**: CloudKit operations never block the UI

### Best Practices
- Use descriptive, unique keys to avoid conflicts
- Keep individual values reasonably sized (< 1MB per key)
- Group related settings into structs rather than many individual properties
- Consider using different containers for different data domains

## Error Handling

The SwiftData integration handles errors gracefully:

```swift
private func saveValue(_ value: Value) {
    do {
        // Save to SwiftData
        try modelContext.save()
    } catch {
        // Graceful degradation - logs error but doesn't crash
        print("SwiftDataStorage saveValue error: \(error)")
    }
}
```

## Migration from UserDefaults

Migrating from UserDefaults backing is straightforward:

```swift
// Before
@GraphStored(backed: .userDefaults(key: "theme"))
var theme: String = "light"

// After
@GraphStored(backed: .swiftData(key: "theme"))
var theme: String = "light"
```

## Troubleshooting

### Common Issues

1. **CloudKit not syncing**: Ensure CloudKit entitlements are properly configured
2. **Predicate errors**: Use local variables in #Predicate, not self properties
3. **Type errors**: Ensure all stored types conform to `SwiftDataStorable`
4. **Context issues**: Ensure global ModelContext is properly initialized

### Debugging

```swift
// Enable verbose SwiftData logging
let config = ModelConfiguration(
    schema: schema,
    cloudKitDatabase: .automatic,
    debugLogging: true
)
```

## Conclusion

The SwiftData + CloudKit integration provides a powerful, local-first approach to reactive state management with automatic cloud synchronization. It maintains the synchronous semantics that make `@GraphStored` properties easy to use while providing robust background sync capabilities.

The integration is designed to be:
- **Simple**: Minimal setup required
- **Performant**: Local SQLite operations with background sync
- **Reliable**: Built on proven Apple technologies
- **Scalable**: Supports complex types and large datasets 