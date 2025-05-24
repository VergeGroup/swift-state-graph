# SwiftUI Integration

Seamless integration between Swift State Graph and SwiftUI.

## Overview

Swift State Graph integrates naturally with SwiftUI, providing automatic UI updates when your state changes. The framework works alongside SwiftUI's binding system and observation mechanisms to create reactive user interfaces.

## Basic Integration

The simplest way to use Swift State Graph with SwiftUI is to create a view model with `@GraphStored` and `@GraphComputed` properties:

```swift
import SwiftUI
import StateGraph

final class CounterViewModel {
  @GraphStored
  var count: Int = 0

  @GraphComputed
  var isEven: Bool

  @GraphComputed
  var displayText: String

  init() {
    self.$isEven = .init { [$count] _ in
      $count.wrappedValue % 2 == 0
    }

    self.$displayText = .init { [$count, $isEven] _ in
      let number = $count.wrappedValue
      let parity = $isEven.wrappedValue ? "even" : "odd"
      return "Count: \(number) (\(parity))"
    }
  }

  func increment() { count += 1 }
  func decrement() { count -= 1 }
}

struct CounterView: View {
  @State private var viewModel = CounterViewModel()

  var body: some View {
    VStack(spacing: 20) {
      Text(viewModel.displayText)
        .font(.title)

      HStack {
        Button("−", action: viewModel.decrement)
        Button("+", action: viewModel.increment)
      }
      .buttonStyle(.borderedProminent)
    }
    .padding()
  }
}
```

## SwiftUI Bindings

Swift State Graph provides seamless integration with SwiftUI's binding system through the `.binding` property:

```swift
final class FormViewModel {
  @GraphStored
  var name: String = ""

  @GraphStored
  var email: String = ""

  @GraphStored
  var age: Double = 18

  @GraphComputed
  var isValid: Bool

  init() {
    self.$isValid = .init { [$name, $email] _ in
      !$name.wrappedValue.isEmpty && 
      $email.wrappedValue.contains("@")
    }
  }
}

struct FormView: View {
  @State private var viewModel = FormViewModel()

  var body: some View {
    Form {
      Section("Personal Information") {
        TextField("Name", text: viewModel.$name.binding)
        TextField("Email", text: viewModel.$email.binding)
        
        VStack(alignment: .leading) {
          Text("Age: \(Int(viewModel.age))")
          Slider(value: viewModel.$age.binding, in: 18...100, step: 1)
        }
      }

      Section {
        Button("Submit") {
          submitForm()
        }
        .disabled(!viewModel.isValid)
      }
    }
  }

  private func submitForm() {
    // Handle form submission
  }
}
```

## Observable Conformance

Swift State Graph nodes automatically conform to SwiftUI's `Observable` protocol when available, enabling direct use with SwiftUI's observation system:

```swift
// On iOS 17+ / macOS 14+, nodes are automatically observable
struct UserProfileView: View {
  @State private var viewModel = UserProfileViewModel()

  var body: some View {
    // SwiftUI automatically observes viewModel properties
    VStack {
      Text("Hello, \(viewModel.fullName)")
      
      if viewModel.isLoading {
        ProgressView()
      } else {
        ProfileContent(viewModel: viewModel)
      }
    }
  }
}
```

## Complex UI Patterns

### Master-Detail Views

```swift
final class BookLibraryViewModel {
  @GraphStored
  var books: [Book] = []

  @GraphStored
  var selectedBookId: Book.ID?

  @GraphStored
  var searchText: String = ""

  @GraphComputed
  var filteredBooks: [Book]

  @GraphComputed
  var selectedBook: Book?

  init() {
    self.$filteredBooks = .init { [$books, $searchText] _ in
      let books = $books.wrappedValue
      let search = $searchText.wrappedValue
      
      if search.isEmpty {
        return books
      } else {
        return books.filter { 
          $0.title.localizedCaseInsensitiveContains(search) 
        }
      }
    }

    self.$selectedBook = .init { [$books, $selectedBookId] _ in
      guard let id = $selectedBookId.wrappedValue else { return nil }
      return $books.wrappedValue.first { $0.id == id }
    }
  }
}

struct LibraryView: View {
  @State private var viewModel = BookLibraryViewModel()

  var body: some View {
    NavigationSplitView {
      VStack {
        SearchBar(text: viewModel.$searchText.binding)
        
        List(viewModel.filteredBooks, selection: viewModel.$selectedBookId.binding) { book in
          BookRow(book: book)
        }
      }
      .navigationTitle("Library")
    } detail: {
      if let book = viewModel.selectedBook {
        BookDetailView(book: book)
      } else {
        Text("Select a book")
          .foregroundStyle(.secondary)
      }
    }
  }
}
```

### List Management

```swift
final class TodoListViewModel {
  @GraphStored
  var todos: [Todo] = []

  @GraphStored
  var filter: TodoFilter = .all

  @GraphComputed
  var filteredTodos: [Todo]

  @GraphComputed
  var completedCount: Int

  @GraphComputed
  var remainingCount: Int

  init() {
    self.$filteredTodos = .init { [$todos, $filter] _ in
      let todos = $todos.wrappedValue
      switch $filter.wrappedValue {
      case .all: return todos
      case .active: return todos.filter { !$0.isCompleted }
      case .completed: return todos.filter { $0.isCompleted }
      }
    }

    self.$completedCount = .init { [$todos] _ in
      $todos.wrappedValue.count { $0.isCompleted }
    }

    self.$remainingCount = .init { [$todos] _ in
      $todos.wrappedValue.count { !$0.isCompleted }
    }
  }

  func addTodo(_ title: String) {
    todos.append(Todo(title: title))
  }

  func toggleTodo(_ id: Todo.ID) {
    if let index = todos.firstIndex(where: { $0.id == id }) {
      todos[index].isCompleted.toggle()
    }
  }
}

struct TodoListView: View {
  @State private var viewModel = TodoListViewModel()
  @State private var newTodoText = ""

  var body: some View {
    NavigationView {
      VStack {
        // Add new todo
        HStack {
          TextField("New todo", text: $newTodoText)
          Button("Add") {
            viewModel.addTodo(newTodoText)
            newTodoText = ""
          }
          .disabled(newTodoText.isEmpty)
        }
        .padding()

        // Filter picker
        Picker("Filter", selection: viewModel.$filter.binding) {
          Text("All (\(viewModel.todos.count))").tag(TodoFilter.all)
          Text("Active (\(viewModel.remainingCount))").tag(TodoFilter.active)
          Text("Completed (\(viewModel.completedCount))").tag(TodoFilter.completed)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)

        // Todo list
        List(viewModel.filteredTodos) { todo in
          TodoRow(todo: todo) {
            viewModel.toggleTodo(todo.id)
          }
        }
      }
      .navigationTitle("Todos")
    }
  }
}
```

## State Restoration

SwiftUI's state restoration works naturally with Swift State Graph:

```swift
final class AppState {
  @GraphStored
  var selectedTab: Tab = .home

  @GraphStored
  var userSettings: UserSettings = .default

  // State is automatically preserved and restored
}

struct ContentView: View {
  @State private var appState = AppState()

  var body: some View {
    TabView(selection: appState.$selectedTab.binding) {
      HomeView()
        .tabItem { Label("Home", systemImage: "house") }
        .tag(Tab.home)
      
      ProfileView()
        .tabItem { Label("Profile", systemImage: "person") }
        .tag(Tab.profile)
    }
    .environmentObject(appState)
  }
}
```

## Environment Integration

Share state through SwiftUI's environment system:

```swift
// Environment key
struct AppStateKey: EnvironmentKey {
  static let defaultValue = AppState()
}

extension EnvironmentValues {
  var appState: AppState {
    get { self[AppStateKey.self] }
    set { self[AppStateKey.self] = newValue }
  }
}

// Root view
struct MyApp: App {
  @State private var appState = AppState()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environment(\.appState, appState)
    }
  }
}

// Child view
struct SomeChildView: View {
  @Environment(\.appState) private var appState

  var body: some View {
    Text("Current user: \(appState.currentUser?.name ?? "None")")
  }
}
```

## Performance Tips

### Minimize View Updates

```swift
// ✅ Good: Specific property access
struct UserNameView: View {
  let user: User

  var body: some View {
    Text(user.name) // Only updates when name changes
  }
}

// ❌ Less optimal: Full object access
struct UserView: View {
  let user: User

  var body: some View {
    VStack {
      Text(user.name)
      Text(user.email) 
      // Updates when ANY user property changes
    }
  }
}
```

### Use Computed Properties for View Logic

```swift
final class ShoppingCartViewModel {
  @GraphStored
  var items: [CartItem] = []

  @GraphComputed
  var canCheckout: Bool

  @GraphComputed
  var checkoutButtonTitle: String

  init() {
    self.$canCheckout = .init { [$items] _ in
      !$items.wrappedValue.isEmpty
    }

    self.$checkoutButtonTitle = .init { [$items] _ in
      let count = $items.wrappedValue.count
      return count == 0 ? "Add Items" : "Checkout (\(count) items)"
    }
  }
}
```

## Animation Integration

Swift State Graph works seamlessly with SwiftUI animations:

```swift
struct AnimatedCounterView: View {
  @State private var viewModel = CounterViewModel()

  var body: some View {
    VStack {
      Text("\(viewModel.count)")
        .font(.largeTitle)
        .contentTransition(.numericText())

      Button("Increment") {
        withAnimation(.spring()) {
          viewModel.increment()
        }
      }
    }
  }
}
```

## Testing in SwiftUI

Swift State Graph makes SwiftUI view testing straightforward:

```swift
import XCTest
import SwiftUI
@testable import YourApp

class CounterViewTests: XCTestCase {
  func testCounterIncrement() {
    let viewModel = CounterViewModel()
    
    // Test initial state
    XCTAssertEqual(viewModel.count, 0)
    XCTAssertTrue(viewModel.isEven)
    
    // Test increment
    viewModel.increment()
    XCTAssertEqual(viewModel.count, 1)
    XCTAssertFalse(viewModel.isEven)
  }
}
```

## Common Patterns

### Loading States

```swift
final class DataViewModel {
  @GraphStored
  var isLoading: Bool = false

  @GraphStored
  var data: [Item]? = nil

  @GraphStored
  var error: Error? = nil

  @GraphComputed
  var viewState: ViewState

  init() {
    self.$viewState = .init { [$isLoading, $data, $error] _ in
      if $isLoading.wrappedValue {
        return .loading
      } else if let error = $error.wrappedValue {
        return .error(error)
      } else if let data = $data.wrappedValue {
        return .loaded(data)
      } else {
        return .empty
      }
    }
  }
}

enum ViewState {
  case loading
  case loaded([Item])
  case error(Error)
  case empty
}
```

Swift State Graph provides a natural, reactive approach to SwiftUI development, eliminating boilerplate while maintaining full type safety and performance. 