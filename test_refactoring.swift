import StateGraph

// Test that the refactored _Stored class works correctly

// Test InMemoryStorage
let memoryStored = _Stored(storage: .memory, value: 42)
print("Memory stored value: \(memoryStored.wrappedValue)")
memoryStored.wrappedValue = 100
print("Updated memory stored value: \(memoryStored.wrappedValue)")

// Test type is correct
print("Type of memoryStored: \(type(of: memoryStored))")

// Test with Computed
let computed = Computed(memoryStored)
print("Computed value: \(computed.wrappedValue)")

// Test with convenience initializer
let convenient = _Stored(wrappedValue: "Hello, World!")
print("Convenient stored value: \(convenient.wrappedValue)")

print("\nRefactoring successful! ✅")