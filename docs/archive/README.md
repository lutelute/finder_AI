# 過去の記録

その時点の状態を書き留めたもので、**いまの実装の説明ではありません。** 当時の
テスト数・版番号・画面の呼び方が今と違っていても、書き換えずに残してあります。
「なぜそう決めたのか」を後から辿るための資料です。

いまの説明は[ARCHITECTURE.md](../../ARCHITECTURE.md)と[README.md](../../README.md)に
あります。手で確かめる手順は[実機チェックリスト](../MANUAL_TEST_CHECKLIST.md)です。

| ファイル | 何の記録か | 時点 |
|---|---|---|
| [ROADMAP_1_3_TO_1_7.md](ROADMAP_1_3_TO_1_7.md) | 1.3〜1.7で何を入れるかの計画 | 2026-07-20 |
| [ROADMAP_1_11_TO_1_14.md](ROADMAP_1_11_TO_1_14.md) | 1.11〜1.14の計画 | 2026-08-10 |
| [SESSION_RECORD_2026-07-16.md](SESSION_RECORD_2026-07-16.md) | 作業セッションの記録 | 2026-07-16 |
| [SESSION_LIFECYCLE_RECORD_2026-07-20.md](SESSION_LIFECYCLE_RECORD_2026-07-20.md) | セッションの生存期間まわりの設計記録 | 2026-07-22 |
| [ARCHIVED_BRANCHES.md](ARCHIVED_BRANCHES.md) | マージされずに閉じたブランチを注釈付きタグへ退避した記録 | 2026-08-09 |

`ARCHIVED_BRANCHES.md`だけは今も引ける索引です。タグはブランチを消しても残ります。

```bash
git tag -n99 -l 'archive/*'
```
