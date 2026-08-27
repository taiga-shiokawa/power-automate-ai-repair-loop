# 第二段階 — フロー起動まで含めた完全自動ループ 検証計画

作成日: 2026-08-27
ステータス: **検証完了・成功条件10項目すべて成立（2026-08-27）**
親計画: [power-automate-ai-verification-plan.md](power-automate-ai-verification-plan.md) §12
進捗・実測値: [power-automate-ai-verification-log.md](power-automate-ai-verification-log.md)

> **公開版についての注記**: テナント ID・環境 ID・組織 URL・各種 GUID は `YOUR-*` 形式の
> プレースホルダーに置換しています。実値はリポジトリ管理外の `local.config.json`
> （`.gitignore` 済み）に置く設計です。

---

## 1. 目的

第一段階で成立した「AI編集 → pac CLI デプロイ → 実行 → FlowRun 取得 → AI修正」のうち、
**実行（起動）と監視が人間の手作業**として残った。第二段階では次の1コマンドで全周を回す。

```powershell
.\scripts\repair-loop.ps1
# pack → import → 起動 → 実行完了待ち → Failed なら AI 修正 → 再デプロイ → …（最大 N 周）
```

## 2. 第一段階から持ち越した課題

| # | 課題 | 第一段階での状態 |
| --- | --- | --- |
| ① | デプロイ | ✅ CLI 完結（`pac solution pack` → `import --force-overwrite --activate-plugins --publish-changes`） |
| ② | import 後の有効化 | ⚠️ ON からの import は ON 維持。**Draft からの復帰手段が無い**（`--activate-plugins` では戻らない・2回確認） |
| ③ | **フロー起動** | ❌ ポータルから手動実行のみ |
| ④ | **実行結果の取得** | ⚠️ FlowRun は**遅延約25分**、かつ `errormessage` はフローレベルの汎用文（`ActionFailed`）のみでアクション詳細が無い |
| ⑤ | AI 修正の非対話呼び出し | 未検証（対話セッションで人間が指示していた） |
| ⑥ | ループ制御 | 未実装 |

③④が第二段階の本質。①は流用、②⑤⑥は実装で解く。

## 3. 事前調査で確定した制約（2026-08-27 実測）

| 調査 | 結果 |
| --- | --- |
| `pac auth token` の適用範囲 | audience は `api.powerplatform.com` **固定**（`pac auth token` は引数を一切受け付けない）。スコープに Power Automate 系が無い |
| 同トークンで Flow API | `https://api.flow.microsoft.com/...` → **401** |
| 同トークンで Dataverse Web API | `https://YOURORG.crm7.dynamics.com/api/data/v9.2/WhoAmI` → **401** |
| `api.powerplatform.com` に Power Automate 面はあるか | `/powerautomate/environments/{env}/flows` → **404**（存在しない） |
| `pac env` の書き込み | サブコマンドは `who / list / fetch / list-settings / update-settings / select / features`。**Dataverse レコードの作成・更新は不可**（`fetch` は読み取り専用） |
| デバイスコードフロー | well-known パブリッククライアント（Azure CLI `04b07795-…` / Dynamics CRM `51f81489-…`）で `service.flow.microsoft.com` と Dataverse 両方のデバイスコード発行に成功 → **アプリ登録なしでトークン取得の見込み** |
| `claude` CLI の非対話実行 | `-p/--print` / `--permission-mode` / `--allowedTools` / `--output-format` を確認 → ⑤は実装可能 |

**結論**: pac CLI だけでは③④に到達できない。**pac CLI（ALM）＋ 別トークンで叩く Flow API（実行系）** の二本立てが必須。

## 4. 起動・監視の実装方式の比較

| 案 | 方式 | ③起動 | ④監視 | ②有効化 | 前提・リスク |
| --- | --- | --- | --- | --- | --- |
| **A（採用）** | Flow Management API（`api.flow.microsoft.com`）＋デバイスコード認証 | `POST .../flows/{id}/triggers/manual/run` | `GET .../runs`（ポータルと同じ経路のため即時性が期待できる） | `POST .../flows/{id}/start` | フロー無改変で済む。初回のみ対話サインイン。**非公式 API** |
| B | トリガーを「HTTP 要求の受信時」に変更＋Response で同期返却 | SAS URL に POST（トークン不要） | 同期レスポンスでアクションレベルの詳細まで取得可 | 同上の課題 | **プレミアム扱いのトリガー**。トリガー種別変更が import で通るか未検証 |
| C | フロー内に失敗時分岐（`Configure run after` ＋ `result()`）を追加して自己通報 | 解決しない | アクション詳細を確実に取得可 | — | 起動は別途必要。フロー本体を汚す |

**採用: 案A**。フローを一切変更せずに③④②すべてに手が届く点を優先する。
案Aで④のアクションレベル詳細が取れない場合に限り、案C（自己通報）で補強する。

## 5. アーキテクチャ

```text
repair-loop.ps1（オーケストレータ）
  ├─ token.ps1        … デバイスコード認証／リフレッシュ（.secrets/ に DPAPI 暗号化保存）
  ├─ deploy.ps1       … pac solution pack → import（第一段階で確立済み）
  ├─ trigger-flow.ps1 … Flow API で manual トリガーを起動 → runId 取得
  ├─ fetch-flow-runs.ps1 … Flow API で run の完了待ち＋失敗アクション詳細を取得
  │                        → logs/latest-flow-run.json
  └─ claude -p        … prompts/repair-flow.md に従い src/ を修正（非対話）
```

### 環境固有値の扱い

実値は **`local.config.json`（gitignore 済み）** に集約し、スクリプトとドキュメントには
一切埋め込まない。第一段階では `src/` とログに実値が入り公開時に一括サニタイズが必要だったが、
第二段階はこの分離により公開ブランチへの混入リスクを構造的に減らす。

```json
{
  "tenantId": "YOUR-TENANT-ID",
  "environmentId": "Default-YOUR-TENANT-ID",
  "orgUrl": "https://YOURORG.crm7.dynamics.com/",
  "solutionName": "AIFlowDevelopment",
  "flowName": "GetAvailableHumanResources",
  "workflowId": "YOUR-WORKFLOW-ID",
  "workflowIdUnique": "YOUR-WORKFLOW-UNIQUE-ID",
  "publicClientId": "04b07795-8ddb-461a-bbee-02f9e1bf7b46",
  "flowApiResource": "https://service.flow.microsoft.com/",
  "flowApiBase": "https://api.flow.microsoft.com"
}
```

### ブランチ運用

実値を含む `src/` を扱うため、第二段階の作業は**ローカル専用ブランチ `phase2-work`** で行う。
公開ブランチ `main` にはサニタイズ済みの docs / scripts のみを載せる（scripts は実値を
持たない設計なのでそのまま公開可能）。

## 6. 検証ステップ

| Step | 内容 | 実施者 | 結果 |
| --- | --- | --- | --- |
| P1 | 事前調査（pac トークンの適用範囲・デバイスコードフローの可否） | AI | ✅ pac 単体では不可と確定。デバイスコード経路を選定 |
| P2 | `token.ps1` 実装 → デバイスコードでサインインし Flow API トークン取得 | AI ＋ 人間（初回サインインのみ） | ✅ 取得成功。追加の管理者同意は不要 |
| P3 | Flow API のエンドポイント形状を確定 | AI | ✅ `flows` / `runs` / `triggers` / `actions` / `start` を確定 |
| P4 | `pac solution export` → `unpack` で実値入り `src/` を復元 | AI | ✅ 完了 |
| P5 | `trigger-flow.ps1` — API 起動で実行が始まることを確認 | AI | ✅ 200 で起動成功（ただし**入力は渡せない**） |
| P6 | `fetch-flow-runs.ps1` — 所要時間の実測＋失敗アクション詳細 | AI | ✅ **秒オーダー**で取得。`/actions` でアクション単位の詳細も取得可 |
| P7 | エラー注入 → `repair-loop.ps1` 1コマンドで Success へ収束するか | AI | ✅ **成功**（iteration 1 Failed → AI 修正 → iteration 2 Succeeded） |
| P8 | ②の検証: Draft 状態のフローを `POST .../start` で有効化できるか | AI | ✅ 200 で有効化成功（**課題②解決**） |
| P9 | 案B（HTTP 要求トリガー）の可否 | AI | ❌ `MissingAdequateQuotaPolicy` — Premium ライセンス必須で不可 |

## 7. 第二段階の成功条件

1. アプリ登録なしで Flow API トークンを取得できる（初回サインインのみ）
2. 2回目以降はリフレッシュトークンで無人実行できる
3. CLI からフローを起動できる
4. 実行結果を**分オーダーではなく秒オーダー**で取得できる
5. 失敗したアクション名とエラー内容を取得できる（第一段階の④の制約を解消）
6. `claude -p` による非対話 AI 修正が成立する
7. 1コマンドで「デプロイ → 実行 → 監視 → AI修正 → 再デプロイ」が回る
8. 反復上限・タイムアウトで無限ループしない
9. AI が禁止領域（接続参照・環境固有 ID）を触らない
10. Draft に落ちたフローを CLI/API で有効化できる（②の解消）

1〜8が成立すれば第二段階は成功、9〜10は運用上の必須要件として別評価とする。

## 8. 既知のリスク

- **非公式 API 依存**: `api.flow.microsoft.com` の ProcessSimple プロバイダはドキュメント化されていない。
  Microsoft 側の変更で壊れる可能性がある（実案件適用時は Power Automate Management コネクタや
  公式 API への置き換えを検討）。
- **トークン寿命**: 本テナントはリフレッシュトークンが非アクティブ12時間で失効する
  （第一段階で pac 側で観測）。完全無人運用には日次の再サインイン、または
  サービスプリンシパル（要 Entra ID アプリ登録＋Dataverse アプリケーションユーザー）が必要。
- **動的検証パラメータの破壊**: AI がコネクタの動的検証対象（Excel の `table` など）を壊すと、
  デプロイは通っても有効化で 429 スロットリングに陥りフローが有効化不能になる（第一段階で実発生）。
  `prompts/repair-flow.md` で明示的に禁止する。
- **Windows PowerShell 5.1 の文字コード**: BOM なし UTF-8 の `.ps1` は ANSI として読まれ
  日本語リテラルが壊れる。**スクリプトは ASCII のみで書く**（日本語はこの docs 側に置く）。
