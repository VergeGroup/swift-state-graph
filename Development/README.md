# Spotify Client App

Spotify Web APIを使用したiOSクライアントアプリです。OAuth 2.0のAuthorization Code Flow with PKCEを使用してユーザー認証を行います。

## 機能

- ✅ Spotify OAuth認証
- ✅ ユーザープロフィール表示
- ✅ ログイン/ログアウト機能
- ✅ モダンなUI/UX
- ✅ StateGraphによる高度な状態管理
- ✅ リアクティブなデータフロー

## アーキテクチャ

このアプリはStateGraphライブラリを使用した高度な状態管理アーキテクチャを採用しています：

### StateGraphの特徴
- **@GraphStored**: プロパティをグラフ内で管理し、自動的に変更を追跡
- **@GraphComputed**: 他の状態から派生した計算プロパティを定義
- **リアクティブ**: 状態の変更が自動的にUIに反映される
- **型安全**: Swift の型システムを最大限に活用

### 状態管理の構造

```
SpotifyAuthState (Entity)
├── isAuthenticated: Bool
├── accessToken: String?
├── user: SpotifyUser?
├── errorMessage: String?
└── isLoading: Bool

SpotifyAuthService
├── authState: SpotifyAuthState (@GraphStored)
└── 認証ロジック

SpotifyAuthViewModel (UI Layer)
├── isAuthenticated (@GraphComputed)
├── user (@GraphComputed)
├── errorMessage (@GraphComputed)
├── isLoading (@GraphComputed)
└── UIアクション
```

## セットアップ手順

### 1. Spotify Developer Dashboard での設定

1. [Spotify Developer Dashboard](https://developer.spotify.com/dashboard/) にログイン
2. 「Create an App」をクリックして新しいアプリを作成
3. アプリ名と説明を入力
4. 「Edit Settings」を選択
5. Redirect URIsに以下を追加：
   ```
   spotify-auth://callback
   ```
6. 「Save」をクリック
7. 「Client ID」をコピー

### 2. アプリでの設定

1. `Development/SpotifyAuthService.swift` を開く
2. `clientId` の値を実際のClient IDに変更：
   ```swift
   private let clientId = "YOUR_SPOTIFY_CLIENT_ID" // ここを変更
   ```

### 3. Xcodeプロジェクト設定

1. Xcodeでプロジェクトを開く
2. プロジェクト設定から「Info」タブを選択
3. 「URL Types」セクションで「+」ボタンをクリック
4. URL Schemesに `spotify-auth` を追加

## ファイル構成

```
Development/
├── App.swift                   # アプリエントリーポイント
├── ContentView.swift           # メインナビゲーション
├── SpotifyAuthService.swift    # OAuth認証サービス (StateGraph)
│   ├── SpotifyAuthState        # 認証状態エンティティ
│   ├── SpotifyAuthService      # 認証ロジック
│   └── SpotifyAuthViewModel    # UI接続層
├── SpotifyLoginView.swift      # ログイン画面
├── SpotifyClient.swift         # Spotifyデータモデル
└── ...
```

## 主要コンポーネント

### SpotifyAuthState
- StateGraphエンティティとして認証状態を管理
- `@GraphStored`により変更が自動追跡される
- 認証、ユーザー情報、エラー、ローディング状態を含む

### SpotifyAuthService  
- OAuth 2.0 Authorization Code Flow with PKCEを実装
- `SpotifyAuthState`を通じて状態を管理
- ASWebAuthenticationSessionを使用した安全な認証

### SpotifyAuthViewModel
- UIレイヤーとStateGraphを接続
- `@GraphComputed`により状態の変更を自動的にUIに反映
- ObservableObjectとしてSwiftUIと統合

### SpotifyLoginView
- モダンなログイン画面
- リアクティブなUI（状態変更が自動反映）
- ローディング状態とエラーハンドリング

## 使用ライブラリ

- **SwiftUI**: ユーザーインターフェース
- **AuthenticationServices**: OAuth認証
- **CryptoKit**: PKCE実装
- **StateGraph**: 高度な状態管理
- **StateGraphNormalization**: エンティティ正規化

## StateGraphの利点

### 従来のObservableObjectとの比較

| 項目 | ObservableObject | StateGraph |
|------|------------------|------------|
| 状態追跡 | 手動の@Published | 自動の@GraphStored |
| 派生状態 | @Published computed | @GraphComputed |
| パフォーマンス | 全体再描画 | 必要な部分のみ更新 |
| 複雑な状態 | 管理が困難 | グラフ構造で整理 |
| テスト | モックが複雑 | 状態の分離が容易 |

### リアクティブデータフロー

```
認証イベント → SpotifyAuthService → SpotifyAuthState → UI自動更新
     ↓                ↓                    ↓             ↓
  authenticate()  状態変更通知        @GraphStored     SwiftUI再描画
```

## セキュリティ

- PKCE (Proof Key for Code Exchange) を使用
- Client Secretを使用しないため、モバイルアプリに適した実装
- State パラメータによるCSRF攻撃対策

## 必要な権限

- `user-read-private`: ユーザーの基本情報取得
- `user-read-email`: ユーザーのメールアドレス取得
- `playlist-read-private`: プライベートプレイリスト読み取り

## トラブルシューティング

### 認証エラーが発生する場合
1. Client IDが正しく設定されているか確認
2. Redirect URIがSpotify Developer Dashboardと一致しているか確認
3. URLスキームがXcodeプロジェクトに正しく追加されているか確認

### ビルドエラーが発生する場合
1. StateGraphライブラリが正しくインポートされているか確認
2. 必要なフレームワークがインポートされているか確認

## ライセンス

このプロジェクトはサンプル用途です。 