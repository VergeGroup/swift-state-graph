# SwiftUI から EntityCollection を使う — TanStack DB との対応

プロジェクト 42 の未完了 Todo を表示し、タップした Todo を完了にする。SwiftUI 側で必要な操作は次の 4 つ。

```swift
let query = TodoAdapter.Query.open(projectID: 42)
try await todos.collection.load(query)                    // GET。画面の .task から呼ぶ
let rows = todos.state.wrappedValue.results(for: query)   // 読み取り。body から何度でも読める
try await todos.collection.mutate(.complete(id))          // POST。ボタンから呼ぶ
try await todos.collection.load(query)                    // 未完了一覧の並びとメンバーを再取得
```

たとえば Todo 7 の完了に成功すると、サーバーは `{"id":7,"title":"原稿を書く","completed":true}` を返す。Swift ではこの時点で詳細画面にも完了が反映される。未完了一覧は次の GET で ID 7 が結果から外れたときに行が消える。TanStack DB の例ではボタンを押した時点でローカルの `completed` を更新するため、live query からその場で行が消える。

## 操作の対応表

| アプリがしたいこと | TanStack DB ＋ React | EntityCollection ＋ SwiftUI |
| --- | --- | --- |
| データの共有先を作る | `createCollection(queryCollectionOptions(…))`。同じ Collection を画面間で共有 | `EntityCollection(adapter:)` を共有。届いた snapshot を 1 つの `Stored` に代入 |
| 同じ Todo を識別する | `getKey: todo => todo.id` | `Todo.TypedID`。各クエリ結果は順序付き ID を持ち、実体は共通の `EntityStore` に置く |
| 未完了一覧を取得する | `useLiveQuery` の `where` → on-demand の `queryFn` → GET | `.task` → `load(.open(projectID:))` → アダプタの `load` → GET |
| 再描画で最新の値を読む | フックの `data` を読む。元の行が変わるとクエリ結果が差分更新される | `body` で `state.wrappedValue.results(for:)` を読む。`nil` は未取得、`[]` は取得済みで 0 件 |
| Todo の完了を永続化する | `createOptimisticAction` の `onMutate` で仮更新、`mutationFn` で POST と再取得。CRUD なら `onInsert / onUpdate / onDelete` も使える | `mutate(.complete(id))` → アダプタが POST → 返った行を `.upsert`。通信中は直前の確定値を表示 |
| 絞り込みや並びを更新する | ローカルの `where` / `orderBy` が行の変更に追従。例ではサーバーの確定状態も再取得 | 行の値は共有される。サーバーが決めるメンバーと順序は明示的に `load`。確定した `.delete(id)` は全結果から即座に除く |

## SwiftUI での組み込み

アプリのターゲットから `StateGraph` と `StateGraphNormalization` の両 product を参照する。既存の API クライアントがあるアプリなら、アダプタの `load` と `mutate` でそのメソッドを呼べる。以下では対応する HTTP リクエストまで見えるように `URLSession` で書いた。

### API との対応を書く

例の GET は対象プロジェクトの未完了 Todo を配列で返す。POST は更新後の Todo を 1 件返す。実際の API が `204 No Content` を返す場合は、アダプタが詳細を読み直してから確定値を返す、といった形でサービスの契約に合わせる。

```swift
import Foundation
import StateGraph
import StateGraphNormalization
import SwiftUI

nonisolated struct Todo: TypedIdentifiable, Decodable, Sendable {
  typealias TypedIdentifierRawValue = Int
  let number: Int
  let title: String
  let completed: Bool
  var typedID: TypedID { .init(number) }

  enum CodingKeys: String, CodingKey {
    case number = "id"
    case title, completed
  }
}

struct TodoAdapter: EntityCollectionAdapter {
  enum Query: Hashable { case open(projectID: Int) }
  enum Mutation { case complete(Todo.TypedID) }

  let baseURL: URL

  func load(_ query: Query) async throws -> [Todo] {
    switch query {
    case .open(let projectID):
      let url = baseURL.appending(path: "projects/\(projectID)/todos")
        .appending(queryItems: [URLQueryItem(name: "status", value: "open")])
      return try await send(URLRequest(url: url))
    }
  }

  func mutate(_ mutation: Mutation) async throws -> [EntityChange<Todo>] {
    switch mutation {
    case .complete(let id):
      var request = URLRequest(url: baseURL.appending(path: "todos/\(id.raw)/complete"))
      request.httpMethod = "POST"
      let confirmed: Todo = try await send(request)
      return [.upsert(confirmed)]
    }
  }

  private func send<Value: Decodable>(_ request: URLRequest) async throws -> Value {
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw URLError(.badServerResponse)
    }
    return try JSONDecoder().decode(Value.self, from: data)
  }
}
```

### 共有するコレクションを作る

```swift
final class Todos: Sendable {
  let state: Stored<EntityCollection<TodoAdapter>.Snapshot>
  let collection: EntityCollection<TodoAdapter>

  init(baseURL: URL) {
    let state = Stored<EntityCollection<TodoAdapter>.Snapshot>(wrappedValue: .init())
    self.state = state
    self.collection = EntityCollection(adapter: TodoAdapter(baseURL: baseURL)) {
      state.wrappedValue = $0
    }
  }
}
```

アプリのルートやサインインしたセッションで `let todos = Todos(baseURL: apiBaseURL)` を一度作り、一覧には `OpenTodosView(todos: todos, projectID: 42)`、詳細には同じ `todos` と選択した ID を渡す。詳細の `body` で `todos.state.wrappedValue.entities[id]` を読むと、一覧に含まれていた同じ Todo の確定値が表示される。

### 取得を開始し、結果を表示する

```swift
struct OpenTodosView: View {
  let todos: Todos
  let projectID: Int
  @State private var message: String?
  @State private var saving = false

  private var query: TodoAdapter.Query { .open(projectID: projectID) }

  var body: some View {
    VStack {
      if let message {
        Text(message)
        Button("一覧を再取得") { Task { await reload() } }
      }
      if let rows = todos.state.wrappedValue.results(for: query) {
        List(rows) { todo in
          Button(todo.title) { Task { await complete(todo.typedID) } }
            .disabled(saving || todo.completed)
        }
      } else if message == nil {
        ProgressView()
      }
    }
    .task(id: query) { await reload() }
  }

  private func reload() async {
    do {
      try await todos.collection.load(query)
      message = nil
    } catch {
      if !Task.isCancelled { message = "一覧を取得できませんでした" }
    }
  }

  private func complete(_ id: Todo.TypedID) async {
    guard !saving else { return }
    saving = true
    defer { saving = false }
    do {
      try await todos.collection.mutate(.complete(id))
    } catch {
      message = "完了を確認できませんでした"
      return
    }
    await reload()
  }
}
```

完了 POST が成功してから一覧の GET が失敗した場合、ボタン「一覧を再取得」は GET だけを再試行する。完了した Todo の確定値はストアに残る。

### Todo をクラスにする場合

上の `struct Todo` をこの定義に差し替えても、同じアダプタ・一覧画面を使える。ID は固定し、変化する値を `@GraphStored` に置く。

```swift
nonisolated final class Todo: TypedIdentifiable, Decodable, Sendable {
  typealias TypedIdentifierRawValue = Int
  let typedID: TypedID

  @GraphStored var title: String
  @GraphStored var completed: Bool

  private enum CodingKeys: String, CodingKey { case id, title, completed }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    typedID = .init(try values.decode(Int.self, forKey: .id))
    title = try values.decode(String.self, forKey: .title)
    completed = try values.decode(Bool.self, forKey: .completed)
  }
}
```

詳細画面には ID を渡し、`body` の中で現在のインスタンスを解決する。

```swift
struct TodoDetail: View {
  let todos: Todos
  let id: Todo.TypedID

  var body: some View {
    if let todo = todos.state.wrappedValue.entities[id] {
      Label(todo.title, systemImage: todo.completed ? "checkmark.circle.fill" : "circle")
    }
  }
}
```

同じインスタンスの `title` を更新すると、そのプロパティを読んだ画面に反映される。この代入はローカルな変更なので、サーバーにも反映する操作はアダプタの `mutate` を通す。

この例では GET と POST のレスポンスをデコードするたびに新しい `Todo` ができる。`load` や `.upsert` はストアの同じ ID のエントリを差し替える。詳細が ID を持っていれば新しい `Todo` を読み直せる。以前の `Todo` を直接保持しているコードは、引き続き以前のインスタンスを読む。また、クラスを含む過去の snapshot は各インスタンスへの参照を持つため、フィールドの履歴を保存する用途には別の値コピーが必要になる。

オブジェクト自体を長く保持し、同期後も `===` を保つ設計では、ID ごとの既存インスタンスに受信値を適用する処理が必要になる。パッケージには `EntityStore.updateOrCreate` と `@InitAndUpdate` がある。現在の `EntityCollection` はこのインプレース更新を自動では行わない。

## 同じ操作を TanStack DB で書く

React 側はプロジェクトごとの Collection をアプリで一度作り、一覧と詳細に渡す。プロジェクト ID は URL と Query key に含める。下の `queryFn` はこの画面が使う `completed == false` を `status=open` に変換する。条件のない取得に対しては全件を返せる API を想定している。ページングを追加するときは取得範囲も API に対応付ける。

```tsx
import { QueryClient } from '@tanstack/query-core'
import { createCollection, createOptimisticAction, eq, useLiveQuery } from '@tanstack/react-db'
import { parseLoadSubsetOptions, queryCollectionOptions } from '@tanstack/query-db-collection'

type Todo = { id: number; title: string; completed: boolean }

export function projectTodos(projectID: number, queryClient: QueryClient) {
  const todos = createCollection(queryCollectionOptions({
    queryClient,
    queryKey: ['projects', projectID, 'todos'],
    getKey: (todo: Todo) => todo.id,
    syncMode: 'on-demand',
    queryFn: async ({ meta, signal }): Promise<Todo[]> => {
      const { filters } = parseLoadSubsetOptions(meta?.loadSubsetOptions ?? {})
      const open = filters.some(f =>
        f.field.join('.') === 'completed' && f.operator === 'eq' && f.value === false
      )
      const path = `/projects/${projectID}/todos${open ? '?status=open' : ''}`
      const response = await fetch(path, { signal })
      if (!response.ok) throw new Error(`GET ${path}: ${response.status}`)
      return response.json()
    },
  }))

  const complete = createOptimisticAction<number>({
    onMutate: id => {
      todos.update(id, draft => { draft.completed = true })
    },
    mutationFn: async id => {
      const response = await fetch(`/todos/${id}/complete`, { method: 'POST' })
      if (!response.ok) throw new Error(`POST complete: ${response.status}`)
      await todos.utils.refetch()
    },
  })
  return { todos, complete }
}
```

```tsx
import { useState } from 'react'

function OpenTodos({ model }: { model: ReturnType<typeof projectTodos> }) {
  const [error, setError] = useState<string>()
  const { data, isLoading, isLoadingError } = useLiveQuery(q =>
    q.from({ todo: model.todos }).where(({ todo }) => eq(todo.completed, false))
  )
  if (isLoadingError) return <p>一覧を取得できませんでした</p>
  if (isLoading) return <p>読み込み中</p>

  async function complete(id: number) {
    setError(undefined)
    try {
      await model.complete(id).when('settled')
    } catch {
      setError('完了を確認できませんでした')
    }
  }
  return <>
    {error && <p>{error}</p>}
    {data.map(todo =>
      <button key={todo.id} onClick={() => complete(todo.id)}>{todo.title}</button>
    )}
  </>
}
```

アプリでの生成例は `const model = projectTodos(42, queryClient)`、画面は `<OpenTodos model={model} />`。TanStack Query の `queryKey` は取得キャッシュを識別し、TanStack DB の live query は Collection の行に適用する条件を表す。Swift の `TodoAdapter.Query` は、取得操作の指定と、取得済みの順序付き ID を引くキーの両方を担う。

## Swift 版でアプリが決めること

- **いつ通信するか。** `load` は呼ぶたびにアダプタを実行する。画面の表示、更新操作、書き込み後など、必要なタイミングをアプリが選ぶ。同じコレクションの読み書きは直列に実行される。
- **どの条件をサーバーに渡すか。** `.open(projectID:)` のようにアダプタの型に表す。ロード済みデータをさらに絞ったり結合したりする表示は `Computed` で記述できる。その Swift クロージャを HTTP の条件へ変換する機能や、TanStack DB の差分 JOIN エンジンは現在の実装範囲外。
- **どの範囲でデータを共有するか。** 同じコレクションの実体と検索結果はメモリ内に保持される。ログインユーザーが変われば、新しいセッションに新しい `Todos` を渡す。

Swift 例は Swift 6.3.3 で型検査し、アプリのモデルからローカル HTTP サーバーに対して GET → POST → GET を実行した。TypeScript 例は `@tanstack/react-db 1.0.0-rc.1.5`、`@tanstack/query-db-collection 1.5.2`、`@tanstack/query-core 5.108.2` で型検査し、同じ条件の live query とモック API で楽観的更新・確定後の再取得を確認した。

[Swift 実装](https://github.com/VergeGroup/swift-state-graph/pull/158) · [TanStack DB の Query Collection](https://tanstack.com/db/latest/docs/collections/query-collection) · [Live Queries](https://tanstack.com/db/latest/docs/guides/live-queries) · [Mutations](https://tanstack.com/db/latest/docs/guides/mutations)
