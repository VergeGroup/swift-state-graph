import SwiftUI
import StateGraph


final class UserDefaultsViewModel {
  
  @GraphStored var count: Int = 0
  
  @GraphStored(backed: .userDefaults(key: "A")) var savedCount: Int = 0
  
}
  

struct UserDefaultsView: View {
  
  let model: UserDefaultsViewModel = .init()
  
  var body: some View {
    let _ = Self._printChanges()
    Form {
      Text("Count: \(model.count)")
      Button("Increment") {
        model.count += 1
      }
      Text("Saved Count: \(model.savedCount)")
      Button("Save Count") {
        model.savedCount = model.count
      }
      Button("Update UserDefaults") {
        UserDefaults.standard.set(model.count, forKey: "A")
      }
    }
    
  }
}

#Preview("UserDefaults") {
  UserDefaultsView()
}
