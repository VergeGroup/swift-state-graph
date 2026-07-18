import Testing
@testable import StateGraphNormalization
import StateGraph
import Dispatch
import Foundation
import os

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
    self.$activeComments = .init(name: "activeComments") { context in
      context.environment.normalizedStore.comments
        .filter { $0.post.id.raw == id }
        .filter { !$0.isDeleted }
        .sorted(by: { $0.createdAt < $1.createdAt })
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

  let users: EntityStore<User>
  let posts: EntityStore<Post>
  let comments: EntityStore<Comment>

  init() {
    let coordinator = EntityStoreCoordinator()
    self.users = .init(coordinator: coordinator)
    self.posts = .init(coordinator: coordinator)
    self.comments = .init(coordinator: coordinator)
  }
}

private final class ConcurrentEntity: TypedIdentifiable, Sendable {

  typealias TypedIdentifierRawValue = Int

  let typedID: TypedID

  init(id: Int) {
    self.typedID = .init(id)
  }
}

private struct ValueEntity: TypedIdentifiable, Sendable {

  typealias TypedIdentifierRawValue = Int

  let typedID: TypedID
  var value: Int

  init(id: Int, value: Int) {
    self.typedID = .init(id)
    self.value = value
  }
}

private enum MutationError: Error {
  case expected
}

private actor ConcurrentStartGate {

  private let participantCount: Int
  private var continuations: [CheckedContinuation<Void, Never>] = []

  init(participantCount: Int) {
    self.participantCount = participantCount
  }

  func wait() async {
    if continuations.count + 1 == participantCount {
      let continuations = self.continuations
      self.continuations.removeAll()
      continuations.forEach { $0.resume() }
      return
    }

    await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
  }
}

/// A one-shot signal that lets synchronous store callbacks resume async test code.
///
/// Waiting suspends the test task, which avoids exhausting cooperative-executor threads
/// when synchronization tests run in parallel with the rest of the package.
private final class TestSignal: @unchecked Sendable {

  private struct State {
    var isSignaled = false
    var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  func signal() {
    let waiters = state.withLock { state in
      guard !state.isSignaled else { return [CheckedContinuation<Bool, Never>]() }

      state.isSignaled = true
      let waiters = Array(state.waiters.values)
      state.waiters.removeAll()
      return waiters
    }

    waiters.forEach { $0.resume(returning: true) }
  }

  func wait(for timeout: Duration) async -> Bool {
    let id = UUID()

    return await withCheckedContinuation { continuation in
      let isAlreadySignaled = state.withLock { state in
        guard !state.isSignaled else { return true }
        state.waiters[id] = continuation
        return false
      }

      guard !isAlreadySignaled else {
        continuation.resume(returning: true)
        return
      }

      Task.detached { [self] in
        try? await Task.sleep(for: timeout)
        let waiter = state.withLock { state in
          state.waiters.removeValue(forKey: id)
        }
        waiter?.resume(returning: false)
      }
    }
  }
}

@Suite
struct NormalizationTests {

  @Test func concurrentDistinctIDInsertionsAreNotLost() async {
    let participantCount = 250
    let gate = ConcurrentStartGate(participantCount: participantCount)
    let store = EntityStore<ConcurrentEntity>()

    await withTaskGroup(of: Void.self) { group in
      for id in 0..<participantCount {
        group.addTask {
          await gate.wait()
          store.add(.init(id: id))
        }
      }
    }

    #expect(store.count == participantCount)
    for id in 0..<participantCount {
      #expect(store.contains(.init(id)))
    }
  }

  @Test func concurrentSameIDUpdatesReturnOneCanonicalReference() async {
    let participantCount = 100
    let gate = ConcurrentStartGate(participantCount: participantCount)
    let store = EntityStore<ConcurrentEntity>()

    let returnedEntities = await withTaskGroup(
      of: ConcurrentEntity.self,
      returning: [ConcurrentEntity].self
    ) { group in
      for _ in 0..<participantCount {
        group.addTask {
          await gate.wait()
          return store.updateOrCreate(
            id: .init(1),
            update: { _ in },
            create: { .init(id: 1) }
          )
        }
      }

      return await group.reduce(into: []) { result, entity in
        result.append(entity)
      }
    }

    let canonicalEntity = try! #require(store.get(by: .init(1)))
    #expect(returnedEntities.allSatisfy { $0 === canonicalEntity })
  }

  @Test func batchMutationPublishesOneGraphUpdate() async {
    let store = EntityStore<ValueEntity>()
    let observedCounts = OSAllocatedUnfairLock(initialState: [Int]())

    await confirmation(expectedCount: 2) { updates in
      let stream = withStateGraphTrackingStream(apply: { store.count })
      let trackingTask = Task {
        for await count in stream {
          observedCounts.withLock { $0.append(count) }
          updates.confirm()
          if count == 2 {
            break
          }
        }
      }

      store.add([
        .init(id: 1, value: 1),
        .init(id: 2, value: 2),
      ])
      await trackingTask.value
    }

    #expect(observedCounts.withLock { $0 } == [0, 2])
  }

  @Test func failedValueUpdateDoesNotCommitOrPublish() {
    let store = EntityStore<ValueEntity>(
      entities: [.init(1): .init(id: 1, value: 1)]
    )
    let computationCount = OSAllocatedUnfairLock(initialState: 0)
    let value = Computed { _ in
      computationCount.withLock { $0 += 1 }
      return store.get(by: .init(1))?.value
    }

    #expect(value.wrappedValue == 1)
    #expect(throws: MutationError.self) {
      try store.updateOrCreate(
        id: .init(1),
        update: { entity throws(MutationError) in
          entity.value = 2
          throw .expected
        },
        create: { () throws(MutationError) -> ValueEntity in
          .init(id: 1, value: 2)
        }
      )
    }

    #expect(store.get(by: .init(1))?.value == 1)
    #expect(value.wrappedValue == 1)
    #expect(computationCount.withLock { $0 } == 1)
  }

  @Test func sharedCoordinatorSupportsNestedStoreMutation() {
    let coordinator = EntityStoreCoordinator()
    let parentStore = EntityStore<ValueEntity>(coordinator: coordinator)
    let childStore = EntityStore<ValueEntity>(coordinator: coordinator)

    parentStore.updateOrCreate(
      id: .init(1),
      update: { _ in },
      create: {
        childStore.add(.init(id: 2, value: 2))
        return .init(id: 1, value: 1)
      }
    )

    #expect(parentStore.contains(.init(1)))
    #expect(childStore.contains(.init(2)))
  }

  @Test func readWaitsForCoordinatedMutation() async {
    let coordinator = EntityStoreCoordinator()
    let store = EntityStore<ValueEntity>(
      entities: [.init(1): .init(id: 1, value: 1)],
      coordinator: coordinator
    )
    let mutationStarted = TestSignal()
    let allowMutationToFinish = DispatchSemaphore(value: 0)
    let readStarted = TestSignal()
    let readFinished = TestSignal()
    let work = DispatchGroup()
    let workFinished = TestSignal()
    let readValue = OSAllocatedUnfairLock<Int?>(initialState: nil)

    work.enter()
    DispatchQueue.global().async {
      store.updateOrCreate(
        id: .init(1),
        update: { entity in
          entity.value = 2
          mutationStarted.signal()
          _ = allowMutationToFinish.wait(timeout: .now() + .seconds(5))
        },
        create: { .init(id: 1, value: 2) }
      )
      work.leave()
    }

    #expect(await mutationStarted.wait(for: .seconds(5)))

    work.enter()
    DispatchQueue.global().async {
      readStarted.signal()
      readValue.withLock { $0 = store.get(by: .init(1))?.value }
      readFinished.signal()
      work.leave()
    }

    work.notify(queue: .global()) {
      workFinished.signal()
    }

    #expect(await readStarted.wait(for: .seconds(5)))
    #expect(await !readFinished.wait(for: .milliseconds(100)))

    allowMutationToFinish.signal()

    #expect(await readFinished.wait(for: .seconds(5)))
    #expect(await workFinished.wait(for: .seconds(5)))
    #expect(readValue.withLock { $0 } == 2)
  }

  @Test func sharedCoordinatorBlocksReadsAcrossStores() async {
    let coordinator = EntityStoreCoordinator()
    let mutatingStore = EntityStore<ValueEntity>(
      entities: [.init(1): .init(id: 1, value: 1)],
      coordinator: coordinator
    )
    let readingStore = EntityStore<ValueEntity>(
      entities: [.init(2): .init(id: 2, value: 2)],
      coordinator: coordinator
    )
    let mutationStarted = TestSignal()
    let allowMutationToFinish = DispatchSemaphore(value: 0)
    let readStarted = TestSignal()
    let readFinished = TestSignal()
    let work = DispatchGroup()
    let workFinished = TestSignal()

    work.enter()
    DispatchQueue.global().async {
      mutatingStore.updateOrCreate(
        id: .init(1),
        update: { _ in
          mutationStarted.signal()
          _ = allowMutationToFinish.wait(timeout: .now() + .seconds(5))
        },
        create: { .init(id: 1, value: 1) }
      )
      work.leave()
    }

    #expect(await mutationStarted.wait(for: .seconds(5)))

    work.enter()
    DispatchQueue.global().async {
      readStarted.signal()
      _ = readingStore.get(by: .init(2))
      readFinished.signal()
      work.leave()
    }

    work.notify(queue: .global()) {
      workFinished.signal()
    }

    #expect(await readStarted.wait(for: .seconds(5)))
    #expect(await !readFinished.wait(for: .milliseconds(100)))

    allowMutationToFinish.signal()

    #expect(await readFinished.wait(for: .seconds(5)))
    #expect(await workFinished.wait(for: .seconds(5)))
  }

  @Test func getAllReturnsIndependentSnapshot() {
    let store = EntityStore<ValueEntity>()
    store.add(.init(id: 1, value: 1))

    let snapshot = store.getAll()
    store.add(.init(id: 2, value: 2))

    #expect(snapshot.map(\.typedID) == [.init(1)])
    #expect(Set(store.getAll().map(\.typedID)) == [.init(1), .init(2)])
  }

  @MainActor
  @Test func basic() async {
    
    let store = NormalizedStore()
    
    StateGraphGlobal.computedEnvironmentValues.withLock { values in
      values.normalizedStore = store
    }
    
    let user = User.init(
      id: "user1",
      name: "John Doe",
      age: 30
    )
    
    store.users.add(user)
    
    let post = Post.init(
      id: UUID().uuidString,
      title: "My first post",
      content: "This is my first post",
      author: user
    )
    
    store.posts.add(post)

    #expect(user.posts.count == 1)
    
    print(await NodeStore.shared.graphViz())
      
  } 

  @MainActor
  @Test func randomDataGeneration() async {
    
    let task = Task {
      let store = NormalizedStore()
      
      StateGraphGlobal.computedEnvironmentValues.withLock { values in
        values.normalizedStore = store
      }
      
      // ランダムなユーザーを生成
      let users = (0..<5).map { i in
        User(
          id: "user\(i)",
          name: "User \(i)",
          age: Int.random(in: 18...80)
        )
      }
      
      // ユーザーをストアに追加
      users.forEach { store.users.add($0) }
      
      // 各ユーザーに対してランダムな投稿を生成
      let posts = users.flatMap { user in
        (0..<Int.random(in: 1...3)).map { i in
          Post(
            id: UUID().uuidString,
            title: "Post \(i) by \(user.name)",
            content: "Content for post \(i)",
            author: user
          )
        }
      }
      
      // 投稿をストアに追加
      posts.forEach { store.posts.add($0) }
      
      // 各投稿に対してランダムなコメントを生成
      let comments = posts.flatMap { post in
        (0..<Int.random(in: 0...5)).map { i in
          Comment(
            id: UUID().uuidString,
            text: "Comment \(i) on post: \(post.title)",
            post: post,
            author: users.randomElement()!
          )
        }
      }
      
      // コメントをストアに追加
      comments.forEach { store.comments.add($0) }
      
      // 検証
      #expect(store.users.count == 5)
      #expect(store.posts.count == posts.count)
      #expect(store.comments.count == comments.count)
      
      // 各ユーザーの投稿数を検証
      for user in users {
        #expect(user.posts.count == posts.filter { $0.author.id == user.id }.count)
      }
      
      // 各投稿のコメント数を検証
      for post in posts {
        #expect(post.allComments.count == comments.filter { $0.post.id == post.id }.count)
        #expect(post.activeComments.count == comments.filter { $0.post.id == post.id && !$0.isDeleted }.count)
      }
      
    }
    
    await task.value
    
    StateGraphGlobal.computedEnvironmentValues.withLock { values in
      values.normalizedStore = nil
    }
    
    await Task.yield()
    
    print(await NodeStore.shared.graphViz())
    
  }
}
