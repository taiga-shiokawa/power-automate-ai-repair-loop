# Power Automate × AI エージェント 自動修正ループ検証（PoC）

Power Automate のクラウドフローを **AI コーディングエージェント（Claude Code）と Power Platform CLI（pac）だけで開発・修正できるか** を検証した PoC の記録です。

```text
AI がフロー定義を編集 → pac solution pack/import でデプロイ → 実行
   → FlowRun からエラー取得 → AI が原因を特定して修正 → 再デプロイ → Success
```

**結論: この修正ループは成立する。** 意図的に壊したフローを AI が解析・修正し、CLI 経由の再デプロイで正常化するまでを実機で一周させ、検証計画に定めた成功条件10項目をすべて達成しました。さらに既存フローへの機能追加（トリガーへの入力項目追加・フィルタ条件の拡張）も、Designer を一切使わずソース編集と CLI だけで反映・動作確認しています。

## 検証で分かったこと

### CLI と AI でできること

| できること | 手段 |
| --- | --- |
| Solution の取得・展開 | `pac solution export` / `unpack` |
| フロー定義の解析・修正・機能追加 | AI が unpack 済み JSON を直接編集（Git で差分を追跡） |
| 変更のデプロイ | `pac solution pack` / `import --force-overwrite --publish-changes` |
| 稼働中フローの無停止更新 | import 前にオンなら、import 後もオンのまま反映される |
| 実行結果・エラーの取得 | `pac env fetch` で Dataverse の `flowrun` テーブルを照会 |

### 手作業が残ること

| 残る手作業 | 理由 |
| --- | --- |
| フローの新規作成（最初の1本） | pac にクラウドフローを新規作成するコマンドがない。Seed は Designer で作る |
| 下書き状態のフローの有効化 | `--activate-plugins` は「import 前にオンだったものをオンに戻す」だけで、下書きからの有効化はできない |
| フローの実行起動 | 手動トリガーのため。HTTP トリガー化すれば自動化できる見込み（第二段階の課題） |
| pac の再認証 | リフレッシュトークンが非アクティブ12時間で失効する |

### つまずきポイント（重要）

- **コネクタのパラメータを壊すと、実行時ではなく保存・有効化時に失敗する。** Excel テーブル名を存在しない値にしたところ、有効化時の動的検証（`GetTable`）が 404 を連発し、Graph API に 429（`TooManyConsecutiveFailures`）でスロットリングされてフローを有効化できなくなりました。AI に書き換えさせる対象としては、動的検証が走らない**式・データ操作系が安全**です。
- **FlowRun は即時ではなく、エラー詳細も粗い。** Dataverse への書き込みまで実測10〜79分の遅延があり、`errormessage` は `An action failed. No dependent actions succeeded.` のようなフローレベルの汎用文言のみで、どのアクションがなぜ失敗したかは含まれません。実用的な自動修正ループには、フロー内にエラー自己通報を仕込むなどの補完が要ります。
- **`pac auth token` は Dataverse Web API には使えない。** audience が異なるため 401 になります（Power Platform API 用）。実行ログの取得は `pac env fetch`（FetchXML）が現実的な経路でした。

## リポジトリ構成

```text
docs/
  power-automate-ai-verification-plan.md   検証計画（目的・対象フロー・16ステップ・成功条件）
  power-automate-ai-verification-log.md    実施ログ（全ステップの実行コマンドと結果、判明した制約）
src/                                       unpack した Solution ソース（AI の編集対象）
  Workflows/GetAvailableHumanResources-*.json      フロー定義本体
  Other/Solution.xml, Customizations.xml           Solution マニフェスト
logs/latest-flow-run.json                  取得した FlowRun（Failed 実行）
```

`docs/power-automate-ai-verification-log.md` に、実行した全コマンドとその出力、失敗した試行とその原因分析まで時系列で残しています。

## 検証に使ったフロー

`GetAvailableHumanResources` — Excel の人材一覧から「稼働可能」な要員を取り出す最小構成のフローです。検証の主眼は業務ロジックではなく開発ループ自体にあるため、意図的に小さく作っています。

```text
手動トリガー（入力: スキル）
  → Excel Online (Business) / List rows present in a table
  → Filter array（稼働状況 = 稼働可能 AND スキル部分一致）
  → Compose
```

## 再現するには

1. Power Platform 環境に Solution を作り、Designer で Seed フローを1本作成する
2. `pac auth create --environment https://YOURORG.crm7.dynamics.com/`
3. `pac solution export --name <solution> --path .\solution.zip --managed false`
4. `pac solution unpack --zipfile .\solution.zip --folder .\src --allowWrite true --allowDelete true`
5. `src/` 配下のフロー定義を AI に編集させる
6. `pac solution pack --zipfile .\dist\solution.zip --folder .\src`
7. `pac solution import --path .\dist\solution.zip --force-overwrite --activate-plugins --publish-changes`

引数はバージョンによって異なるため、実行前に `--help` で確認してください（検証時は pac 2.11.2）。

## 注記

本リポジトリは公開にあたり、テナント ID・環境 URL・SharePoint のサイト／ドライブ／ファイル ID・Connection Reference 名・アカウント情報を `YOURORG` / `YOUR-TENANT-ID` / `YOUR-FILE-ID` などのプレースホルダーへ置換しています。そのため `src/` のソースはそのままでは import できません（自環境の値に差し替える必要があります）。手順・コマンド・検証結果そのものはすべて実機で実行したものです。

## 今後（第二段階）

フロー起動まで含めた完全自動ループ（1コマンドで デプロイ → 実行 → 監視 → AI 修正 → 再デプロイ を回す）を検証予定です。課題は Dataverse 用トークンの取得手段と、FlowRun の反映遅延への対処です。
