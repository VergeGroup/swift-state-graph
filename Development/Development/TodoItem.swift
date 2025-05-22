import Foundation
import StateGraph // Add this import

final class TodoItem: Identifiable, Sendable { // Changed from struct to final class
    let id: String
    
    @GraphStored // Added for title
    var title: String
    
    @GraphStored // Added for isCompleted
    var isCompleted: Bool

    init(id: String = UUID().uuidString, title: String, isCompleted: Bool = false) {
        self.id = id
        self.title = title // Corrected: Direct assignment
        self.isCompleted = isCompleted // Corrected: Direct assignment
    }
}
