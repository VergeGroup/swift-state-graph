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
  var count: Int = 0
  @GraphStored
  var count2: Int = 0
  
  init(
    name: String,
    count: Int
  ) {      
    self.name = name
    self.count = count
  }
  
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
      Text("\(model.count)")
      Button("Update Name") {
        model.name += "+"        
      }
      Button("Update Count") {
        model.count += 1
      }
      Button("Update Count 2") {
        model.count2 += 1
      }
    }
    .onAppear {
      
      print("onAppear")
      
      let node = Computed { _ in
        model.count + model.count2
      }
            
      subscription = withGraphTracking { 
        node.onChange { value in
          print("computed \(node)", value)          
        }
        model.$count.onChange { value in
          print("count", value)
        }
      }
      
    }
    .onDisappear {
      subscription?.cancel()      
    }
  }
}

#Preview {
  Book_StateView(
    entity: .init(
      name: "A",
      count: 1
    )
  )
}


#endif
