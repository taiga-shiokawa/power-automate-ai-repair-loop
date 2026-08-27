# Power Automate × AIコーディングエージェント 自動修正ループ検証 — 実施ログ

計画: [power-automate-ai-verification-plan.md](power-automate-ai-verification-plan.md)

> **公開版についての注記**: テナント ID・環境 URL・SharePoint の各種 ID・Connection Reference 名・アカウント情報は、`YOURORG` / `YOUR-TENANT-ID` / `YOUR-FILE-ID` などのプレースホルダーに置換しています。手順・コマンド・検証結果はすべて実際に実行したものです。

## ステップ進捗サマリ

| Step | 内容 | 状態 |
| --- | --- | --- |
| 1 | 環境確認（pac / auth / solution list） | ✅ 完了（2026-08-27） |
| 2 | HumanResources.xlsx 配置 | ✅ 完了（2026-08-27・SharePoint グループサイト上） |
| 3 | Solution `AIFlowDevelopment` 作成 | ✅ 完了（2026-08-27） |
| 4 | Seed フロー `GetAvailableHumanResources` 作成 | ✅ 完了（2026-08-27） |
| 5 | 正常動作確認 | ✅ 完了（2026-08-27・手動実行成功をユーザー確認） |
| 6–7 | Solution export / unpack | ✅ 完了（2026-08-27） |
| 8 | AI による Solution 解析 | ✅ 完了（2026-08-27） |
| 9–10 | 意図的エラー注入 → pack/import | ✅ 完了（Filter array 式破壊方式・2026-08-27） |
| 11 | エラーになることを確認（手動実行） | ✅ 完了（2026-08-27・Filter array で Failed をユーザー確認） |
| 12 | FlowRun 取得 → JSON 保存 | ✅ 完了（2026-08-27・遅延約25分で到着、`logs/latest-flow-run.json` 保存） |
| 13–14 | AI 解析 → 修正 | ✅ 完了（2026-08-27・注入内容既知のため FlowRun 到着前に修正） |
| 15 | 再デプロイ → 実行 | ✅ 完了（2026-08-27・フローはアクティブ維持のまま CLI デプロイ） |
| 16 | Success 確認 | ✅ 完了（2026-08-27・ユーザー実行で Success 確認）— **第一段階 PoC 成功** |

---

## 2026-08-27 — Step 1: 環境確認

### 実施内容と結果

**1. pac CLI インストール確認 — ✅ OK**

```powershell
Get-Command pac
# C:\Users\USERNAME\.dotnet\tools\pac.exe

pac
# Microsoft PowerPlatform CLI
# Version: 2.11.2+g47bc199 (.NET 10.0.11)
```

- pac は .NET tool としてインストール済み。バージョン 2.11.2。
- `solution` サブコマンド（export / import / pack / unpack）が利用可能なことをヘルプで確認。
- ヘルプ上、`flow` サブコマンドは存在しない（計画どおり、フロー新規作成は Designer で行う前提で問題なし）。

**2. 認証プロファイル確認 — ✅ プロファイルあり**

```powershell
pac auth list
# Index Active Kind      Name User                       Cloud  Type Environment           Environment Url
# [1]   *      UNIVERSAL      user@example.com Public User example.com (default) https://YOURORG.crm7.dynamics.com/
```

- 対象環境: `https://YOURORG.crm7.dynamics.com/`（example.com default 環境）

**3. Solution 一覧取得 — ❌ 失敗（トークン失効）**

```powershell
pac solution list
# Error: Failed to connect to Dataverse
# AADSTS700082: The refresh token has expired due to inactivity.
# The token was issued on 2026-08-26T03:10:54Z and was inactive for 12:00:00.
```

- リフレッシュトークンが12時間の非アクティブで失効。Dataverse へ接続できない。
- テナントのポリシーによりトークン寿命が短い模様。**検証セッションの開始時には毎回 `pac auth list` → 失効していれば再認証、を前提に進める**（`scripts/auth.ps1` にこのチェックを組み込む予定）。

### 判明した環境情報

| 項目 | 値 |
| --- | --- |
| pac バージョン | 2.11.2+g47bc199 (.NET 10.0.11) |
| pac パス | `C:\Users\USERNAME\.dotnet\tools\pac.exe` |
| 環境 URL | `https://YOURORG.crm7.dynamics.com/` |
| 認証ユーザー | user@example.com |
| 認証の注意点 | リフレッシュトークンが非アクティブ12時間で失効する |

### 再認証と Step 1 完了（2026-08-27 同日）

ユーザーが `pac auth create --environment https://YOURORG.crm7.dynamics.com/` を実行し、ブラウザ認証に成功。直後の `pac solution list` は成功した。

```text
Unique Name                 Friendly Name                         Version         Managed
（社内ソリューション名のため非公開）                                        x.x.x.x         False
...（既存 7 件。うち Managed 1 件）
```

- 環境への CLI 接続・Solution 一覧取得を確認 → **Step 1 完了**。
- 検証用 Solution `AIFlowDevelopment` はまだ存在しない（Step 3 で作成予定）。
- 再認証後は即時に接続できたため、トークン失効時の復旧手順は「`pac auth create` の再実行」で確定。

### 次のアクション

1. **（人間）Step 2** — `HumanResources.xlsx` を OneDrive for Business / SharePoint に配置し、Excel テーブル `HumanResources` を作成する（データ例は計画書 §3.2）。
2. **（人間）Step 3** — Maker Portal で Solution `AIFlowDevelopment` を作成する。
3. **（人間）Step 4–5** — Designer で Seed フロー `GetAvailableHumanResources` を作成し、手動実行で「稼働可能」3名が取得できることを確認する。
4. **（AI）Step 6 以降** — `pac solution export` → `unpack` → 内部構造の解析へ進む。

---

## 2026-08-27 — Step 3 完了 / Step 4 進行中

- （人間）Maker Portal で Solution `AIFlowDevelopment` を作成 → **Step 3 完了**。
- （人間）Solution 内に手動トリガー（Manually trigger a flow）のみのフローを作成 → **Step 4 進行中**。
- 残作業: フロー名を `GetAvailableHumanResources` に設定（未確認）、Excel Online (Business) の List rows present in a table / Filter array / Compose の3アクションを追加（計画書 §3.3）。
- 前提: Step 2（`HumanResources.xlsx` の配置とテーブル `HumanResources` の作成）が未完なら先に実施する。

---

## 2026-08-27 — Step 4–5 完了（人間） / Step 6–8 完了（AI）

### Step 4–5: フロー完成と正常動作確認（人間）

ユーザーが Designer で3アクション（List rows present in a table / Filter array / Compose）を追加してフローを完成させ、手動実行に成功（Step 5 完了）。

### Step 6: Solution export — ✅ 成功

```powershell
pac solution export --name AIFlowDevelopment --path .\AIFlowDevelopment.zip --managed false --overwrite
# Solution export succeeded.
```

- 事前に `pac auth list` → `pac solution list` で接続確認（前回の再認証セッションがまだ有効だった）。
- 計画の注意どおり `pac solution export --help` / `unpack --help` で 2.11.2 の引数仕様を確認してから実行。

### Step 7: Solution unpack — ✅ 成功

```powershell
pac solution unpack --zipfile .\AIFlowDevelopment.zip --folder .\src --allowWrite true --allowDelete true
# Processing Component: Workflows
#  - GetAvailableHumanResources
```

### Step 8: Solution 内部構造の解析 — ✅ 完了

unpack 結果は4ファイル:

```text
src/
├─ Workflows/
│   ├─ GetAvailableHumanResources-F57394BC-E3A1-F111-B8DE-70A8A5876024.json  ← フロー定義本体（Logic Apps workflowdefinition 形式）
│   └─ GetAvailableHumanResources-F57394BC-E3A1-F111-B8DE-70A8A5876024.json.data.xml  ← Workflow メタデータ（StateCode=1/StatusCode=2 = 有効化済み）
└─ Other/
    ├─ Solution.xml        ← マニフェスト（UniqueName / Version 1.0.0.0 / RootComponent type=29 = クラウドフロー）
    └─ Customizations.xml  ← ほぼ空（言語 1041 のみ）
```

フロー定義 JSON の解析結果（計画 Step 8 の特定対象）:

| 対象 | 内容 |
| --- | --- |
| Trigger | `manual`（type: Request, kind: Button）。入力スキーマは空 |
| Excel アクション | `List_rows_present_in_a_table`（type: OpenApiConnection, operationId: `GetItems`） |
| Excel の source | `groups/YOUR-SHAREPOINT-GROUP-ID` — **SharePoint グループサイトのライブラリ**（個人 OneDrive ではない） |
| Excel の file | `YOUR-FILE-ID`（ファイル ID。metadata にヒント `/HumanResources.xlsx` あり） |
| Excel の table | **`{YOUR-TABLE-ID}`（GUID 参照。テーブル名の文字列ではない）** |
| Filter array | type: Query。`from: @outputs('List_rows_present_in_a_table')?['body/value']` / `where: @equals(item()?['稼働状況'], '稼働可能')` |
| Compose | `@body('Filter_array')` |
| Connection Reference | `yourpublisher_YourSolution.shared_excelonlinebusiness.shared-excelonlinebu-YOUR-CONNECTION-ID`（runtimeSource: invoker）。Solution.xml では MissingDependency 扱い（Active ソリューション側に実体があるため、同一環境への再 import では問題にならない想定） |

**Step 9 への重要な示唆**: Designer はテーブルを名前ではなく **GUID** で保存している。計画 §7 の「テーブル名を `HumanResources_ERROR` に変更」は、`table` パラメータの値を GUID から文字列 `HumanResources_ERROR` に置き換える形で実現する（Excel コネクタの table パラメータは名前/ID どちらも受け付けるため、存在しない名前を渡せば実行時エラーになる）。

### 次のアクション

1. **（AI）Step 9** — `src/Workflows/...json` の `table` パラメータを `HumanResources_ERROR` へ書き換え（エラー注入）。
2. **（AI）Step 10** — `pac solution pack` → `pac solution import`（事前に `--help` で引数確認）。
3. **（人間）Step 11** — フローを手動実行し、失敗することを確認。
4. **（AI）Step 12** — Dataverse Web API で FlowRun メタデータを確認し、Failed レコードを取得して `logs/latest-flow-run.json` へ保存。

---

## 2026-08-27 — Step 9–10 完了（AI）: エラー注入と CLI デプロイ

### Step 9: エラー注入 — ✅ 完了

`src/Workflows/GetAvailableHumanResources-*.json` の Excel アクションの `table` パラメータを、GUID `{YOUR-TABLE-ID}` から存在しないテーブル名 `HumanResources_ERROR` に置換。変更はこの1行のみ（Connection Reference・認証・環境固有 ID は不変更を git diff で確認）。

### Step 10: pack → import — ✅ 成功

```powershell
pac solution pack --zipfile .\dist\AIFlowDevelopment.zip --folder .\src
# Unmanaged Pack complete.

pac solution import --path .\dist\AIFlowDevelopment.zip --force-overwrite --activate-plugins --publish-changes
# Solution Imported successfully.
# The original workflow definition has been deactivated and replaced.
# Published All Customizations.
```

- import 時のメッセージ「The original workflow definition has been deactivated and replaced.」のとおり、**環境上のフロー定義が CLI 経由で上書きできることを確認**（成功条件 §11-4 を満たす）。
- `--activate-plugins` を付けているためフローは再有効化される想定だが、Step 11 の実行前に Designer 上でフローが「オン」になっているかの確認を推奨。

### 次のアクション

1. **（人間）Step 11** — フローを手動実行（Test → Manually）し、Excel アクションが失敗することを確認する。フローがオフになっていたらオンにしてから実行。
2. **（AI）Step 12** — Dataverse Web API で FlowRun エンティティのメタデータ（Entity Set Name・フィールド名）を確認し、Failed レコードを取得して `logs/latest-flow-run.json` へ保存。

---

## 2026-08-27 — Step 9 やり直し: テーブル名破壊は「設計時エラー」になり実行に到達できない（重要知見）

### 発生した問題

Step 10 のデプロイ後、ユーザーがフローをオンにしようとしたところ、保存/有効化が以下のエラーで失敗し、**フローを有効化できなくなった**。

```text
DynamicOperationRequestClientFailure:
The dynamic operation request to API 'excelonlinebusiness' operation 'GetTable'
failed with status code 'TooManyRequests'.
→ 429 Too many requests to Graph API (TooManyConsecutiveFailures)
   「セッション内の連続する API エラーが多すぎるため、要求が調整されました」
```

`pac env fetch` で workflow テーブルを照会すると statecode = **下書き（Draft）** のまま。import 時の `--activate-plugins` でも有効化されていなかった。

### 原因分析

1. **存在しないテーブル名は実行時ではなく、保存/有効化時の動的検証（`GetTable`）で捕まる**。Power Automate は保存・有効化のタイミングで Excel コネクタの動的オペレーションを呼び、パラメータを検証する。
2. 検証の `GetTable` が 404 を繰り返した結果、**Graph API がセッションをスロットリング（429 TooManyConsecutiveFailures）**し、クールダウン期間中は有効化そのものができなくなった。
3. つまり計画 §7 の「テーブル名を `HumanResources_ERROR` に変更」は **FlowRun（実行ログ）まで到達できず、修正ループ検証のエラー注入としては不適切**。

### 対応（エラー注入方式の変更）

- `table` パラメータを正規の GUID `{YOUR-TABLE-ID}` に復元。
- 代わりに **Filter array の `from` 式**を破壊: `body/value` → `body/values`（存在しないキー）。
  - Data Operation は connector の動的検証が走らないため、**保存・有効化は通る**。
  - 実行時は `from` が null になり Query アクションが必ず失敗する → Failed FlowRun が生成される。
- pack → import は成功（2回目）。ただし直後の照会でもフローは下書きのまま → **クールダウン待ち後に `--activate-plugins` 付き再 import で有効化を再試行**（実行中）。

### PoC としての学び

- **AI がフロー定義を書き換える際、コネクタの動的検証対象パラメータ（テーブル名・ファイル ID 等）を壊すと、デプロイは通っても有効化で詰まる**。AI 修正ループの変更対象としては式・データ操作系が安全。
- 連続失敗による Graph API スロットリングは有効化不能という形で跳ね返る。リトライ戦略にはクールダウン待ちが必須。
- `pac auth token` は Power Platform API（api.powerplatform.com）用で、**Dataverse Web API には 401 で使えない**（WhoAmI で確認）。Step 12 の FlowRun 取得は `pac env fetch`（FetchXML）を第一候補にする。
- モダンフローの有効化を CLI から直接行う手段は pac 2.11.2 には見当たらない（`--activate-plugins` 頼み。効かない場合はポータルから手動でオン）。

### クールダウン後の再試行結果（同日 7:19）

5分待機後に `pac solution import --force-overwrite --activate-plugins --publish-changes` を再実行 → import は成功したが、フローは**下書きのまま**。

- **結論: `--activate-plugins` では一度無効化されたモダンフローは再有効化されない**（本環境・pac 2.11.2 で2回確認）。
- 有効化はポータルの手動操作（フロー詳細ページの「オンにする」）に委ねる。テーブル参照は正規 GUID に戻してあるため、有効化時の GetTable 検証は成功する見込み。
- **Phase 2 への課題**: 完全自動ループには「import 後のフロー有効化」の自動化手段が必要（Dataverse Web API の workflow statecode 更新。要 Dataverse 用トークン取得手段 = az CLI か MSAL アプリ登録）。

---

## 2026-08-27 — Step 11 完了 / Step 12 保留中 / Step 13–15 実施

### Step 11: 実行エラー確認 — ✅ 完了（人間）

ユーザーがポータルからフローをオンにし（テーブル参照が正規に戻ったため有効化成功）、手動実行 → **Filter array アクションで Failed** をユーザーが確認。エラー注入方式の変更（式破壊）は意図どおり機能した。

### Step 12: FlowRun 取得 — 🔄 未達（ポーリング継続中）

- `pac env fetch`（FetchXML）で `flowrun` テーブルを照会可能なことを確認。属性: `name` / `status` / `errorcode` / `errormessage`（JSON） / `starttime` / `endtime` / `duration` / `triggertype` / `workflow`（lookup） / `workflowid` / `resourceid` / `modernflowtype` など。
- Failed レコードには `errorcode`（例: `ActionFailed`）と `errormessage`（JSON: code / message）が入ることを他フローの過去レコードで確認。
- **書き込み遅延は実測10〜79分**（今日の他フローレコードの starttime→createdon 差）。
- 懸念: 環境内の FlowRun 全レコードが `modernflowtype = CopilotStudioFlow`。標準クラウドフローが FlowRun に記録されるかは未確定 → ポーリングで確認中。
- `pac auth token` は Dataverse に 401（audience 違い）、az CLI 未インストールのため Power Automate Management API 経路も現状なし。環境 ID は `Default-YOUR-TENANT-ID`。

### Step 13–14: エラー解析と修正 — ✅ 完了（AI）

ユーザー指示「エラーを解決してください」により、FlowRun 到着を待たず修正を実施（エラー箇所は注入内容として既知。ユーザー報告「Filter array で失敗」とも一致）。

- 修正: `from` の `body/values` → `body/value`（1行）。ソースは正常系 baseline と完全一致に復帰（git diff で確認）。
- 本来のループでは Step 12 の `latest-flow-run.json` を入力として解析する。今回は Step 12 が遅延しているため順序を入れ替えた。

### Step 15: 再デプロイ — ✅ pack / import 成功、フローはアクティブ維持

```powershell
pac solution pack → pac solution import --force-overwrite --activate-plugins --publish-changes
# Solution Imported successfully.
# The original workflow definition has been deactivated and replaced.
# → statecode = アクティブ化（import 後も稼働状態を維持）
```

**重要な発見**: `--activate-plugins` の実際の挙動は「**import 前にオンだったフローはオンに戻す。下書きだったフローは下書きのまま**」。
→ フローを一度オンにしてしまえば、**「AI修正 → pack → import → 即実行可能」の CLI 完結ループが成立する**（前回それが失敗したのは、フローが下書き状態からの import だったため + スロットリング中だったため）。

### 次のアクション

1. **（人間）Step 15 実行** — フローを手動実行し、Compose に「稼働可能」3名が出て Success になることを確認（= Step 16）。
2. **（AI）Step 12 継続** — FlowRun ポーリングを継続。今回の Failed 実行 + 修正後の Success 実行のレコードが取れたら `logs/latest-flow-run.json` へ保存。約80分待っても現れない場合は「標準クラウドフローは FlowRun 対象外（この環境では Copilot Studio エージェントフローのみ）」と結論づけ、代替経路（ブラウザ自動操作 / フローへの自己通報アクション追加 / Management API 用トークン整備）を検討する。

---

## 2026-08-27 — Step 16 完了・FlowRun 到着 — **第一段階 PoC 成功**

### Step 16: Success 確認 — ✅ 完了（人間）

修正版デプロイ後、ユーザーが手動実行し **Success** を確認。「AI編集 → CLIデプロイ → 実行 → エラー確認 → AI修正 → 再デプロイ → Success」のループが一周した。

### Step 12: FlowRun 取得 — ✅ 完了（遅延約25分で到着）

Failed 実行（starttime 07:23 UTC）のレコードが createdon 07:48 UTC に出現。**標準クラウドフローも FlowRun に記録される**ことが確定（それまで全レコードが CopilotStudioFlow だったのは、単に最近エージェントフローしか動いていなかっただけ）。取得内容は `logs/latest-flow-run.json` に保存。

```text
status: Failed / errorcode: ActionFailed / triggertype: Instant / duration: 2590ms
errormessage: { "code": "ActionFailed", "message": "An action failed. No dependent actions succeeded." }
```

**制約として判明**: FlowRun の `errormessage` はフローレベルの汎用メッセージのみで、**どのアクションがなぜ失敗したかは含まれない**。アクションレベルの詳細（Filter array の from が null 等）はフローサービス側の実行履歴にしかない。AI 修正ループでは「FlowRun で Failed を検知 → ソースと突き合わせて原因推定」となり、複雑なフローでは詳細ログの代替経路（Management API / ブラウザ / フロー内自己通報）が必要になる。

### 第一段階の成功条件（計画 §11）の判定

| # | 条件 | 判定 |
| --- | --- | --- |
| 1 | Solution を CLI で取得できる | ✅ |
| 2 | AI がフロー定義を理解できる | ✅ |
| 3 | AI がフロー定義を変更できる | ✅ |
| 4 | CLI だけで変更後 Solution を反映できる | ✅ |
| 5 | フローを実行できる | ✅（手動。CLI 起動は Phase 2） |
| 6 | FlowRun を CLI / API 経由で取得できる | ✅（pac env fetch。遅延約25分） |
| 7 | Failed の Error Message を AI へ渡せる | ✅（ただし汎用メッセージのみ） |
| 8 | AI がエラー原因を特定できる | ✅（注入既知 + ソース突き合わせ） |
| 9 | AI が Solution source を修正できる | ✅ |
| 10 | 再デプロイ後に Success になる | ✅ |

**10項目すべて成立 — 第一段階 PoC 成功。**

---

## 2026-08-27 — 機能追加検証（第三段階の先行実施）: スキル検索入力

第一段階成功を受け、「AI が既存フローを CLI 経由で**拡張**できるか」を検証。計画 §12 第三段階の例（ユーザー入力起点の人材検索）を実装した。

### 変更内容（AI がソース直接編集）

1. **トリガーにテキスト入力「スキル」を追加** — 手動トリガーの入力スキーマに Designer 互換の形式（`x-ms-dynamically-added` / `x-ms-content-hint: TEXT`）でプロパティ `text` を追加、必須入力とした。
2. **Filter array の条件を拡張** —

```text
旧: @equals(item()?['稼働状況'], '稼働可能')
新: @and(equals(item()?['稼働状況'], '稼働可能'),
        contains(toLower(coalesce(item()?['スキル'], '')),
                 toLower(coalesce(triggerBody()?['text'], ''))))
```

- `toLower` で大文字小文字を無視、`coalesce` で null 安全化（スキル列が空のセルや入力欠落でも式エラーにならない）。

### デプロイ結果

pack → import 成功。**フローはアクティブ状態を維持**（オン状態からの CLI デプロイでオンが保たれる挙動は3回目の再現）。トリガースキーマの変更もコネクタ動的検証の対象外のため、有効化に影響なし。

### 期待動作（人間の実行テスト待ち）

実行時に「スキル」の入力を求められる。データ例に対する期待結果:

| 入力 | 期待される取得者 |
| --- | --- |
| `Python` | 山田太郎 |
| `Power Platform` | 鈴木一郎・高橋美咲 |
| `azure`（小文字） | 山田太郎（大文字小文字無視の確認） |
| `Salesforce` | 0名（佐藤花子は稼働中のため除外) |

### 実行テスト結果 — ✅ 成功（2026-08-27）

ユーザーが `Python` を入力して実行し、**山田太郎のみが取得されることを確認**。トリガー入力の追加を含む機能拡張が、Designer を使わず「AI ソース編集 → CLI デプロイ」だけで実現できることを実証した。
