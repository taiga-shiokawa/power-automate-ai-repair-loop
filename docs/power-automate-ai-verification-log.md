# Power Automate × AIコーディングエージェント 自動修正ループ検証 — 実施ログ

計画: [power-automate-ai-verification-plan.md](power-automate-ai-verification-plan.md)

> **公開版についての注記**: テナント ID・環境 URL・SharePoint の各種 ID・Connection Reference 名・アカウント情報は、`YOURORG` / `YOUR-TENANT-ID` / `YOUR-FILE-ID` などのプレースホルダーに置換しています。手順・コマンド・検証結果はすべて実際に実行したものです。

計画（第二段階）: [power-automate-ai-phase2-plan.md](power-automate-ai-phase2-plan.md)

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

---

# 第二段階 — 完全自動ループ

計画: [power-automate-ai-phase2-plan.md](power-automate-ai-phase2-plan.md)

## 進捗サマリ（第二段階）

| Step | 内容 | 状態 |
| --- | --- | --- |
| P1 | 事前調査（pac トークンの適用範囲・デバイスコードフローの可否） | ✅ 完了（2026-08-27） |
| P2 | `token.ps1` 実装 → Flow API トークン取得 | ✅ 完了（2026-08-27・デバイスコード認証成功） |
| P3 | Flow API エンドポイント形状の確定 | ✅ 完了（2026-08-27） |
| P4 | 実値入り `src/` の復元（export → unpack） | ✅ 完了（2026-08-27） |
| P5 | API からのフロー起動 | 🔄 進行中（接続参照の問題は解決。トリガー種別の制約に到達） |
| P6 | 実行結果の即時取得・失敗アクション詳細 | 未着手 |
| P7 | `repair-loop.ps1` 1コマンド実行 | 未着手 |
| P8 | Draft フローの API 有効化 | 未着手 |

---

## 2026-08-27 — P1: 事前調査（AI）

### `pac auth token` の適用範囲 — ❌ 実行系には使えない

`pac auth token` は**引数を一切受け付けない**（`--help` すら unknown argument）。取得した JWT を
デコードした結果:

```text
aud : https://api.powerplatform.com
scp : All.All.ReadWrite AppManagement.* Connectivity.* CopilotStudio.* PowerApps.* PowerPages.*
```

**スコープに Power Automate（フロー実行系）が一切含まれない**。実測した到達性:

| 対象 | 結果 |
| --- | --- |
| `https://api.powerplatform.com/powerautomate/environments/{env}/flows` | **404**（そのような面は存在しない） |
| `https://api.flow.microsoft.com/providers/Microsoft.ProcessSimple/...` | **401** |
| `https://YOURORG.crm7.dynamics.com/api/data/v9.2/WhoAmI` | **401** |

また `pac env` のサブコマンドは `who / list / fetch / list-settings / update-settings / select / features`
のみで、**Dataverse レコードの作成・更新はできない**（`fetch` は読み取り専用）。

→ **結論: pac CLI 単体では第二段階の「起動」「監視」に到達できない。別トークンが必須。**

### 代替経路の選定

| 経路 | 判定 |
| --- | --- |
| Entra ID アプリ登録＋サービスプリンシパル | テナント管理者権限が必要。PoC では重い |
| az CLI の `get-access-token` | az 未インストール |
| PowerShell モジュール（Microsoft.PowerApps.* / MSAL.PS） | 未インストール。要ダウンロード |
| **デバイスコードフロー（well-known パブリッククライアント）** | **採用**。インストール不要、`Invoke-RestMethod` のみで完結 |

well-known パブリッククライアント2種でデバイスコード発行を試験し、いずれも成功:

| クライアント | Flow API | Dataverse |
| --- | --- | --- |
| Azure CLI `04b07795-8ddb-461a-bbee-02f9e1bf7b46` | ✅ 発行成功 | ✅ 発行成功 |
| Dynamics CRM `51f81489-12ee-4a9e-aaae-a2591f45987d` | ✅ 発行成功 | ✅ 発行成功 |

### `claude` CLI の非対話実行 — ✅ 可能

`claude --help` に `-p/--print` / `--permission-mode` / `--allowedTools` / `--output-format` を確認。
ループから AI 修正を呼び出す手段は確保できた。

---

## 2026-08-27 — P2: Flow API トークン取得（AI ＋ 人間の初回サインインのみ）

`scripts/token.ps1` を実装（Request / Poll / Get / Status の4モード）。

- Azure CLI クライアント ID でデバイスコードを発行 → ユーザーが `https://login.microsoft.com/device`
  でコードを入力しサインイン → **トークン取得成功**。
- 取得したトークンの実体:

```text
aud : https://service.flow.microsoft.com/
scp : user_impersonation
```

- **追加の管理者同意は不要だった**（Azure CLI クライアントは Flow サービスに対して事前同意済み）。
- リフレッシュトークンは `.secrets/token-service-flow-microsoft-com.json` に **DPAPI（ユーザー単位）で
  暗号化して保存**。2回目以降は `-Mode Get` が無人でリフレッシュする。

### 実装上の重要な知見（Windows PowerShell 5.1）

1. **BOM なし UTF-8 の `.ps1` は ANSI（CP932）として読まれ、日本語リテラルが壊れて構文エラーになる。**
   最初に日本語コメント付きで書いたスクリプトは全滅した。→ **スクリプトは ASCII のみで記述**し、
   日本語の説明は `docs/` 側に置く方針に変更。リポジトリのパス自体に日本語が含まれるため、
   スクリプト内でパスをリテラル指定するのも不可（相対パス・`$PSScriptRoot` を使う）。
2. `Invoke-RestMethod` が失敗した際、`$_.Exception.Response.GetResponseStream()` は
   既に消費済みで読めないことがある。**エラー本文は `$_.ErrorDetails.Message` から取る**のが確実。
   これを誤ると `authorization_pending`（デバイスコードのポーリング中の正常応答）を
   致命的エラーと誤認して即 throw する。

---

## 2026-08-27 — P3: Flow API エンドポイントの確定（AI）

ベース: `https://api.flow.microsoft.com/providers/Microsoft.ProcessSimple/environments/{environmentId}`

| エンドポイント | 結果 |
| --- | --- |
| `GET /flows?api-version=2016-11-01` | ✅ 200。ソリューションフローも列挙される（`state: Started`） |
| `GET /flows/{workflowId}` | ✅ 200。`properties.definition` に Logic Apps 定義がそのまま入る |
| `GET /flows/{workflowIdUnique}` | ✅ 200（**どちらの GUID でも参照できる**） |
| `GET /flows/{id}/runs` | ✅ 200。`startTime` / `endTime` / `status` を含む実行履歴 |
| `GET /flows/{id}/triggers` | ✅ 200。トリガー名 `manual` / `state: Enabled` |
| `GET /flows/{id}/triggers/manual` | ✅ 200 |

**FlowRun（Dataverse）の約25分遅延に対し、Flow API の `runs` はポータルと同じ経路のため即時性が期待できる**
（P6 で実測予定）。

---

## 2026-08-27 — P5: API からのフロー起動（AI）— 2つの壁

### 壁1: `InvokerConnectionOverrideFailed` — ✅ 解決

`POST /flows/{id}/triggers/manual/run` を叩くと 400:

```text
InvokerConnectionOverrideFailed:
Failed to parse invoker connections from trigger 'manual' outputs.
Exception: Could not find property 'headers.X-MS-APIM-Tokens' in the trigger outputs.
Workflow has connection references '["shared_excelonlinebusiness"]' with invoker runtime source.
```

原因: フロー定義の接続参照が `"runtimeSource": "invoker"` になっており、**呼び出し元（ポータル）が
`X-MS-APIM-Tokens` ヘッダーでコネクション トークンを渡す前提**になっている。API から素で叩くと
このヘッダーが無いため解決できない。

対応: `src/Workflows/*.json` の接続参照を **`"runtimeSource": "embedded"`** に変更して再デプロイ。

```diff
-        "runtimeSource": "invoker",
+        "runtimeSource": "embedded",
```

デプロイ後、API から見た接続参照は `"source": "Embedded"` に変わり、**このエラーは解消**した。
接続参照の論理名・コネクション ID は一切変更していない（AI の禁止領域は不変）。

> **PoC としての知見**: ソリューションフローを API/CLI から起動可能にするには、
> 接続参照の runtime source を invoker から embedded に切り替える必要がある。
> これは「フローの実行主体が対話ユーザーからサービス（自動化）へ変わる」ことを意味する。

### 壁2: `TriggerInputSchemaMismatch` — トリガー種別の構造的制約

`embedded` 化後、同じ POST が別のエラーになった:

```text
TriggerInputSchemaMismatch:
The input body for trigger 'manual' of type 'Request' did not match its schema definition.
The input body is missing required schema properties.
```

トリガーは第一段階の機能追加でテキスト入力 `text`（必須）を持つ。そこでボディの形を6通り試験:

| ボディ | 結果 |
| --- | --- |
| （ボディ無し） | 400 TriggerInputSchemaMismatch |
| `{}` | 400 同上 |
| `{"text":"Python"}` | 400 同上 |
| `{"text":"Python"}` ＋ `charset=utf-8` | 400 同上 |
| `{"inputs":{"text":"Python"}}` | 400 同上 |
| `{"triggerBody":{"text":"Python"}}` | 400 同上 |
| `{"headers":{...},"body":{"text":"Python"}}` | 400 同上 |

**ボディ無しと `{"text":"Python"}` が完全に同じエラー** → この `run` エンドポイントは
**リクエストボディをトリガーへ転送していない**。つまり Button トリガーには API から入力を渡せない。

Request 型トリガー本来の入口である callback URL も試したが:

```text
POST /flows/{id}/triggers/manual/listCallbackUrl
→ 400 ListCallbackUrlOperationBlocked:
  "The list callback url operation is blocked for triggers of type 'Request'."
```

**Button トリガー（`type: Request` / `kind: Button`）は callback URL の発行が禁止されている。**

### 現時点の整理

| 選択肢 | 起動 | 入力の受け渡し | 前提 |
| --- | --- | --- | --- |
| Button トリガー（現状）＋ `triggers/manual/run` | ⭕（ただし必須入力があると 400） | ❌ 不可 | 必須入力を外す必要あり |
| `kind: Http`（HTTP 要求の受信時）へ変更 | ⭕ | ⭕ callback URL に POST | **プレミアム扱い。可否は未検証** |

→ 次アクション: `kind: Button` → `kind: Http` に変更して import し、
（a）ライセンス的に通るか（b）`listCallbackUrl` が解禁されるか を確認する。
通らなければ Button トリガーの必須入力を外し、「入力なしで起動」に割り切ってループを完成させる。

### 壁2の判定: `kind: Http` はライセンスで不可 — ❌ 案B 却下

`src/Workflows/*.json` の `"kind": "Button"` → `"kind": "Http"` に変更して import。

- **import 自体は成功**（`Solution Imported successfully.` / `Published All Customizations.`）。
- しかし**フローは `state: Stopped`（下書き）に落ち、トリガーは `Disabled`** になった。
- `listCallbackUrl` は依然 `ListCallbackUrlOperationBlocked`（この API 経路では Request 型トリガーの
  URL 発行は種別に関係なく禁止されている）。
- 有効化を試みると決定的なエラー:

```text
POST /flows/{id}/start
→ 403 MissingAdequateQuotaPolicy:
  "Flow could not be activated because you need a Power Automate Premium license
   or other license that includes premium connectors to save this flow with connection: 'Http'"
```

**HTTP 要求トリガーは Power Automate Premium ライセンスが必要で、本アカウントでは利用不可**と確定。
→ 案B は却下。Button トリガー＋`triggers/manual/run`（入力なし起動）で進める。

なお、`kind` を `Button` に戻して再 import すると、フローのプロパティに
**`flowTriggerUri`**（`https://japan-001.azure-apim.net/apim/logicflows/{internalWorkflowId}/triggers/manual/run`）
が現れる。Button トリガーには APIM 経由の実行 URI が存在するが、`listCallbackUrl` 経由では取得できない。

---

## 2026-08-27 — P8: Draft フローの有効化 — ✅ 解決（第一段階の課題②）

`kind` を `Button` に戻し、トリガーの必須指定（`required: ["text"]`）を外して再デプロイした直後は、
まだ `MissingAdequateQuotaPolicy`（'Http' コネクション）が返った。**数十秒待って再試行すると成功**:

```text
POST /providers/Microsoft.ProcessSimple/environments/{env}/flows/{flowId}/start?api-version=2016-11-01
→ 200
state after start : Started
trigger manual state=Enabled
```

**第一段階で「pac 2.11.2 には手段が見当たらない」としていたモダンフローの有効化が、Flow API の
`POST /start` で可能**と判明。`--activate-plugins` に依存せず、Draft に落ちたフローも復帰できる。

### 実装上の注意

- **import 直後のライセンス評価にはラグがある**。直前の定義（プレミアム要素あり）で判定され
  403 になることがあるため、`/start` は**リトライ前提**で実装する
  （`repair-loop.ps1` の `Ensure-FlowStarted` は最大5回・10秒間隔でリトライ）。
- 403 は「エンドポイントが無い」ではなく「ライセンス判定」。404 と区別して扱う。

---

## 2026-08-27 — P5: API からのフロー起動 — ✅ 成功

必須入力を外した Button トリガーに対して:

```text
POST /flows/{flowId}/triggers/manual/run?api-version=2016-11-01
→ HTTP 200
```

**CLI/API からのフロー起動が成立**（第一段階の成功条件5「フローを実行できる」を人手なしで達成）。

### 制約: 入力は渡せない

- `run` エンドポイントはリクエストボディをトリガーへ転送しない（ボディ7通りで検証済み）。
- 応答に Logic Apps の run 名は含まれない（返るのは `japaneast:<guid>` 形式のリクエスト ID）。
  → **run の特定は「起動時刻以降に開始された最新 run」を実行履歴から突き合わせる**方式にした。
- したがって第一段階で追加した「スキル検索入力」は、**ポータルからの手動実行では使えるが、
  API 起動では空扱い**になる（`coalesce` で null 安全化してあるため実行は成功し、
  稼働可能な全員が返る）。入力を渡した自動実行が必要なら Premium（HTTP トリガー）が前提。

---

## 2026-08-27 — P6: 実行結果の即時取得とアクション詳細 — ✅ 成功

### 即時性 — 25分遅延の解消

| 経路 | 反映までの時間 |
| --- | --- |
| Dataverse `flowrun` テーブル（第一段階） | **約25分**（実測10〜79分） |
| Flow API `GET /flows/{id}/runs`（第二段階） | **数秒** |

実測: 09:18:27 起動 → 09:18:29 完了 → 09:19:02 時点で `status: Succeeded` を取得済み。
**秒オーダーでの監視が可能**（成功条件4を満たす）。

### アクションレベルの詳細 — 第一段階の制約の解消

```text
GET /flows/{flowId}/runs/{runId}/actions?api-version=2016-11-01
→ 200
    Compose                      status=Succeeded  code=OK
    Filter_array                 status=Succeeded  code=NotSpecified
    List_rows_present_in_a_table  status=Succeeded  code=OK
```

第一段階では FlowRun の `errormessage` が `{"code":"ActionFailed","message":"An action failed.
No dependent actions succeeded."}` という汎用文だけで、**どのアクションが失敗したか分からなかった**。
Flow API の `/actions` は**アクション単位の status / code / error** を返すため、この制約が解消される。

- `/operations` は 404（存在しない）。正しいパスは `/actions`。
- 失敗アクションの入出力は `inputsLink` / `outputsLink`（署名付き URL）で参照できるため、
  `fetch-flow-runs.ps1` はこれを追跡して本文を `logs/latest-flow-run.json` に格納する。
- run 詳細（`/runs/{id}`）の properties は `startTime, endTime, status, correlation, trigger, isAborted`。

---

## 2026-08-27 — P7: 1コマンド完全自動ループ — ✅ **第二段階 PoC 成功**

### 実行内容

エラー注入（第一段階と同じ Filter array の式破壊: `body/value` → `body/values`）を行い、
**1コマンドだけ**実行した。

```powershell
.\scripts\repair-loop.ps1 -MaxIterations 2
```

### 実行結果（人間の介入ゼロ）

```text
==== preflight ====
[loop] Flow API token: OK
[loop] pac Dataverse connection: OK

==== iteration 1 / 2 ====
[deploy] pack -> import: Solution Imported successfully. / Published All Customizations.
[loop] flow state: Started
[trigger] POST triggers/manual/run -> HTTP 200
[fetch] run 08584...CU61 detected (status=Running)
[fetch] run 08584...CU61 status=Failed
[fetch] FAILED action: Filter_array  code=BadRequest
[loop] trigger -> verdict in 7s (exit 2)

==== AI repair (iteration 1) ====   ← claude -p による非対話修正
（AI の出力）
 1. 特定した失敗アクション名: Filter_array（BadRequest — 'from' が Null 型、配列である必要がある）
 2. 根本原因: from が body/values という存在しないキーを参照しており、Excel GetItems の
    実際の出力キー body/value と不一致で Null に解決されていた
 3. 変更: Filter_array の from を ?['body/values'] -> ?['body/value'] に修正（1箇所のみ）。
    接続参照・認証・table GUID・トリガーには一切触れていない

==== iteration 2 / 2 ====
[deploy] pack -> import: Solution Imported successfully.
[loop] flow state: Started
[trigger] POST triggers/manual/run -> HTTP 200
[fetch] run 08584...CU39 status=Succeeded
[loop] trigger -> verdict in 7s (exit 0)

==== summary ====
RESULT: Succeeded   (exit 0)
```

### AI に渡された入力（`logs/latest-flow-run.json`）

第二段階の監視スクリプトが生成した JSON。**第一段階との差はここが決定的**。

```json
{
  "flowName": "GetAvailableHumanResources",
  "runId": "08584...CU61",
  "status": "Failed",
  "durationMs": 477,
  "error": { "code": "ActionFailed", "message": "An action failed. No dependent actions succeeded." },
  "actions": [
    { "name": "Compose", "status": "Skipped", "code": "ActionSkipped" },
    { "name": "Filter_array", "status": "Failed", "code": "BadRequest" },
    { "name": "List_rows_present_in_a_table", "status": "Succeeded", "code": "OK" }
  ],
  "failedActions": [
    {
      "name": "Filter_array",
      "status": "Failed",
      "code": "BadRequest",
      "error": {
        "code": "BadRequest",
        "message": "The 'from' property value in the 'query' action inputs is of type 'Null'. The value must be an array."
      }
    }
  ],
  "source": "PowerAutomateManagementApi"
}
```

- `error`（フローレベル）は第一段階と同じ汎用文だが、**`failedActions[].error.message` に
  原因そのものが入る**。AI はこれだけで正しく原因特定できた。
- 失敗アクションの `inputsLink` / `outputsLink` は今回のケースでは提供されず `null` だったが、
  `error.message` で十分だった（リンクがある場合はスクリプトが本文を追跡する実装済み）。

### 検証: AI が禁止領域を触っていないこと

ループ完了後の `git status` で **`src/` に差分なし**。
つまり AI の修正後のソースは、エラー注入前のベースラインコミットと**バイト単位で一致**した。
接続参照・テナント ID・SharePoint ID・table GUID・トリガー定義はいずれも無変更。

### 所要時間

| 区間 | 実測 |
| --- | --- |
| pack → import → publish | 約60〜90秒 |
| 起動 → 実行結果の判定 | **7秒** |
| AI 修正（`claude -p`） | 約60〜90秒 |
| 1周（デプロイ〜判定） | 約2分 |

---

## 第二段階の成功条件（計画 §7）の判定

| # | 条件 | 判定 | 備考 |
| --- | --- | --- | --- |
| 1 | アプリ登録なしで Flow API トークンを取得できる | ✅ | Azure CLI パブリッククライアント＋デバイスコード。管理者同意も不要 |
| 2 | 2回目以降はリフレッシュトークンで無人実行できる | ✅ | DPAPI 暗号化して `.secrets/` に保存。ループ実行時は無人 |
| 3 | CLI からフローを起動できる | ✅ | `POST /triggers/manual/run` → 200 |
| 4 | 実行結果を秒オーダーで取得できる | ✅ | **7秒**（第一段階は約25分） |
| 5 | 失敗したアクション名とエラー内容を取得できる | ✅ | `/runs/{id}/actions` でアクション単位に取得 |
| 6 | `claude -p` による非対話 AI 修正が成立する | ✅ | `--permission-mode acceptEdits --allowedTools Read Edit Write Grep Glob` |
| 7 | 1コマンドで全周が回る | ✅ | `.\scripts\repair-loop.ps1` |
| 8 | 反復上限・タイムアウトで無限ループしない | ✅ | `-MaxIterations` / `-RunTimeoutSec` / `/start` リトライ上限 |
| 9 | AI が禁止領域を触らない | ✅ | `git status` で src 差分ゼロを確認 |
| 10 | Draft に落ちたフローを CLI/API で有効化できる | ✅ | `POST /start` → 200（第一段階の課題②を解決） |

**10項目すべて成立 — 第二段階 PoC 成功。**

---

## 第二段階で判明した制約（実案件適用時の判断材料）

| # | 制約 | 影響 | 回避策 |
| --- | --- | --- | --- |
| 1 | **pac CLI だけでは実行系に到達できない** | `pac auth token` の audience が固定。Flow API / Dataverse とも 401 | 別トークン（デバイスコード or サービスプリンシパル）が必須 |
| 2 | **API 起動では入力を渡せない** | Button トリガーの `run` はボディを転送しない。`listCallbackUrl` はブロック | 入力が必要なら Premium（HTTP 要求トリガー）が前提。または入力を Excel/Dataverse 側の値で持つ設計にする |
| 3 | **HTTP 要求トリガーは Premium 必須** | `MissingAdequateQuotaPolicy`（本アカウントでは不可） | ライセンス調達、または制約2の設計変更 |
| 4 | **接続参照を `embedded` にする必要がある** | 実行主体が対話ユーザーからサービスへ変わる。既存フローに手を入れることになる | フロー設計時点で自動化前提にしておく |
| 5 | **非公式 API 依存** | `api.flow.microsoft.com` の ProcessSimple プロバイダは未ドキュメント。仕様変更で壊れ得る | 実案件では Power Automate Management コネクタ等への置き換えを検討 |
| 6 | **リフレッシュトークンが非アクティブ12時間で失効**（テナントポリシー） | 完全無人の常時運用には日次サインインが必要 | Entra ID アプリ登録＋サービスプリンシパル（要管理者権限） |
| 7 | **import 直後はライセンス評価にラグ** | `/start` が一時的に 403 を返す | リトライ実装（本ループは最大5回・10秒間隔） |
| 8 | **Windows PowerShell 5.1 は BOM なし UTF-8 の .ps1 を ANSI 解釈** | 日本語リテラルが壊れて構文エラー | スクリプトは ASCII のみ。パスもリテラル指定せず相対パス／`$PSScriptRoot` を使う |

## 第三段階への申し送り

- 制約2（入力を渡せない）は、フローを複雑化するうえで最も効く。
  ユーザー入力起点の検証を続けるなら **Premium ライセンスの有無を先に確定**させるべき。
- 複数コネクタ（SharePoint / Dataverse / Teams / Planner）への拡張時は、
  制約4（`embedded` 化）を全接続参照に適用する必要がある。
- 失敗アクションの `inputsLink` / `outputsLink` を実際に使うケース（大きな入出力を伴う失敗）は
  未検証。実装は済んでいるので、複雑なフローで確認するとよい。

