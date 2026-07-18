# Implementation Notes - swift-state-graph PR #114

- cwd: `/Users/hiroshi.kimura/.codex/worktrees/64a6/swift-state-graph`
- branch: `codex/pr-114-test-semantics` (based on PR #114 head `8cbd47e`)
- started at: 2026-07-19 (Asia/Tokyo)
- note owner: Codex

## 設計判断

- `Equatable` な `Stored` への同値代入は、現在は `shouldNotify` で通知前に除外される。そのため既存の同値代入テストを「再入防止」の根拠にはせず、同値通知抑制のテストとして評価し直す。
- 再入防止は、通知が実際に発生する non-Equatable 値で評価する。同じ tracking handler が再実行されないことに加え、別 handler は更新を受け取ることを確認し、通知抑制による見かけ上の成功と区別する。
- PR で使われていた non-Equatable class は `AnyObject` 用の identity comparator を通るため、default の always-notify 経路を明示できる non-Equatable value type に変更する。
- `mixedChangedAndUnchangedValues` は従来どちらも同値代入だったため、片方を実際の値変更にし、Equatable 抑制と再入防止を同じケースで評価する。
- review feedback を受け、`TrackingRegistration.perform()` の再入防止コメントは簡略化せず、通知 predicate の3経路、registration の収集、自己再入の循環、peer observer を維持する理由、non-Equatable の具体例まで記述する。

## 逸脱点

- 現時点ではなし。

## トレードオフ

- 単一 handler の呼び出し回数だけでは Equatable 判定と再入防止を区別できない。独立した読み取り handler の呼び出し回数も評価することで、テストの観測点を増やす方針を採る。
- tracking group の再実行は `Task` により scheduling される。既存テストに合わせて 100ms の bounded wait を維持した。正の peer 通知を event-driven に待つ案も検討したが、自己再入がないことの確認には結局 quiet window が必要であり、今回の原因分離には counter の組み合わせを優先した。

## 検証

- 履歴確認: 再入防止テスト群は `76626f9`（PR #82、2025-10-22）、Equatable/identity 通知抑制は `f8d7abe`（PR #90、2026-04-17）で追加されている。
- 変更前: `swift test --build-system native --filter infiniteLoopWhenNonEquatable` が成功し、mutating handler は1回、peer handler は2回だった。
- 変更後: `swift test --build-system native --filter GraphTrackingGroupTests` が成功（19 tests）。新しい対になる評価は Equatable が `peer=1 / mutating=1`、non-Equatable が `peer=2 / mutating=1`。
- 対になる2テストを `--maximum-repetitions 20 --repeat-until fail --skip-build` で反復し、全20回成功した。
- 詳細コメントへの review feedback 反映後、対になる2テストを `--skip-build` で再実行し、2 tests が成功した。`git diff --check` も成功。
- publish target は PR #114 の head branch `muukii/recursive-update-tests`。remote head とローカルの変更元はいずれも `8cbd47e` で一致することを push 前に確認した。
- build/test には既存 warning がある。今回の変更に起因する新しい warning は確認されていない。

## 未解決の確認事項

- なし。

## 最終サマリー

- `GraphTrackingGroupTests` の同値代入と再入防止を、peer/mutating の2カウンターで原因別に評価するよう更新した。
- non-Equatable テストを identity comparator の class から always-notify の value type へ変更した。
- `TrackingRegistration.perform()` の古い「setter は常に通知する」「TaskLocal」という説明を、現在の通知 predicate と `ThreadLocal.registration` に合わせて更新した。
- review feedback に合わせ、上記コメントを現行実装に即した詳細な説明へ拡充した。
