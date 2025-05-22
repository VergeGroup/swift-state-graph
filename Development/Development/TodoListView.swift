import SwiftUI
import StateGraph // Ensure this import is present

struct TodoListView: View {
    @StateObject var viewModel = TodoListViewModel() // Initialize the ViewModel
    @State private var newTodoTitle: String = ""

    var body: some View {
        NavigationView {
            VStack {
                HStack {
                    TextField("Enter new todo...", text: $newTodoTitle)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    Button(action: {
                        if !newTodoTitle.isEmpty {
                            viewModel.addTodo(title: newTodoTitle)
                            newTodoTitle = "" // Reset text field
                        }
                    }) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.green)
                            .imageScale(.large)
                    }
                }
                .padding()

                List {
                    ForEach(viewModel.todos) { todo in
                        HStack {
                            Text(todo.title)
                            Spacer()
                            Image(systemName: todo.isCompleted ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(todo.isCompleted ? .green : .gray)
                                .onTapGesture {
                                    viewModel.toggleCompletion(for: todo)
                                }
                        }
                    }
                    .onDelete(perform: viewModel.deleteTodo)
                }
            }
            .navigationTitle("Todo List")
            .toolbar {
                EditButton() // To enable swipe-to-delete functionality easily
            }
        }
    }
}

#if DEBUG
struct TodoListView_Previews: PreviewProvider {
    static var previews: some View {
        TodoListView()
    }
}
#endif
