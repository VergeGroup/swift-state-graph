import Foundation

#if canImport(SwiftData)
import SwiftData
#endif

// MARK: - KVBlob SwiftData Model

#if canImport(SwiftData)
@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
@Model
public final class KVBlob {
    @Attribute(.unique)
    public var key: String
    
    public var data: Data
    public var updatedAt: Date
    
    public init(key: String, data: Data) {
        self.key = key
        self.data = data
        self.updatedAt = Date()
    }
}

// MARK: - SwiftData Storable Protocol

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
public protocol SwiftDataStorable: Codable, Sendable, Equatable {
    static var jsonEncoder: JSONEncoder { get }
    static var jsonDecoder: JSONDecoder { get }
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension SwiftDataStorable {
    public static var jsonEncoder: JSONEncoder { JSONEncoder() }
    public static var jsonDecoder: JSONDecoder { JSONDecoder() }
}

// MARK: - SwiftDataStorage Implementation

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
public final class SwiftDataStorage<Value: SwiftDataStorable>: Storage, Sendable {
    
    private let key: String
    private let defaultValue: Value
    
    nonisolated(unsafe)
    private let modelContext: ModelContext
    
    nonisolated(unsafe)
    private var cachedValue: Value?
    
    nonisolated(unsafe)
    private var subscription: NSObjectProtocol?
    
    public var value: Value {
        get {
            if let cachedValue {
                return cachedValue
            }
            
            let loadedValue = loadValue()
            cachedValue = loadedValue
            return loadedValue
        }
        set {
            cachedValue = newValue
            saveValue(newValue)
        }
    }
    
    public init(
        key: String,
        defaultValue: Value,
        modelContext: ModelContext
    ) {
        self.key = key
        self.defaultValue = defaultValue
        self.modelContext = modelContext
    }
    
    public func loaded(context: StorageContext) {
        // Subscribe to SwiftData changes
        subscription = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave,
            object: modelContext,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            
            // Check if our key was updated
            let previousValue = self.cachedValue
            self.cachedValue = nil
            let newValue = self.value
            
            guard previousValue != newValue else { return }
            
            context.notifyStorageUpdated()
        }
    }
    
    public func unloaded() {
        guard let subscription else { return }
        NotificationCenter.default.removeObserver(subscription)
        self.subscription = nil
    }
    
    // MARK: - Private Methods
    
    private func loadValue() -> Value {
        do {
            let keyToFind = self.key
            let descriptor = FetchDescriptor<KVBlob>(
                predicate: #Predicate { $0.key == keyToFind }
            )
            
            let results = try modelContext.fetch(descriptor)
            
            if let blob = results.first {
                return try Value.jsonDecoder.decode(Value.self, from: blob.data)
            }
            
            return defaultValue
        } catch {
            return defaultValue
        }
    }
    
    private func saveValue(_ value: Value) {
        do {
            let encoder = Value.jsonEncoder
            let data = try encoder.encode(value)
            
            let keyToFind = self.key
            let descriptor = FetchDescriptor<KVBlob>(
                predicate: #Predicate { $0.key == keyToFind }
            )
            
            let results = try modelContext.fetch(descriptor)
            
            let blob: KVBlob
            if let existingBlob = results.first {
                blob = existingBlob
            } else {
                blob = KVBlob(key: key, data: data)
                modelContext.insert(blob)
            }
            
            blob.data = data
            blob.updatedAt = Date()
            
            try modelContext.save()
        } catch {
            // Handle error gracefully - could log or provide fallback
            print("SwiftDataStorage saveValue error: \(error)")
        }
    }
}

// MARK: - Convenience Extensions

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension Bool: SwiftDataStorable {}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension Int: SwiftDataStorable {}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension Double: SwiftDataStorable {}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension String: SwiftDataStorable {}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension Data: SwiftDataStorable {}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension Date: SwiftDataStorable {}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension Array: SwiftDataStorable where Element: SwiftDataStorable {}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension Dictionary: SwiftDataStorable where Key == String, Value: SwiftDataStorable {}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension Optional: SwiftDataStorable where Wrapped: SwiftDataStorable {}

// MARK: - SwiftDataStored Typealias

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
public typealias SwiftDataStored<Value: SwiftDataStorable> = _Stored<Value, SwiftDataStorage<Value>>

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension _Stored where S == SwiftDataStorage<Value> {
    /// Initializes a SwiftDataStored node.
    ///
    /// - Parameters:
    ///   - file: The file where the node is created (defaults to current file)
    ///   - line: The line number where the node is created (defaults to current line)
    ///   - column: The column number where the node is created (defaults to current column)
    ///   - name: The name of the node (defaults to nil)
    ///   - key: The SwiftData key to store the value
    ///   - defaultValue: The default value if no value exists in SwiftData
    ///   - modelContext: The SwiftData ModelContext
    public convenience init(
        _ file: StaticString = #fileID,
        _ line: UInt = #line,
        _ column: UInt = #column,
        name: StaticString? = nil,
        key: String,
        defaultValue: Value,
        modelContext: ModelContext
    ) {
        let storage = SwiftDataStorage(
            key: key,
            defaultValue: defaultValue,
            modelContext: modelContext
        )
        self.init(
            file,
            line,
            column,
            name: name,
            storage: storage
        )
    }
}

#endif 
