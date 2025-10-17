//
//  ContentView.swift
//  Development
//
//  Created by Muukii on 2025/04/28.
//

import StateGraph
import SwiftUI
import StorybookKit

struct ContentView: View {
  var body: some View {
    NavigationStack {
      Form {
        
        NavigationLink {
          Observe_specific(model: .init(name: "A", count: 1))
        } label: { 
          Text("Observe specific") 
        }
        
        NavigationLink { 
          Text("Empty")
        } label: { 
          Text("Empty") 
        }
        
        NavigationLink {
          Book_StateView(entity: .init(name: "A", count: 1))
        } label: { 
          Text("StateView") 
        }
        
        NavigationLink {
          PostListContainerView()
        } label: { 
          Text("Posts") 
        }
        
        NavigationLink {
          PostOneShotView()
        } label: { 
          Text("Database memory check") 
        }
        
        NavigationLink {
          UserDefaultsView()
        } label: { 
          Text("UserDefaults") 
        }
        
      }
    }
  }
}

#if DEBUG

import SwiftUI

private struct Book_SingleStoredNode: View {
  
  let node: Stored<Int>
  
  init(node: Stored<Int>) {
    self.node = node
  }
  
  var body: some View {
    VStack {
      Text("\(node.wrappedValue)")
      Button("+1") {
        node.wrappedValue += 1
      }
    }
  }
}

#Preview("_Book") {
  Book_SingleStoredNode(
    node: Stored(wrappedValue: 1)
  )
  .frame(width: 300, height: 300)
}

// MARK: -

final class Model: Sendable {
  
  @GraphStored
  var name: String = ""
  @GraphStored
  var count1: Int = 0
  @GraphStored
  var count2: Int = 0
  
  init(
    name: String,
    count: Int
  ) {      
    self.name = name
    self.count1 = count
  }
  
}

struct Observe_specific: View {
  
  let model: Model
  
  var body: some View {
    let _ = Self._printChanges()    
    Form {
      Text("This view should be updated only when count1 changes.")
      Text("\(model.count1)")
      Button("Update count1") {
        model.count1 += 1
      }
      Button("Update count2") {
        model.count2 += 1
      }
    }
  }
  
}

#Preview("Observe_specific") {
  Observe_specific(model: .init(name: "A", count: 1))
}

private struct Book_StateView: View {
    
  let model: Model
  @State var subscription: AnyCancellable?
  
  init(entity: Model) {
    self.model = entity
  }
  
  var body: some View {
    let _ = Self._printChanges()
    Form {
      Text("\(model.name)")
      Text("\(model.count1)")
      Button("Update Name") {
        model.name += "+"        
      }
      Button("Update Count \(model.count1)") {
        model.count1 += 1
      }
      Button("Update Count \(model.count2)") {
        model.count2 += 1
      }
      Button("Batch") {
        model.count1 += 1
        model.count1 += 1
        model.count2 += 1
      }
    }
    .onAppear {
      
      print("onAppear")
                
      subscription = withGraphTracking {

        withGraphTrackingGroup {
          print("☁️", model.count1, model.count2)
        }

        withGraphTrackingMap {
          model.count1 + model.count2
        } onChange: { value in
          print("computed", value)
        }

        withGraphTrackingMap {
          model.$count1.wrappedValue
        } onChange: { value in
          print("count", value)
        }
      }
      
    }
    .onDisappear {
      subscription?.cancel()      
    }
  }
}

final class MyViewModel {
  @GraphStored var count: Int = 0
}

#Preview("StateView") {
  Book_StateView(
    entity: .init(
      name: "A",
      count: 1
    )
  )
}


#endif
