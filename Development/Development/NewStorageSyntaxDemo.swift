import SwiftUI
import StateGraph

// Example demonstrating the new storage syntax
struct NewStorageSyntaxDemo: View {
  
  // Using the new syntax with memory storage
  let memoryStoredValue = _Stored(storage: .memory, value: "Hello from memory!")
  
  // Using the new syntax with UserDefaults storage  
  let userDefaultsStoredValue = _Stored(
    storage: .userDefaults(key: "demo_message"),
    value: "Hello from UserDefaults!"
  )
  
  // With custom suite
  let customSuiteValue = _Stored(
    storage: .userDefaults(key: "theme", suite: "com.example.app"),
    value: "light"
  )
  
  var body: some View {
    VStack(spacing: 20) {
      Text("New Storage Syntax Demo")
        .font(.title)
        .padding()
      
      GroupBox("Memory Storage") {
        HStack {
          Text("Value:")
          TextField("Enter text", text: memoryStoredValue.binding)
            .textFieldStyle(.roundedBorder)
        }
        .padding()
      }
      
      GroupBox("UserDefaults Storage") {
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            Text("Value:")
            TextField("Enter text", text: userDefaultsStoredValue.binding)
              .textFieldStyle(.roundedBorder)
          }
          
          Text("This value persists across app launches")
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding()
      }
      
      GroupBox("Custom Suite Storage") {
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            Text("Theme:")
            Picker("Theme", selection: customSuiteValue.binding) {
              Text("Light").tag("light")
              Text("Dark").tag("dark")
              Text("System").tag("system")
            }
            .pickerStyle(.segmented)
          }
          
          Text("Stored in custom suite: com.example.app")
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding()
      }
      
      Spacer()
      
      // Demonstrating that it works with Computed nodes
      ComputedValueDemo(stored: memoryStoredValue)
    }
    .padding()
  }
}

struct ComputedValueDemo: View {
  let stored: _Stored<InMemoryStorage<String>>
  
  var body: some View {
    let computed = Computed(stored)
    
    GroupBox("Computed from Memory Storage") {
      VStack(alignment: .leading) {
        Text("Uppercase: \(computed.wrappedValue.uppercased())")
        Text("Character count: \(computed.wrappedValue.count)")
      }
      .padding()
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

#Preview {
  NewStorageSyntaxDemo()
    .frame(width: 400, height: 600)
}
