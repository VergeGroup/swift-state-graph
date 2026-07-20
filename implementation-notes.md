# Implementation Notes - swift-state-graph PR #116

- cwd: `/Users/hiroshi.kimura/.codex/worktrees/e506/swift-state-graph`
- branch: `codex/lazy-node-observation-registrar`
- PR: [VergeGroup/swift-state-graph#116](https://github.com/VergeGroup/swift-state-graph/pull/116)
- resumed at: 2026-07-21 (Asia/Tokyo)
- note owner: Codex

## 設計判断

- PR #116 の head branch `codex/lazy-node-observation-registrar` をこの worktree で直接追跡する。作業開始時点の local HEAD と remote head はともに `31c9bf13e00e4d7b5b1d59f748495ba0d68a032b`。
- `NodeObservationRegistrar` は node が単独所有する lifecycle holder なので `~Copyable` にした。内部から取り出す `ObservationRegistrar` 自体は reference-backed な copyable value のまま notification closure へ渡す。
- lazy initialization だけを既存 node lock で直列化し、`ObservationRegistrar.access` は lock を解放してから呼ぶ。`Stored` / `Computed` ともに `initialize under lock → access outside lock → value work` の順序にした。
- `access` を value read より後ろへは移さない。read と registration の間に mutation が入ると、古い値を返したにもかかわらず、その変更通知を受け取れない race が成立するため。
- node ごとの registrar が registration identity を分離するため、key path に node pointer を埋め込まない。固定の stored marker key path `\NodeObservationRoot<Owner>.wrappedValue` を使い、`\NodeObservationRoot<Stored<Int>>.wrappedValue` のように表示する。
- pointer identity の uniqueness / lifetime / concurrency tests は設計上不要になったため削除した。代わりに concrete node type と `wrappedValue` が表示されること、アドレスが表示されないこと、Sendable key path であること、同一 key path が別 registrar 間で分離されることを検証する。
- 今回の feedback を今後の実装にも適用できるよう、`~/mu-coding-style.html` に single-owner holder の `~Copyable` 化、外部 runtime work を internal lock の外へ置く境界、diagnostic identity の可読性を追記した。

## 逸脱点

- GitHub 上の review thread は 0 件だった。今回の3コメントは Codex の diff comment として受け取り、GitHub への reply や thread resolve は行っていない。
- `craft-implementation-notes` skill の標準保存先である Craft folderId はプロジェクト指示にない。AGENTS.md が明示しているローカル `implementation-notes.md` を更新している。
- `origin/main` の取り込みと draft 解除は行っていない。ユーザーの追加依頼により、今回の差分は PR #116 の既存 head branch へ commit / push する。

## トレードオフ

- getter は lazy initialization 用と value / graph bookkeeping 用に node lock を2回取得する。1回にまとめるより短いが、Apple Observation の内部同期へ node lock 保持中に入らず、PR #116 より前の lock boundary を維持することを優先した。
- 実 node の `wrappedValue` key path を直接使う案は、computed property のため `\Stored<Int>.<computed 0x...>` のようにアドレスを含んで表示される。readable な stored marker を持つ `NodeObservationRoot` を採用した。
- `NodeObservationRoot` は実データを持たない marker subject だが、registrar が node-local なので root や key path 自体に instance identity を持たせる必要はない。

## 検証

- 履歴確認: node lock 導入時から `79b216f`、`bd47f09`、`f8d7abe`、`5a25c7c`、`80a47c9` を経て、getter は一貫して `ObservationRegistrar.access` を node lock の外で実行していた。PR #116 の lazy initialization が初めてその境界を内側へ移していた。
- Apple Swift 6.3.3: `swift test --filter KeyPathTests` が成功。Observation と key path の2 suites、8 tests が成功した。
- Apple Swift 6.3.3: `swift test` が成功。17 XCTest tests と 144 Swift Testing tests が成功した。
- Apple Swift 6.4 / Xcode 27 beta 3: `swift build --target StateGraph` が成功した。出力された GraphTracking の isolation / deprecated continuation warnings と Documentation.docc warning は既存。
- `git diff --check` が成功した。

## 未解決の確認事項

- `origin/main` の PR #117 (`b551472`) を PR #116 に取り込むか。
- OS 27 runtime が必要な registrar deinit test は、今回も runtime execution していない。

## 現在地

- 3件の diff comment はローカル差分で対応済み。
- 変更対象は registrar / key path implementation、`Stored` / `Computed` の access boundary、関連 tests、実装ノート。
- repository 外では `~/mu-coding-style.html` を更新済み。
- repository 内の6ファイルは `codex/lazy-node-observation-registrar` へ1 commitで publish する。
