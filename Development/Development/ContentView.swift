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
          SpotifyLoginView()
        } label: {
          Text("Spotify Login")
        }
        
        NavigationLink {
          SpotifyListView()
        } label: {
          Text("Spotify (Sample Data)")
        }
      }
    }
  }
}

#Preview {
  ContentView()
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
    }
    .onAppear {
      
      print("onAppear")
                
      subscription = withGraphTracking { 
        Computed { _ in
          model.count1 + model.count2
        }
        .onChange { value in
          print("computed", value)          
        }
        model.$count1.onChange { value in
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
