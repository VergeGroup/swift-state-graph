import XCTest
@testable import Development // Import the module where TodoItem and TodoListViewModel are defined
@testable import StateGraph // Required if you directly interact with StateGraph mechanisms

class TodoTests: XCTestCase {

    // MARK: - TodoItem Tests

    func testTodoItemInitialization() {
        let item1 = TodoItem(title: "Buy groceries")
        XCTAssertEqual(item1.title, "Buy groceries")
        XCTAssertFalse(item1.isCompleted)
        XCTAssertFalse(item1.id.isEmpty)

        let item2 = TodoItem(id: "custom-id", title: "Walk the dog", isCompleted: true)
        XCTAssertEqual(item2.id, "custom-id")
        XCTAssertEqual(item2.title, "Walk the dog")
        XCTAssertTrue(item2.isCompleted)
    }

    // MARK: - TodoListViewModel Tests

    @MainActor // Run on main actor if your ViewModel requires it (common with @StateObject or UI updates)
    func testAddTodo() {
        let viewModel = TodoListViewModel()
        XCTAssertTrue(viewModel.todos.isEmpty)

        viewModel.addTodo(title: "First Todo")
        XCTAssertEqual(viewModel.todos.count, 1)
        XCTAssertEqual(viewModel.todos.first?.title, "First Todo")
        XCTAssertFalse(viewModel.todos.first!.isCompleted)
    }

    @MainActor
    func testDeleteTodo() {
        let viewModel = TodoListViewModel()
        viewModel.addTodo(title: "Todo 1")
        viewModel.addTodo(title: "Todo 2")
        XCTAssertEqual(viewModel.todos.count, 2)

        // Assuming deleteTodo(at offsets: IndexSet)
        viewModel.deleteTodo(at: IndexSet(integer: 0))
        XCTAssertEqual(viewModel.todos.count, 1)
        XCTAssertEqual(viewModel.todos.first?.title, "Todo 2")
        
        // Test deleting a specific item if that function is preferred
        if let itemToDelete = viewModel.todos.first {
            viewModel.deleteTodoItem(itemToDelete)
            XCTAssertTrue(viewModel.todos.isEmpty)
        }
    }
    
    @MainActor
    func testDeleteTodoItem() {
        let viewModel = TodoListViewModel()
        viewModel.addTodo(title: "Todo 1")
        let todo2 = TodoItem(title: "Todo 2")
        viewModel.todos.append(todo2)
        
        XCTAssertEqual(viewModel.todos.count, 2)

        viewModel.deleteTodoItem(todo2)
        XCTAssertEqual(viewModel.todos.count, 1)
        XCTAssertEqual(viewModel.todos.first?.title, "Todo 1")
        
        if let itemToDelete = viewModel.todos.first {
             viewModel.deleteTodoItem(itemToDelete)
             XCTAssertTrue(viewModel.todos.isEmpty)
        }
    }

    @MainActor
    func testToggleCompletion() {
        let viewModel = TodoListViewModel()
        viewModel.addTodo(title: "Test Todo")
        
        guard let todo = viewModel.todos.first else {
            XCTFail("Todo item should exist")
            return
        }
        XCTAssertFalse(todo.isCompleted)

        viewModel.toggleCompletion(for: todo)
        // Need to fetch the item again if it's a struct and array holds copies
        // If TodoItem is a class, this isn't strictly necessary but good for clarity
        let updatedTodo = viewModel.todos.first! 
        XCTAssertTrue(updatedTodo.isCompleted)

        viewModel.toggleCompletion(for: updatedTodo)
        let finalTodo = viewModel.todos.first!
        XCTAssertFalse(finalTodo.isCompleted)
    }
}
