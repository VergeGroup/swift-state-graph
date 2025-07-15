import SwiftUI
import SwiftData
import StateGraph

// MARK: - SwiftData + CloudKit Setup

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
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

// MARK: - Global Model Context Access

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
var globalModelContext: ModelContext {
    SwiftDataManager.shared.context
}

// MARK: - Example Models

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
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

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
final class AppSettingsModel {
    // These values automatically sync to CloudKit
    @GraphStored(backed: .swiftData(key: "userSettings"))
    var userSettings: UserSettings = UserSettings()
    
    @GraphStored(backed: .swiftData(key: "selectedCalendar"))
    var selectedCalendar: String = ""
    
    @GraphStored(backed: .swiftData(key: "darkMode"))
    var darkMode: Bool = false
    
    @GraphStored(backed: .swiftData(key: "autoSync"))
    var autoSync: Bool = true
    
    // Computed properties work seamlessly with SwiftData backing
    @GraphComputed
    var isDarkTheme: Bool
    
    @GraphComputed
    var accessibilityFontSize: Double
    
    @GraphComputed
    var displayName: String
    
    init() {
        self.$isDarkTheme = .init { [$darkMode, $userSettings] _ in
            $darkMode.wrappedValue || $userSettings.wrappedValue.theme == "dark"
        }
        
        self.$accessibilityFontSize = .init { [$userSettings] _ in
            max(12.0, min(32.0, $userSettings.wrappedValue.fontSize))
        }
        
        self.$displayName = .init { [$selectedCalendar] _ in
            let calendar = $selectedCalendar.wrappedValue
            return calendar.isEmpty ? "Default Calendar" : calendar
        }
    }
}

// MARK: - SwiftUI Integration

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
struct SwiftDataExampleView: View {
    @State private var settingsModel = AppSettingsModel()
    
    var body: some View {
        NavigationView {
            Form {
                Section("Appearance") {
                    Toggle("Dark Mode", isOn: settingsModel.$darkMode.binding)
                    
                    VStack(alignment: .leading) {
                        Text("Font Size: \(settingsModel.userSettings.fontSize, specifier: "%.1f")")
                        Slider(
                            value: Binding(
                                get: { settingsModel.userSettings.fontSize },
                                set: { newValue in
                                    var settings = settingsModel.userSettings
                                    settings.fontSize = newValue
                                    settingsModel.userSettings = settings
                                }
                            ),
                            in: 12...32,
                            step: 1
                        )
                        Text("Accessibility Size: \(settingsModel.accessibilityFontSize, specifier: "%.1f")")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Section("Sync") {
                    Toggle("Auto Sync", isOn: settingsModel.$autoSync.binding)
                    Toggle("Notifications", isOn: Binding(
                        get: { settingsModel.userSettings.notificationsEnabled },
                        set: { newValue in
                            var settings = settingsModel.userSettings
                            settings.notificationsEnabled = newValue
                            settingsModel.userSettings = settings
                        }
                    ))
                }
                
                Section("Calendar") {
                    TextField("Calendar Name", text: settingsModel.$selectedCalendar.binding)
                    Text("Display: \(settingsModel.displayName)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Section("Theme Info") {
                    Text("Is Dark Theme: \(settingsModel.isDarkTheme ? "Yes" : "No")")
                    Text("Current Theme: \(settingsModel.userSettings.theme)")
                }
            }
            .navigationTitle("SwiftData + CloudKit Example")
        }
        .preferredColorScheme(settingsModel.isDarkTheme ? .dark : .light)
    }
}

// MARK: - App Setup

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
struct SwiftDataExampleApp: App {
    var body: some Scene {
        WindowGroup {
            SwiftDataExampleView()
                .modelContainer(SwiftDataManager.shared.container)
        }
    }
}

// MARK: - Usage Notes

/*
 
 ## SwiftData + CloudKit Integration with GraphStored
 
 This example demonstrates the complete integration of SwiftData with CloudKit 
 for GraphStored properties. Here's what happens:
 
 ### 1. Setup
 - Create a SwiftData ModelContainer with CloudKit sync enabled
 - Use the KVBlob model to store JSON-encoded values
 - Access through a global ModelContext
 
 ### 2. Usage
 - Use @GraphStored(backed: .swiftData(key: "keyName")) for properties
 - Values are automatically serialized to JSON and stored in SwiftData
 - SwiftData automatically syncs changes to CloudKit
 - Changes from other devices are automatically merged and propagated
 
 ### 3. Benefits
 - **Local-first**: All reads/writes are instant SQLite operations
 - **Automatic sync**: CloudKit handles background synchronization
 - **Conflict resolution**: SwiftData manages merge conflicts
 - **Reactive**: Changes automatically propagate through the graph
 - **Type-safe**: Full Codable support for complex types
 
 ### 4. CloudKit Setup Requirements
 - Enable CloudKit capability in your app
 - Add CloudKit container to your entitlements
 - SwiftData handles the rest automatically
 
 ### 5. Performance
 - Synchronous read/write operations (no async/await needed)
 - Automatic caching and change notifications
 - Efficient JSON serialization for complex types
 - Background CloudKit sync doesn't block UI
 
 */ 