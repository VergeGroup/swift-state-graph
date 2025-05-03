//
//  ListView.swift
//  Development
//
//  Created by Muukii on 2025/04/28.
//

import StateGraph
import SwiftUI

@StateView
final class TagEntity: Sendable {
  let id: String
  var name: String = ""

  init(
    id: String,
    name: String
  ) {
    self.id = id
    self.name = name
  }
}

@StateView
final class AuthorEntity: Hashable, Sendable {
  
  public static func == (lhs: AuthorEntity, rhs: AuthorEntity) -> Bool {
    lhs === rhs
  }
  
  func hash(into hasher: inout Hasher) {
    id.hash(into: &hasher)
  }

  let id: String
  var name: String = ""

  init(
    id: String,
    name: String
  ) {
    self.id = id
    self.name = name
  }

}

@StateView
final class BookEntity: Sendable, Hashable {
  
  public static func == (lhs: BookEntity, rhs: BookEntity) -> Bool {
    lhs === rhs
  }
  
  func hash(into hasher: inout Hasher) {
    id.hash(into: &hasher)
  }

  let id: String
  var title: String
  var author: AuthorEntity
  var tags: [TagEntity] = []

  init(
    id: String,
    title: String,
    author: AuthorEntity,
    tags: [TagEntity]
  ) {
    self.id = id
    self.title = title
    self.author = author
    self.tags = tags
  }
}

@StateView
final class RootState: Sendable {

  @StateView
  final class DB: Sendable {
    var books: [BookEntity] = []
    var authors: [AuthorEntity] = []
  }

  let db: DB

  init() {

    self.db = .init()

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
              id: UUID().uuidString,
              name: "Unknown"
            )
          )

        }
      }
    }
  }
  
  struct BookListInAuthor: View {

    @Computed var books: [BookEntity]
    let rootState: RootState
    let author: AuthorEntity
    
    init(
      author: AuthorEntity,
      rootState: RootState
    ) {
      self.author = author
      self.rootState = rootState
      
      _books = .init(compute: {
        rootState.db.books
          .filter { $0.author.id == author.id }
          .sorted { $0.title < $1.title }
      })
    }
    
    var body: some View {
      List(books, id: \.self) { e in
        NavigationLink(value: e) {           
          BookCell(book: e)
        }
      }
      .toolbar {
        Button("Add Book") {
          
          rootState.db.books.append(
            .init(
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

#Preview {
  ListView(rootState: RootState())   
}
