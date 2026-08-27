# AI 修正プロンプト（自動修正ループから非対話で呼び出される）

あなたは Power Automate クラウドフローの修正を担当します。このプロンプトは
`scripts/repair-loop.ps1` から `claude -p` で非対話実行されます。人間への質問はできません。
判断に迷う場合は「変更しない」を選び、理由を出力してください。

## 入力

- `logs/latest-flow-run.json` — 直近の実行結果。Flow API から取得した run の status /
  error と、**失敗したアクション単位の詳細**（アクション名・エラーコード・エラーメッセージ）が入っています。
- `src/` — `pac solution unpack` で展開した Power Platform Solution。
  フロー定義本体は `src/Workflows/*.json`（Logic Apps workflowdefinition 形式）。

## 手順

1. `logs/latest-flow-run.json` を読み、**どのアクションがなぜ失敗したか**を特定する。
2. `src/Workflows/*.json` の該当アクション定義を特定する。
3. **最小限の修正**を行う。1回のループで直すのは原則1箇所。
4. 変更理由を1〜3行で出力する（`git diff` で確認できる粒度で説明）。

## 絶対に変更してはいけないもの

- `connectionReferences` / `connectionReferenceLogicalName` などの接続参照
- 認証情報、テナント ID、環境 ID、SharePoint の site / drive / file ID
- Excel コネクタの `table` パラメータの GUID
  （**重要**: 存在しない値に変えるとデプロイは通っても Power Automate の保存時動的検証
  `GetTable` が 404 を繰り返し、Graph API がスロットリング（429）してフローが有効化不能になる。
  Phase 1 で実際に発生した）
- `src/Other/Solution.xml` のバージョンや RootComponent
- `logs/` 配下、`docs/` 配下、`scripts/` 配下のファイル

## 安全な修正対象

- Data Operation 系（Filter array / Compose / Select / Join）の式
- 条件式・`from` / `where` の参照キー
- トリガー入力スキーマ（コネクタの動的検証対象外）

## 出力

修正後、以下を簡潔に出力してください。

1. 特定した失敗アクション名
2. 根本原因（1行）
3. 変更したファイルと変更内容（1〜3行）
4. 変更しなかった場合はその理由
