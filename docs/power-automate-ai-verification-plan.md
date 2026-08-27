# Power Automate × AIコーディングエージェント 自動修正ループ検証 — 検証計画

作成日: 2026-08-27
ステータス: 検証中（進捗は [power-automate-ai-verification-log.md](power-automate-ai-verification-log.md) を参照）

---

## 1. 検証の目的

Power Automate のクラウドフローについて、Claude Code / Codex などの AI コーディングエージェントを利用し、以下の開発ループをどこまで自動化できるかを検証する。

```text
フローを作る
    ↓
Power Platform環境へデプロイ
    ↓
フローを実行
    ↓
実行結果・エラーログ取得
    ↓
AIがエラー内容を解析
    ↓
フロー定義を修正
    ↓
再デプロイ
    ↓
再実行
```

人間が Power Automate Designer 上で「実行 → エラー確認 → 修正 → 再実行」を繰り返す作業を、可能な範囲で AI エージェントへ移すことがゴール。

## 2. 役割分担（本検証の本質）

「pac CLI だけで Power Automate を自由にプログラミングできる」わけではない。以下の役割分担で成立させる。

| 構成要素 | 役割 |
| --- | --- |
| pac CLI | Solution の ALM（export / unpack / pack / import）・デプロイ |
| Claude Code / Codex | export した Solution ソースの解析・変更 |
| Dataverse Web API | 実行結果・エラーログ（FlowRun）の取得 |
| Power Automate | フロー実行基盤 |

本質は「Solution を **AI が操作可能なコード資産** として扱い、ALM と実行ログを組み合わせて AI エージェントによる開発ループを成立させられるか」の検証である。

## 3. 検証用フロー

### 3.1 テーマ

**Excel から人材情報を取得するクラウドフロー**。業務ロジックではなく「AI編集 → CLIデプロイ → 実行 → ログ取得 → AI修正」の検証に集中するため、できる限り小さく作る。

### 3.2 Excel ファイル

OneDrive for Business または SharePoint に配置する。

- ファイル名: `HumanResources.xlsx`
- シート名: `人材一覧`
- **Excelテーブル名: `HumanResources`**（セル範囲ではなく必ず「テーブル」として設定すること）

データ例:

| ID | 氏名 | 職種 | スキル | 稼働状況 |
| --- | --- | --- | --- | --- |
| 001 | 山田太郎 | エンジニア | Python, Azure | 稼働可能 |
| 002 | 佐藤花子 | PM | Salesforce, PM | 稼働中 |
| 003 | 鈴木一郎 | エンジニア | C#, Power Platform | 稼働可能 |
| 004 | 高橋美咲 | コンサルタント | AI, Power Platform | 稼働可能 |

### 3.3 フロー構成（正常系）

フロー名: `GetAvailableHumanResources`

```text
Trigger（手動）
    ↓
Excel Online (Business) — List rows present in a table
    （File = HumanResources.xlsx, Table = HumanResources）
    ↓
Filter array — 稼働状況 = "稼働可能"
    ↓
Compose — 取得結果をまとめる
```

- Teams 通知 / Planner 登録 / SharePoint 登録は行わない。Excel から正常取得できれば成功。
- Excel コネクタの既定取得行数制限（Pagination）は数行のみの PoC のため考慮不要。

## 4. Solution を利用する理由

フローは必ず Solution（`AIFlowDevelopment`）内に作成する。

1. **CLI で扱いやすい** — pac は Solution に対して export / import / unpack / pack / sync / clone を提供しており、「export → ローカル → AI編集 → pack → import」のループが作れる。
2. **FlowRun が利用できる** — Dataverse への実行履歴保存（FlowRun テーブル）は **Solution cloud flow が対象**。「実行 → エラー取得 → AI解析」と相性が良い。

## 5. Seed フローは Designer で作る

pac には `pac flow create` のような、クラウドフローをゼロから作る専用コマンドはない。そのため **最初の1本だけ Power Automate Designer で作成**し、以後は「Solution export → AI + CLI で編集」とする。最初から内部 XML / JSON を完全生成するより検証が安定する。

## 6. FlowRun（実行ログ）

Solution cloud flow の各実行は Dataverse の `FlowRun` テーブルにレコードとして保存される。主な項目:

| 項目 | 内容 |
| --- | --- |
| Name | Flow Run ID |
| Start time / End time / Run duration | 実行日時・時間 |
| Status | Success / Failed / Cancelled |
| Trigger type | トリガー種類 |
| Error code / Error message | エラー情報 |
| Workflow name / Workflow Id | フロー特定用 |
| Parent Run Id | 親 FlowRun |

取得は Dataverse Web API 経由:

```http
GET https://<environment>.crm7.dynamics.com/api/data/v9.2/<FlowRun entity set>
```

**注意**: FlowRun の Entity Set Name・Status / Error Code / Error Message / Workflow Id の各フィールド名は、実装時に必ず Dataverse メタデータから確認する。固定値を推測して実装しないこと。

## 7. 意図的なエラーの発生方法

正常動作だけでは修正ループを検証できないため、Excel テーブル名を存在しない名前に変更してフローを壊す。

- 正常: `HumanResources`
- エラー用: `HumanResources_ERROR`

## 8. ディレクトリ構成（最終目標）

```text
（プロジェクトルート）
├─ docs/                      ← 本検証の計画・ログ
├─ src/                       ← unpack した Power Platform Solution
├─ dist/
│   └─ AIFlowDevelopment.zip  ← pack した Solution
├─ scripts/
│   ├─ auth.ps1
│   ├─ export.ps1
│   ├─ pack.ps1
│   ├─ deploy.ps1
│   ├─ trigger-flow.ps1
│   ├─ fetch-flow-runs.ps1
│   └─ repair-loop.ps1
├─ logs/
│   ├─ latest-flow-run.json
│   └─ history/
├─ prompts/
│   └─ repair-flow.md
├─ README.md
└─ .gitignore
```

`fetch-flow-runs.ps1` の役割: Dataverse 認証 → FlowRun 取得 → 対象 Workflow に絞る → 最新 Run 取得 → `logs/latest-flow-run.json` へ保存。

```json
{
  "flowName": "GetAvailableHumanResources",
  "status": "Failed",
  "errorCode": "...",
  "errorMessage": "...",
  "startTime": "...",
  "endTime": "..."
}
```

## 9. 主要 CLI コマンド

```powershell
# 認証
pac auth create --environment https://<environment>.crm7.dynamics.com
pac auth list
pac auth select --index 1

# Solution 取得
pac solution export --name AIFlowDevelopment --path .\AIFlowDevelopment.zip --managed false
pac solution unpack --zipfile .\AIFlowDevelopment.zip --folder .\src

# デプロイ
pac solution pack --zipfile .\dist\AIFlowDevelopment.zip --folder .\src
pac solution import --path .\dist\AIFlowDevelopment.zip --force-overwrite
pac solution publish
```

※ 引数はインストール済み pac バージョンの `--help` で必ず確認すること。

## 10. 検証ステップ

| Step | 内容 | 実施者 |
| --- | --- | --- |
| 1 | 環境確認（`pac` / `pac auth list` / `pac solution list`） | AI |
| 2 | `HumanResources.xlsx` を OneDrive / SharePoint に配置、テーブル `HumanResources` 作成 | 人間 |
| 3 | Solution `AIFlowDevelopment` を Maker Portal で作成 | 人間 |
| 4 | Seed フロー `GetAvailableHumanResources` を Designer で作成 | 人間 |
| 5 | Power Automate 上で実行し「稼働可能」人材（山田太郎・鈴木一郎・高橋美咲）が取得できることを確認 | 人間 |
| 6 | `pac solution export` | AI |
| 7 | `pac solution unpack` | AI |
| 8 | AI が Solution 内部構造を解析（フロー定義・Excelアクション・Connection Reference・Trigger・Filter array の特定） | AI |
| 9 | AI が意図的にテーブル名を `HumanResources_ERROR` へ変更 | AI |
| 10 | `pac solution pack` → `pac solution import` | AI |
| 11 | フロー実行 → エラーになることを確認 | 人間（Phase 1） |
| 12 | Dataverse API から FlowRun（Failed / Error code / Error message）を取得し JSON 保存 | AI |
| 13 | `latest-flow-run.json` + Solution source を AI へ入力 | AI |
| 14 | AI がエラーを解析し `HumanResources` へ修正 | AI |
| 15 | 再 pack → import → 実行 | AI + 人間 |
| 16 | FlowRun が `Success` になれば PoC 成功 | — |

### フロー実行の2段階方針

- **Phase 1**: Power Automate 画面から手動実行（Test → Manually）。「AI編集 → CLIデプロイ → 正常動作」の確認を優先。
- **Phase 2**: HTTP Trigger や Dataverse トリガー等を利用し、CLI / API からのフロー起動（`trigger-flow.ps1`）まで自動化。

## 11. 第一段階の成功条件（10項目）

1. Solution を CLI で取得できる
2. AI がフロー定義を理解できる
3. AI がフロー定義を変更できる
4. CLI だけで変更後 Solution を Power Platform へ反映できる
5. フローを実行できる
6. FlowRun を CLI / API 経由で取得できる
7. Failed の Error Message を AI へ渡せる
8. AI がエラー原因を特定できる
9. AI が Solution source を修正できる
10. 再デプロイ後に Success になる

この10項目が成立すれば、「実行 → エラー確認 → 修正」の開発ループのかなりの部分を AI エージェントへ移せることが実証できる。

## 12. 第二段階・第三段階（発展）

- **第二段階**: フロー起動まで含めた完全自動ループ。`.\scripts\repair-loop.ps1` の1コマンドで「pack → import → publish → 実行 → FlowRun 監視 → Failed なら AI 修正 → 再デプロイ」を回す。
- **第三段階**: フロー自体の複雑化。「Power Platform ができる稼働可能な人を探して」のようなユーザー入力起点の人材検索や、SharePoint / Dataverse / Teams / Planner など複数コネクタへの拡張により、実案件適用可能性を検証する。

### 自動修正ループの完成イメージ

```text
                ┌──────────────┐
                │ Claude Code  │
                │   / Codex    │
                └──────┬───────┘
                       │
                       ▼
                 Solution src
                       │
                       ▼
              pac solution pack
                       │
                       ▼
             pac solution import
                       │
                       ▼
                Power Automate
                       │
                       ▼
                    実行
                       │
              ┌────────┴────────┐
              │                 │
           Success            Failed
              │                 │
              ▼                 ▼
             終了           FlowRun
                                │
                                ▼
                       errorMessage取得
                                │
                                ▼
                         Claude / Codex
                                │
                                └────→ 修正
```

## 13. AI への依頼プロンプト（テンプレート）

### 13.1 初回解析（変更禁止）

```text
src以下にPower Platform Solutionを展開しています。

このSolutionには
「GetAvailableHumanResources」
というPower Automateクラウドフローがあります。

まずファイル構造を調査し、

1. フロー定義がどのファイルに存在するか
2. Excel Online (Business)アクションの定義
3. Connection Reference
4. Trigger定義
5. Filter array定義

を特定してください。

まだファイルを変更しないでください。
```

### 13.2 エラー修正

```text
Power Automateクラウドフローの実行に失敗しました。

./logs/latest-flow-run.json に最新の実行結果があります。
./src にはPower Platform Solutionをunpackしたソースがあります。

次を実施してください。

1. エラー原因を特定
2. 該当するフロー定義を特定
3. 最小限の修正を実施
4. 変更理由を説明
5. git diffを確認
6. 不要なファイルは変更しない

認証情報、Connection Reference、Environment固有IDを勝手に変更しないでください。
```

## 14. 技術的な注意点

- 認証情報・Connection Reference・Environment 固有 ID を AI が勝手に変更しないこと（修正プロンプトに明記）。
- Solution ファイルを推測で書き換えず、実際のファイル構造と pac CLI の `--help` を確認してから実装すること。
- FlowRun のエンティティ名・フィールド名は Dataverse メタデータから確認すること。
- AI の変更内容を追跡できなくなるのを防ぐため、Git 管理は必須に近い。
