import Foundation
import StateGraph // Ensure this import is present

final class TodoListViewModel: Sendable, ObservableObject {

    @GraphStored
    var todos: [TodoItem] = []

    // Function to add a new TodoItem
    func addTodo(title: String) {
        let newTodo = TodoItem(title: title)
        todos.append(newTodo)
    }

    // Function to delete a TodoItem
    func deleteTodo(at offsets: IndexSet) {
        todos.remove(atOffsets: offsets)
    }
    
    // Function to delete a specific TodoItem
    func deleteTodoItem(_ item: TodoItem) {
        todos.removeAll { $0.id == item.id }
    }

    // Function to toggle the isCompleted status of a TodoItem
    func toggleCompletion(for todo: TodoItem) {
        if let index = todos.firstIndex(where: { $0.id == todo.id }) {
            todos[index].isCompleted.toggle()
        }
    }
}
