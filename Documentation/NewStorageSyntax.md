# New Storage Initialization Syntax

Swift State Graph now supports a more intuitive syntax for creating `Stored` nodes with different storage backends.

## Overview

Instead of using the `@GraphStored` macro with a `backed:` parameter, you can now directly create `_Stored` instances using the new marker-based syntax:

```swift
// Memory storage (default)
let memoryStored = _Stored(storage: MemoryMarker.memory, value: "Hello, World!")

// UserDefaults storage
let defaultsStored = _Stored(storage: UserDefaultsMarker.userDefaults(key: "myKey"), value: "Hello, World!")

// UserDefaults with custom suite
let suiteStored = _Stored(storage: UserDefaultsMarker.userDefaults(key: "theme", suite: "com.myapp"), value: "light")
```

## Benefits

1. **Type Safety**: The concrete storage type is preserved in the type system, eliminating the need for type erasure.
2. **Better IDE Support**: Autocomplete works naturally with the dot syntax.
3. **Cleaner API**: No need to remember macro-specific enum values.
4. **Flexibility**: Easy to extend with new storage types in the future.

## Migration from Macro Syntax

### Before (Macro Syntax)
```swift
class MyModel {
  @GraphStored(backed: MemoryMarker.memory) 
  var count: Int = 0
  
  @GraphStored(backed: UserDefaultsMarker.userDefaults(key: "theme"))
  var theme: String = "light"
}
```

### After (Direct Initialization)
```swift
class MyModel {
  let count = _Stored(storage: MemoryMarker.memory, value: 0)
  let theme = _Stored(storage: UserDefaultsMarker.userDefaults(key: "theme"), value: "light")
  
  var countValue: Int {
    get { count.wrappedValue }
    set { count.wrappedValue = newValue }
  }
  
  var themeValue: String {
    get { theme.wrappedValue }
    set { theme.wrappedValue = newValue }
  }
}
```

## SwiftUI Integration

The new syntax works seamlessly with SwiftUI bindings:

```swift
struct ContentView: View {
  let stored = _Stored(storage: MemoryMarker.memory, value: "Hello")
  
  var body: some View {
    TextField("Enter text", text: stored.binding)
  }
}
```

## Working with Computed Nodes

The new syntax maintains full compatibility with `Computed` nodes:

```swift
let stored = _Stored(storage: MemoryMarker.memory, value: 10)
let computed = Computed { _ in
  stored.wrappedValue * 2
}
```

## Type Information

The type system now preserves the exact storage type:
- `_Stored<InMemoryStorage<String>>` for memory storage
- `_Stored<UserDefaultsStorage<String>>` for UserDefaults storage

This provides better type safety and enables storage-specific operations in the future.

## Future Compatibility

The `@GraphStored` macro continues to work and will be updated to use the new syntax internally. This ensures backward compatibility while providing a migration path to the cleaner API.