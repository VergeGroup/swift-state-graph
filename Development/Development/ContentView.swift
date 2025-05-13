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

private struct Book_StateView: View {
  
  final class Entity: Sendable {
    
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
  
  let entity: Entity
  
  init(entity: Entity) {
    self.entity = entity
  }
  
  var body: some View {
    let _ = Self._printChanges()
    Form {
      Text("\(entity.name)")
      Text("\(entity.count)")
      Button("Update Name") {
        entity.name += "+"        
      }
      Button("Update Count") {
        entity.count += 1
      }
      Button("Update Count 2") {
        entity.count2 += 1
      }
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
