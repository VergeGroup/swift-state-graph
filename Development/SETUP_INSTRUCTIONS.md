# Spotifyクライアントアプリ セットアップ手順（StateGraph版）

## ⚠️ 重要：URLスキーム設定が必要です

このアプリはStateGraphライブラリを使用した高度な状態管理を採用しています。
アプリを正常に動作させるために、以下の手順でURLスキームを設定してください。

## 手順 1: Xcodeでプロジェクトを開く

1. `Development.xcodeproj` をXcodeで開きます

## 手順 2: URLスキームを追加

1. プロジェクトナビゲーターで「Development」プロジェクトをクリック
2. 「TARGETS」から「Development」を選択
3. 「Info」タブをクリック
4. 「URL Types」セクションを見つけて、「+」ボタンをクリック
5. 以下の情報を入力：
   - **URL Schemes**: `spotify-auth`
   - **Identifier**: `Spotify Auth` (任意)
   - **Role**: `Editor`

## 手順 3: Spotify Developer Dashboard設定

1. [Spotify Developer Dashboard](https://developer.spotify.com/dashboard/) にアクセス
2. 新しいアプリを作成または既存のアプリを選択
3. 「Edit Settings」をクリック
4. 「Redirect URIs」に以下を追加：
   ```
   spotify-auth://callback
   ```
5. 「Save」をクリック
6. 「Client ID」をコピー

## 手順 4: クライアントIDを設定

1. `Development/SpotifyAuthService.swift` を開く
2. 以下の行を変更：
   ```swift
   private let clientId = "YOUR_SPOTIFY_CLIENT_ID"
   ```
   を
   ```swift
   private let clientId = "実際のClient ID"
   ```
   に変更

## StateGraphアーキテクチャについて

このアプリは以下のStateGraph構造を使用しています：

### 状態フロー
```
SpotifyAuthState (@GraphStored)
    ↓
SpotifyAuthService (ビジネスロジック)
    ↓
SpotifyAuthViewModel (@GraphComputed)
    ↓
SpotifyLoginView (SwiftUI)
```

### 主要ファイル
- `SpotifyAuthState`: 認証状態を管理するエンティティ
- `SpotifyAuthService`: 認証ロジックとAPIコール
- `SpotifyAuthViewModel`: UIとStateGraphの接続層
- `SpotifyLoginView`: リアクティブなログイン画面

## ビルドと実行

設定完了後、以下のコマンドでビルドできます：
```bash
# iOS Simulatorでビルド
xcodebuild -project Development.xcodeproj -scheme Development -destination "platform=iOS Simulator,name=iPhone 16" build
```

## 動作確認

1. アプリを起動
2. 「Spotify Login」をタップ
3. 美しいグラデーション背景のログイン画面が表示される
4. 「Spotifyでログイン」ボタンをタップ
5. ローディングインジケーターが表示される
6. Spotifyの認証画面が開く
7. 認証完了後、ユーザー情報が表示される

## StateGraphの利点

✅ **自動状態追跡**: `@GraphStored`により状態変更が自動的に追跡される
✅ **リアクティブUI**: 状態変更が即座にUIに反映される  
✅ **パフォーマンス**: 必要な部分のみが再描画される
✅ **型安全**: Swiftの型システムを最大限活用
✅ **テスト容易性**: 状態とロジックが分離されている

## 確認事項

- ✅ URLスキームが正しく設定されている
- ✅ Spotify Developer DashboardでRedirect URIが設定されている
- ✅ Client IDが正しく設定されている
- ✅ StateGraphライブラリが正しくインポートされている

これらの設定が完了すると、StateGraphベースの高度な状態管理でSpotify認証が正常に動作します。 