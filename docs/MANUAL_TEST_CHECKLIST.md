# FinderAI Workspace 実機チェックリスト

テスト日、macOS、ディスプレイ構成を記録し、未実施を合格扱いにしないでください。まず重要なファイルではなく、一時テストフォルダで行います。

## 起動とレイアウト

- [ ] `/Applications/FinderAI Workspace.app`が一つの通常ウインドウで開く
- [ ] 起動直後からサイドバー、一覧、検索、下部`TERMINAL`を操作できる
- [ ] Accessibility設定を要求しない
- [ ] ウインドウresizeで一覧とTerminalの左右端が常に一致する
- [ ] サイドバーdividerを160〜360ptで動かせる
- [ ] 最小820×520ptでも操作不能な重なりがない
- [ ] フルスクリーンと通常表示を往復できる
- [ ] 再度アプリを開いてもmain windowが増殖しない

## ナビゲーションと一覧

- [ ] ホーム、デスクトップ、書類、ダウンロード、GitHub、Macintosh HDへ移動できる
- [ ] 戻る、進む、親フォルダ、パンくずが正しい
- [ ] フォルダをダブルクリックすると同じwindow内で移動する
- [ ] ファイルをダブルクリックすると既定アプリで開く
- [ ] 名前／変更日／サイズ／種類のsortが動く
- [ ] 現在フォルダ検索が即時に絞り込み、解除で全件に戻る
- [ ] 再読み込みで外部変更を反映する
- [ ] 読めないフォルダで固まらずエラーを表示する

## 安全なファイル整理

- [ ] 新規フォルダが`新規フォルダ`、衝突時は`新規フォルダ 2`として作られる
- [ ] 改名後に項目が再選択される
- [ ] 既存名への改名は上書きせず拒否する
- [ ] dragで移動、Option+dragでコピーになる
- [ ] destinationに同名項目がある場合、どちらも変更せず拒否する
- [ ] フォルダを自身や子孫へdropできない
- [ ] 複数選択のゴミ箱操作で確認が出る
- [ ] ゴミ箱からFinderで復元できる
- [ ] 空白、日本語、引用符、`$()`を含む名前をshell評価せず扱える

## Terminal

- [ ] 閲覧だけではShell／Codex／Claudeプロセスが増えない
- [ ] `⌘J`、status button、header buttonのすべてで開閉できる
- [ ] 上端dragで160〜600ptに変更できる
- [ ] `Shell`でzshが現在フォルダから始まり、`pwd`が一致する
- [ ] `echo test`、日本語入力、copy、pasteが動く
- [ ] `＋`からShell／Codex／Claudeを選べる
- [ ] CLIなしの場合は対応項目が無効で、自動インストールしない
- [ ] 長い処理中に閉じても継続する
- [ ] 別フォルダへ移動しても既存sessionへ`cd`が送られない
- [ ] 元フォルダへ戻るとsession tabが再表示される
- [ ] 実行中sessionを閉じると確認が出る
- [ ] app終了のキャンセルでsessionが継続する
- [ ] app終了後も外部Terminal／Codex／Claudeは終了しない

## 障害時

- [ ] Documentsアクセスを拒否してもappとFinderが通常動作する
- [ ] File Provider待機中もmain windowが操作可能でspinnerが表示される
- [ ] 外部で表示中フォルダを削除してもクラッシュしない
- [ ] appを強制終了してもFinderへ影響しない

## 旧Finder overlayを使う場合だけ

- [ ] Accessibility許可後にFinder下端へbarが一つ表示される
- [ ] Finder移動、resize、最小化、複数window、Space切替へ追従する
- [ ] Finder自体のframeを変更しない
- [ ] overlayの制約を許容できない場合はWorkspace版へ戻る
