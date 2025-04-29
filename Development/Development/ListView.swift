//
//  ListView.swift
//  Development
//
//  Created by Muukii on 2025/04/28.
//

import StateGraph
import SwiftUI

final class TagEntity: StateView {
  let id: String
  @Stored var name: String = ""

  init(
    stateGraph: StateGraph,
    id: String,
    name: String
  ) {
    self.id = id
    self.name = name
    super.init(stateGraph: stateGraph)
  }
}

final class AuthorEntity: StateView {

  let id: String
  @Stored var name: String = ""

  init(
    stateGraph: StateGraph,
    id: String,
    name: String
  ) {
    self.id = id
    self.name = name
    super.init(stateGraph: stateGraph)
  }

}

final class BookEntity: StateView {

  let id: String
  @Stored var title: String = ""
  @Stored var author: AuthorEntity
  @Stored var tags: [TagEntity] = []

  init(
    stateGraph: StateGraph,
    id: String,
    title: String,
    author: AuthorEntity,
    tags: [TagEntity]
  ) {
    self.id = id
    self.title = title
    self.author = author
    self.tags = tags
    super.init(stateGraph: stateGraph)
  }
}

final class RootState: StateView {

  final class DB: StateView {
    @Stored var books: [BookEntity] = []
    @Stored var authors: [AuthorEntity] = []
  }

  let db: DB

  override init(stateGraph: StateGraph) {

    self.db = .init(stateGraph: stateGraph)

    super.init(stateGraph: stateGraph)
  }

}

struct ListView: View {

  let rootState: RootState

  init(rootState: RootState) {
    self.rootState = rootState
  }

  var body: some View {
    NavigationStack {
      List(rootState.db.authors, id: \.self) { e in
        NavigationLink(value: e) {           
          AuthorCell(author: e)
        }
      }
      .navigationDestination(for: AuthorEntity.self, destination: { author in
        BookListInAuthor(author: author, rootState: rootState)
      })
      .toolbar {
        Button("Add Author") {

          rootState.db.authors.append(
            .init(
              stateGraph: stateGraph,
              id: UUID().uuidString,
              name: "Unknown"
            )
          )

        }
      }
    }
  }
  
  struct BookListInAuthor: View {

    let books: ComputedNode<[BookEntity]>
    let rootState: RootState
    let author: AuthorEntity
    
    init(
      author: AuthorEntity,
      rootState: RootState
    ) {
      self.author = author
      self.rootState = rootState
      
      books = rootState.stateGraph!.rule(name: "", { graph in
        rootState.db.books
          .filter { $0.author.id == author.id }
          .sorted { $0.title < $1.title }
      })
    }
    
    var body: some View {
      List(books.wrappedValue, id: \.self) { e in
        NavigationLink(value: e) {           
          BookCell(book: e)
        }
      }
      .toolbar {
        Button("Add Book") {
          
          rootState.db.books.append(
            .init(
              stateGraph: rootState.stateGraph!,
              id: UUID().uuidString,
              title: "New",
              author: author,
              tags: []
            )
          )          
        }
      }
    }

  }

  
  struct AuthorCell: View {

    let author: AuthorEntity

    var body: some View {
      Text(author.name)
    }

  }

  struct BookCell: View {

    let book: BookEntity

    var body: some View {
      Text(book.title)
    }

  }
}

@MainActor
let stateGraph = StateGraph()

#Preview {
  ListView(rootState: RootState(stateGraph: stateGraph))
}
