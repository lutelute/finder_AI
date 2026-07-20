# FinderAI正式リリース手順

## 現在の状態

署名・notarization・Sparkle配布・GitHub公開のパイプラインは実装済みです。ただし、現在はApple Developer ProgramのDeveloper ID Application証明書がないため、正式リリースはできません。`FinderAI Local Signing`やad-hoc署名を指定しても、本番スクリプトはGitHubへ書き込む前に停止します。

初回のDeveloper ID版では、公開済み1.2.2（ローカル証明書）から署名主体が変わります。bundle IDとSparkle EdDSA鍵は維持していますが、実際の1.2.2→新ビルド更新を検証するまで公開確認フラグを設定しないでください。

## Apple側で必要なもの

1. Apple Developer Programへ加入する。
2. `Developer ID Application: 名前 (TEAMID)`証明書を作成する。
3. App Store Connect APIのNotary用キー（`.p8`、Key ID、必要ならIssuer ID）を作る。またはローカルKeychainへnotarytool profileを保存する。
4. 既存のSparkle秘密鍵を安全にバックアップする。新しい鍵へ置き換えない。

ローカルのnotary profileは、秘密値をスクリプト引数へ残さず次のように登録できます。

```bash
xcrun notarytool store-credentials FinderAI-notary \
  --apple-id "APPLE_ID" \
  --team-id "TEAM_ID" \
  --password "APP_SPECIFIC_PASSWORD"
```

## ローカルから公開する

バージョンとbuild番号を先に`Resources/Workspace-Info.plist`へコミットし、mainをorigin/mainと完全に一致させます。その後に実機の旧版から更新テストを済ませます。

```bash
export FINDERAI_SIGN_IDENTITY='Developer ID Application: NAME (TEAMID)'
export FINDERAI_NOTARY_PROFILE='FinderAI-notary'
export FINDERAI_CONFIRMED_LEGACY_UPDATE_TEST=1
./scripts/release.sh 1.7.0 path/to/release-notes.md
```

Sparkle秘密鍵は通常、既存のログインKeychainから読みます。Keychainを使わない場合だけ、Sparkleの`generate_keys -x`で安全な場所へ書き出したファイルを`SPARKLE_PRIVATE_KEY_FILE`へ指定します。秘密鍵ファイルをリポジトリ、`dist`、release assetへ置いてはいけません。

## GitHub Actionsから公開する

`production-release` Environmentを作り、必要なら承認者を設定します。RepositoryまたはEnvironment secretsへ次を登録します。

| Secret | 内容 |
|---|---|
| `DEVELOPER_ID_P12_BASE64` | Developer ID Application証明書と秘密鍵を含むP12をbase64化した値 |
| `DEVELOPER_ID_P12_PASSWORD` | P12のpassword |
| `NOTARY_KEY_P8_BASE64` | App Store Connect API `.p8`をbase64化した値 |
| `NOTARY_KEY_ID` | API Key ID |
| `NOTARY_ISSUER_ID` | Team API keyのIssuer ID。Individual keyなら空でよい |
| `SPARKLE_PRIVATE_KEY` | Sparkle `generate_keys -x`の出力内容 |

Actionsの「Release notarized FinderAI」を手動実行し、version、release notes、旧版更新テスト済みの確認を入力します。workflowは一時Keychainを作り、終了時に証明書と鍵ファイルを消します。

## パイプラインが保証すること

- Developer ID Application以外は拒否し、ad-hoc／自己署名へフォールバックしない
- Hardened Runtime、secure timestamp、TeamIdentifier、`get-task-allow`不在を検査
- Sparkle内蔵helperを公式の順序とentitlement維持規則で署名
- `notarytool`の`Accepted`以外を拒否し、監査ログを保存
- staple後にZIPを作り直し、展開後の署名・ticket・Gatekeeperを再検証
- 埋め込み`SUPublicEDKey`とリリース秘密鍵の一致を検査
- update ZIPとappcastをEdDSA署名し、SHA-256一覧を生成
- GitHub Releaseはまずdraftにし、3 assetが揃った場合だけLatestとして公開

## 初回Developer ID版の必須テスト

正式公開前に、ネットワークを切り替え可能なテスト用appcastまたは一時releaseを使い、次を実機で確認します。

1. GitHub公開版1.2.2を新規ユーザー環境へインストールする。
2. 同じ`SUPublicEDKey`で署名したDeveloper ID候補版をappcastへ置く。
3. 「アップデートを確認…」から候補版を取得する。
4. FinderAIを通常終了し、Developer ID版へ置換されることを確認する。
5. version、build、commit、Developer ID Authority、TeamIdentifierを確認する。
6. さらに次のテスト版を配信し、Developer ID版同士でも自動更新できることを確認する。

強制終了ではSparkleの終了時置換が走らないため、更新試験は通常終了で行います。
