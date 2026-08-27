# Power Automate × AI エージェント 自動修正ループ検証（PoC）

Power Automate のクラウドフローを **AI コーディングエージェント（Claude Code）と CLI / API だけで開発・修正できるか** を検証した PoC の記録です。

```text
AI がフロー定義を編集 → pac solution pack/import でデプロイ → API でフローを起動
   → 実行結果とアクション単位のエラーを取得 → AI が原因を特定して修正 → 再デプロイ → Success
```

**結論: この修正ループは成立し、1コマンドで全周を自走させられる。**

- **第一段階** — 意図的に壊したフローを AI が解析・修正し、CLI 経由の再デプロイで正常化するまでを実機で一周（成功条件10項目すべて達成）。実行とエラー確認は人間が担当。
- **第二段階** — `.\scripts\repair-loop.ps1` の**1コマンド**で「デプロイ → 起動 → 監視 → AI 修正 → 再デプロイ」を人間の介入ゼロで回すことに成功（成功条件10項目すべて達成）。

第二段階の実測ログ（1周 約2分・判定7秒）は [docs/power-automate-ai-verification-log.md](docs/power-automate-ai-verification-log.md) の「第二段階」以降に、設計判断は [docs/power-automate-ai-phase2-plan.md](docs/power-automate-ai-phase2-plan.md) にあります。

## 検証で分かったこと

### CLI と AI でできること

| できること | 手段 |
| --- | --- |
| Solution の取得・展開 | `pac solution export` / `unpack` |
| フロー定義の解析・修正・機能追加 | AI が unpack 済み JSON を直接編集（Git で差分を追跡） |
| 変更のデプロイ | `pac solution pack` / `import --force-overwrite --publish-changes` |
| 稼働中フローの無停止更新 | import 前にオンなら、import 後もオンのまま反映される |
| **下書きフローの有効化** | Flow API `POST /flows/{id}/start`（第二段階で解決） |
| **フローの起動** | Flow API `POST /flows/{id}/triggers/manual/run`（第二段階で解決） |
| **実行結果の即時取得** | Flow API `GET /flows/{id}/runs` — **数秒**で反映 |
| **失敗アクションの特定** | Flow API `GET /flows/{id}/runs/{runId}/actions` |
| AI 修正の非対話実行 | `claude -p --permission-mode acceptEdits --allowedTools ...` |

### 手作業が残ること

| 残る手作業 | 理由 |
| --- | --- |
| フローの新規作成（最初の1本） | pac にクラウドフローを新規作成するコマンドがない。Seed は Designer で作る |
| 認証の初回サインイン | Flow API 用トークンはデバイスコードフローで取得する。以降はリフレッシュトークンで無人 |
| 日次の再サインイン（本テナントの場合） | リフレッシュトークンが非アクティブ12時間で失効する。常時無人運用にはサービスプリンシパルが必要 |

### つまずきポイント（重要）

- **`pac` CLI だけでは実行系に到達できない。** `pac auth token` は引数を取らず audience が `api.powerplatform.com` に固定で、スコープに Power Automate 系が含まれません。Flow API も Dataverse Web API も **401**。`pac env` にも書き込み系サブコマンドはありません。**別トークンの取得手段が必須**です。
- **アプリ登録は不要。** well-known パブリッククライアント（Azure CLI の `04b07795-…`）＋デバイスコードフローで `service.flow.microsoft.com` 向けトークンが取得でき、追加の管理者同意も不要でした。
- **ソリューションフローを API から起動するには接続参照を `embedded` にする必要がある。** 既定の `"runtimeSource": "invoker"` は呼び出し元が `X-MS-APIM-Tokens` ヘッダーでコネクション トークンを渡す前提で、素で叩くと `InvokerConnectionOverrideFailed` になります。
- **手動（Button）トリガーは API から入力を渡せない。** `triggers/manual/run` はリクエストボディをトリガーへ転送せず（ボディ7通りで検証）、`listCallbackUrl` も `ListCallbackUrlOperationBlocked` でブロックされます。入力を渡したいなら HTTP 要求トリガーが必要ですが、こちらは **Power Automate Premium ライセンス必須**（`MissingAdequateQuotaPolicy`）です。
- **コネクタのパラメータを壊すと、実行時ではなく保存・有効化時に失敗する。** Excel テーブル名を存在しない値にしたところ、有効化時の動的検証（`GetTable`）が 404 を連発し、Graph API に 429（`TooManyConsecutiveFailures`）でスロットリングされてフローを有効化できなくなりました。AI に書き換えさせる対象としては、動的検証が走らない**式・データ操作系が安全**です。
- **Dataverse の `flowrun` テーブルは遅く、エラー詳細も粗い。** 書き込みまで実測10〜79分の遅延があり、`errormessage` は `An action failed. No dependent actions succeeded.` のような汎用文言のみ。**Flow API の `/runs` と `/runs/{id}/actions` を使えば数秒でアクション単位の原因まで取得でき**、この制約は解消します。
- **import 直後はライセンス評価にラグがある。** 直前の定義で判定されて `/start` が一時的に 403 を返すため、有効化はリトライ前提で実装します。
- **Windows PowerShell 5.1 は BOM なし UTF-8 の `.ps1` を ANSI として読む。** 日本語リテラルが壊れて構文エラーになるため、**スクリプトは ASCII のみ**で書いています（日本語の説明は `docs/` 側）。

## リポジトリ構成

```text
docs/
  power-automate-ai-verification-plan.md   第一段階の検証計画（目的・対象フロー・16ステップ・成功条件）
  power-automate-ai-phase2-plan.md         第二段階の検証計画（起動・監視の方式比較と成功条件）
  power-automate-ai-verification-log.md    実施ログ（全ステップの実行コマンドと結果、判明した制約）
scripts/
  token.ps1              デバイスコード認証／リフレッシュ（DPAPI 暗号化してローカル保存）
  lib-flowapi.ps1        Flow API 共通ヘルパー
  deploy.ps1             pac solution pack → import
  trigger-flow.ps1       Flow API でフローを起動
  fetch-flow-runs.ps1    実行完了待ち＋失敗アクション詳細の取得
  repair-loop.ps1        1コマンドのオーケストレータ
prompts/
  repair-flow.md         AI 修正プロンプト（禁止領域・安全な修正対象を明記）
src/                     unpack した Solution ソース（AI の編集対象）
logs/latest-flow-run.json  取得した実行結果
local.config.json.example  環境固有値のテンプレート（実値は gitignore 済みの local.config.json に置く）
```

## 検証に使ったフロー

`GetAvailableHumanResources` — Excel の人材一覧から「稼働可能」な要員を取り出す最小構成のフローです。検証の主眼は業務ロジックではなく開発ループ自体にあるため、意図的に小さく作っています。

```text
手動トリガー（入力: スキル。API 起動時は空扱い）
  → Excel Online (Business) / List rows present in a table
  → Filter array（稼働状況 = 稼働可能 AND スキル部分一致）
  → Compose
```

## 再現するには

1. Power Platform 環境に Solution を作り、Designer で Seed フローを1本作成する
2. `pac auth create --environment https://YOURORG.crm7.dynamics.com/`
3. `local.config.json.example` を `local.config.json` にコピーし、自環境の値を入れる（値の調べ方はファイル内に記載）
4. `.\scripts\token.ps1 -Mode Request` → 表示された URL とコードでサインイン → `.\scripts\token.ps1 -Mode Poll`
5. `pac solution export` / `unpack` でソースを取得し、フロー定義の接続参照を `"runtimeSource": "embedded"` にする
6. `.\scripts\repair-loop.ps1`

引数はバージョンによって異なるため、実行前に `--help` で確認してください（検証時は pac 2.11.2）。

## 注記

本リポジトリは公開にあたり、テナント ID・環境 URL・SharePoint のサイト／ドライブ／ファイル ID・Connection Reference 名・アカウント情報を `YOURORG` / `YOUR-TENANT-ID` / `YOUR-FILE-ID` などのプレースホルダーへ置換しています。そのため `src/` のソースはそのままでは import できません（自環境の値に差し替える必要があります）。手順・コマンド・検証結果そのものはすべて実機で実行したものです。

`scripts/` は環境固有値を `local.config.json`（gitignore 済み）から読む設計のため、サニタイズ不要でそのまま公開しています。

## 今後（第三段階）

フロー自体の複雑化（ユーザー入力起点の人材検索、SharePoint / Dataverse / Teams / Planner など複数コネクタへの拡張）による実案件適用可能性の検証。第二段階で判明した「API 起動では入力を渡せない（Premium が前提）」制約が、ここで最も効いてきます。
