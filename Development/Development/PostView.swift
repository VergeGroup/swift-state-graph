import SwiftUI
import StateGraph
import StateGraphNormalization
import Combine

// MARK: Data

extension ComputedEnvironmentValues {
  
  var normalizedStore: NormalizedStore! {
    get {
      self[NormalizedStore.self]
    }
    set {
      self[NormalizedStore.self] = newValue
    }
  }  
}

final class User: TypedIdentifiable, Sendable {
  
  typealias TypedIdentifierRawValue = String
  
  let typedID: TypedID
  
  @GraphStored
  var name: String
  
  @GraphStored
  var age: Int
  
  @GraphComputed
  var posts: [Post]
  
  init(
    id: String,
    name: String,
    age: Int
  ) {
    self.typedID = .init(id)
    self.name = name
    self.age = age
    self.$posts = .init(name: "posts") { context in
      context.environment.normalizedStore.posts
        .filter { $0.author.id.raw == id }
        .sorted(by: { $0.createdAt < $1.createdAt })
    }
  }
}

final class Post: TypedIdentifiable, Hashable, Sendable {
  
  static func == (lhs: Post, rhs: Post) -> Bool {
    lhs === rhs
  }
  
  func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(self))    
  }
  
  typealias TypedIdentifierRawValue = String
  
  let typedID: TypedID
  
  @GraphStored
  var title: String
  
  @GraphStored  
  var content: String
  
  let author: User
  
  let createdAt: Date = .init()
  
  @GraphComputed
  var allComments: [Comment]
  
  @GraphComputed
  var activeComments: [Comment]
  
  init(
    id: String,
    title: String,
    content: String,
    author: User
  ) {
    self.typedID = .init(id)
    self.title = title
    self.content = content
    self.author = author
    self.$allComments = .init(name: "allComments") { context in
      context.environment.normalizedStore.comments
        .filter { $0.post.id.raw == id }
        .sorted(by: { $0.createdAt < $1.createdAt })
    }
    self.$activeComments = .init(name: "activeComments") { [allComments = $allComments] context in
      allComments
        .wrappedValue
        .filter { !$0.isDeleted }
    }
  }
}

final class Comment: TypedIdentifiable, Sendable {
  typealias TypedIdentifierRawValue = String
  
  let typedID: TypedID
  
  @GraphStored
  var text: String
  
  @GraphStored
  var createdAt: Date = .init()
  
  let post: Post
  
  let author: User
  
  @GraphStored
  var isDeleted: Bool = false
  
  init(id: String, text: String, post: Post, author: User) {
    self.typedID = .init(id)
    self.text = text
    self.post = post
    self.author = author
  }
}

// Normalized store using StateGraph
final class NormalizedStore: ComputedEnvironmentKey, Sendable {
  
  typealias Value = NormalizedStore
  
  @GraphStored
  var users: EntityStore<User> = .init()  
  @GraphStored
  var posts: EntityStore<Post> = .init()
  @GraphStored
  var comments: EntityStore<Comment> = .init()
  
  
}

// MARK: Service

@MainActor
final class MockServerService {
  private let store: NormalizedStore
  private var task: Task<Void, Never>?
  
  init(store: NormalizedStore) {
    self.store = store
  }
  
  func start() {
    task = Task {
      // 初期データの生成
      let users = [
        createUser(id: "user1", name: "Alice", age: 25),
        createUser(id: "user2", name: "Bob", age: 30),
        createUser(id: "user3", name: "Charlie", age: 28)
      ]
      
      for user in users {
        store.users.add(user)
      }
      
      // 定期的に新しい投稿とコメントを生成
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 100_000_000) 
        
        // ランダムなユーザーを選択
        guard let randomUser = store.users.getAll().randomElement() else { continue }
        
        // 新しい投稿を作成
        let post = createPost(
          id: UUID().uuidString,
          author: randomUser,
          title: generateRandomTitle(),
          content: generateRandomContent()
        )
        store.posts.add(post)
        
        // 投稿に対するコメントを生成
        try? await Task.sleep(nanoseconds: 1_000_000) // 2秒
        
        for _ in 0..<Int.random(in: 1...3) {
          guard let commentUser = store.users.getAll().randomElement() else { continue }
          let comment = createComment(
            id: UUID().uuidString,
            post: post,
            author: commentUser,
            text: generateRandomComment()
          )
          store.comments.add(comment)
        }
      }
    }
  }
  
  func stop() {
    task?.cancel()
    task = nil
  }
  
  private func createUser(id: String, name: String, age: Int) -> User {
    User(id: id, name: name, age: age)
  }
  
  private func createPost(id: String, author: User, title: String, content: String) -> Post {
    Post(id: id, title: title, content: content, author: author)
  }
  
  private func createComment(id: String, post: Post, author: User, text: String) -> Comment {
    Comment(id: id, text: text, post: post, author: author)
  }
  
  private func generateRandomTitle() -> String {
    let titles = [
      "今日の出来事",
      "新しい発見",
      "面白い体験",
      "考えたこと",
      "共有したいこと"
    ]
    return titles.randomElement() ?? "投稿"
  }
  
  private func generateRandomContent() -> String {
    let contents = [
      "とても素晴らしい一日でした！",
      "新しいプロジェクトを始めました。",
      "友達と楽しい時間を過ごしました。",
      "今日は天気が良くて気分がいいです。",
      "最近読んだ本が面白かったです。"
    ]
    return contents.randomElement() ?? "投稿内容"
  }
  
  private func generateRandomComment() -> String {
    let comments = [
      "素晴らしいですね！",
      "私も同じ経験があります。",
      "興味深い内容です。",
      "応援しています！",
      "もっと詳しく教えてください。"
    ]
    return comments.randomElement() ?? "コメント"
  }
}

// MARK: Views

@MainActor
final class PostListViewModel: ObservableObject {
  
  @GraphStored
  var store: NormalizedStore
  
  @GraphComputed
  var posts: [Post]     
  
  @GraphComputed
  var postsCount: Int
  
  let mockServer: MockServerService
  
  @GraphStored
  var isAutoAddEnabled: Bool = false
  
  private var cancellable: AnyCancellable?
  
  init(store: NormalizedStore) {
    self.store = store
    self.mockServer = .init(store: store)
    
    self.$posts = store.$posts.map { _, value in
      value.getAll().sorted(by: { $0.createdAt > $1.createdAt })            
    }
    
    self.$postsCount = store.$posts.map { _, value in
      value.count
    }
    
    // isAutoAddEnabledの変化を監視し、start/stopを呼ぶ
    self.cancellable = withGraphTracking {
      $isAutoAddEnabled.onChange { [weak self] value in
        guard let self else { return }
        if value {
          self.mockServer.start()
        } else {
          self.mockServer.stop()
        }
      }
    }
  }
  
  deinit {
  }
}

struct PostListContainerView: View {
  @StateObject var viewModel: PostListViewModel = .init(store: .init())
  
  init() {    
  }
  
  var body: some View {
    PostListView(viewModel: viewModel)
      .onAppear {
        MainActor.assumeIsolated {
          let store = viewModel.store
          StateGraphGlobal.computedEnvironmentValues.withLock {
            $0.normalizedStore = store
          }   
        }
      }
      .onDisappear {
       
        viewModel.mockServer.stop()
        StateGraphGlobal.computedEnvironmentValues.withLock {
          $0.normalizedStore = nil
        }   
        Task {
          print("👨🏻", await NodeStore.shared._nodes.count)
        }
      }
  }
}

struct PostListView: View {
  let viewModel: PostListViewModel
  
  var body: some View {
    VStack {
      Toggle("自動追加", isOn: viewModel.$isAutoAddEnabled.binding)
        .padding()
      Text("\(viewModel.postsCount)")
      List {
        ForEach(viewModel.posts) { post in
          PostCellView(post: post)
        }
      }
    }
  }
}

struct PostCellView: View {
  let post: Post
  
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Post content
      VStack(alignment: .leading, spacing: 4) {
        Text(post.title)
          .font(.headline)
        Text(post.content)
          .font(.body)
        Text("By: \(post.author.name)")
          .font(.caption)
          .foregroundColor(.secondary)
        Text(post.createdAt.formatted(date: .omitted, time: .complete))
      }
      
      // Comments
      if !post.activeComments.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text("Comments")
            .font(.subheadline)
            .foregroundColor(.secondary)
          
          List {
            ForEach(post.activeComments) { comment in
              CommentView(comment: comment)
            }
          }
          .listStyle(.plain)
        }
      }
    }
    .padding(.vertical, 8)
  }
}

struct CommentView: View {
  let comment: Comment
  
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(comment.text)
        .font(.body)
      Text("By: \(comment.author.name)")
        .font(.caption)
        .foregroundColor(.secondary)
    }
    .padding(.leading, 8)
  }
}

