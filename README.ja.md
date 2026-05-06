# stagent

[English](./README.md) | [简体中文](./README.zh-CN.md) | **日本語** | [한국어](./README.ko.md) | [Français](./README.fr.md) | [Deutsch](./README.de.md) | [Español](./README.es.md)

**設定駆動の開発ワークフロー** をステートマシンとして実行する Claude Code プラグインです。ステージ・遷移・入力をひとつの `workflow.json` で宣言すれば、プラグインの hook とスクリプトがループを駆動します。

2 つのモード：
- **Cloud**（デフォルト）— 状態を[ホストされた Web アプリ](https://stagent.worldstatelabs.com/)にミラーリングし、ブラウザでライブ表示、マシンをまたいだ再開、プロジェクトディレクトリへの書き込みゼロ。
- **Local** — 状態と artifact は `<project>/.stagent/` 配下に保存され、ネットワーク不要。

## Quick Start

### インストール

ターミナルで以下のコマンドを実行してください。Cloud モードはデフォルトで有効 — 設定や鍵は不要で、`/stagent:start` と `/stagent:continue` は匿名セッションで動きます。アカウント（`/stagent:login`）が必要なのは、ワークフローを hub に publish するときと、認証済みオーナーシップを主張するときだけです。

```
claude plugin marketplace add jie-worldstatelabs/stagent && claude plugin install stagent@stagent
```

すでにインストール済みなら、更新：

```
claude plugin update stagent@stagent
```

必須：[Claude Code](https://claude.ai/claude-code)、`jq`、`curl`、`git`（cloud モードは `sha256sum` / `shasum` のような標準 POSIX ツールにも依存）。

### ワークフローを実行する

オプションですが推奨：session の所有権を主張し、過去の session をより良く管理するため、先にサインインしてください。

```
/stagent:login
```

デフォルトの開発ワークフローを起動します — あなたの説明どおりに構築します：

```
/stagent:start --flow=cloud://demo "Build a journaling app with MBTI insights inferred from journal entries"
```

skill がライブ UI の URL を出力します。サインインしていない場合、これは **匿名で誰でも閲覧できる** session URL となり、リンクを持つ誰もがステートマシンの実行をリアルタイムで追えます（ステージタイムライン、レンダリング済み artifact、`git diff baseline..HEAD` が SSE 経由でライブ更新）。所有者は存在しません。

完全オフラインで実行したい場合は local モードに切り替えてください：

```
/stagent:start --mode=local "Build a journaling app with MBTI insights inferred from journal entries"
```

### 自分のワークフローテンプレートを作る

自然言語のプロンプトからワークフローを定義 — stagent がステージを scaffolding します：

```
/stagent:create "plan, implement, critique & score UX"
```

このコマンドはデフォルトで **cloud** モードで動きます：planning + writing ステージが終わると、新しいテンプレートがあなたの hub アカウントに publish されます。まだサインインしていなければ先に：

```
/stagent:login
```

完全オフラインで動かしたい場合（テンプレートはローカルの `~/.config/stagent/workflows/<name>/` に置かれ、hub には push されません）、local モードに切り替え：

```
/stagent:create --mode=local "plan, implement, critique & score UX"
```

アイデアが欲しい？ [cookbook](https://stagent.worldstatelabs.com/cookbook) に、fork したり remix したりできる、実戦で鍛えられた 12 のワークフローテンプレートがあります。

## デフォルトのワークフロー

`--flow` フラグを付けない場合：

- **Cloud モード**（デフォルト）は hub から `cloud://demo` を取得 — この README とは独立に進化する可能性のあるホスト型テンプレート
- **Local モード**は `skills/stagent/workflow/` のプラグイン同梱ワークフローを使用（オフラインフォールバック）— 以下に説明されているサイクルの正本

同梱ワークフローは **plan → execute → verify → review → QA → deploy** のサイクルを回します：

1. **Planning** *(中断可能)* — あなたとのインライン Q&A：明確化のための質問、提案アプローチ、plan ファイル。あなたが確認するまで何も構築されません。
2. **Executing** — subagent（opus）が plan を実装：指定があれば test-first で、最小・焦点を絞った変更。
3. **Verifying** — クイックテスト（unit / integration）をインライン実行。FAIL → Execute へループ；PASS / SKIPPED → Review。
4. **Reviewing** — subagent が baseline コミットに対して敵対的コードレビューを実行。PASS → QA；FAIL → Execute へループ。
5. **QA-ing** — subagent が実際のユーザージャーニーテストを実行（Playwright、XcodeBuildMCP など）。テストのバグとアプリのバグを区別 — 確定したアプリのバグだけが進行をブロック。PASS → Deploy；FAIL → Execute へループ。
6. **Deploy** *(中断可能)* — Vercel CLI のインラインフロー：`vercel whoami`、初回 `vercel link`、production env vars の同期、`vercel --prod`、URL のスモークチェック。中断可能なのは、初回セットアップで別ターミナルでの `vercel login` や、あなたからの env-var 値が必要な場合があるため。完了 → terminal `complete`。

`execute → verify → review → QA` ループは plan を承認した後に **自律的に** 実行されます。Stop hook がループの完走を保証します（QA がパスするまで；その後 deploy が最終の中断可能ステージとして実行）。ループが停止する条件は次のいずれか：deploy 完了（terminal `complete`）、`max_epoch` に到達（デフォルト `20`、`workflow.json` → `.max_epoch` で設定；暴走反復を terminal `escalated` を強制することで止める）、あるいは `/stagent:interrupt`（一時停止）か `/stagent:cancel`（terminal `cancelled`）であなたが介入。3 つの terminal — `complete`、`escalated`、`cancelled` — はすべて `workflow.json` → `.terminal_stages` で宣言されます。

## カスタムワークフロー

プラグインは **汎用** — スキーマに従えばどんなステージ形式でも動きます。`/stagent:create`（Quick Start 参照）を実行すると、内部 stagent があなたにインタビューし、`workflow.json` + ステージごとの指示ファイルを `~/.config/stagent/workflows/<name>/` 配下に書き出し、リトライループ内で検証し、bundle を hub に publish します（cloud モードのみ）。再利用は次のとおり：

```
/stagent:start --flow=cloud://<you>/<name> <task>
```

`workflow.json` のスキーマは [ARCHITECTURE.md](./ARCHITECTURE.md) を参照。

何をワークフローにすべきかアイデアが必要？ [cookbook](https://stagent.worldstatelabs.com/cookbook) を参照 — Claude Code の典型的な失敗モード（goal pursuit、research-first、end-to-end v1、scope lock-down、invariant guardrails、root-cause forced、real bug hunt、strict TDD、real-journey suite、visual QA gate、perf gate、compliance gate）に対応した、すぐに動く 12 のワークフローがあり、それぞれ `/stagent:start --flow=cloud://...` で起動できます。

## コマンド

| コマンド | 用途 |
|---|---|
| `/stagent:start [--mode=cloud\|local] [--flow=<ref>] <task>` | 新しい run を開始 |
| `/stagent:interrupt` | 状態を消さずにアクティブな run を一時停止（ステージの途中でも呼び出し可；`/stagent:continue` で再開）|
| `/stagent:continue [--session <id>]` | 中断された run を再開（`--session` はマシンをまたいだ cloud 引き継ぎ用）|
| `/stagent:cancel [--hard]` | run をキャンセル。デフォルトはアーカイブ；`--hard` は完全削除。Local モードのファイルはそれに応じてアーカイブ／削除；cloud モードでは local shadow はどちらにせよクリアされ、違いはサーバー側のみ（archived vs hard-deleted）|
| `/stagent:create [--mode=cloud\|local] [--flow=<ref>] <description>` | 新しいワークフローを作成、または既存のワークフローを編集 |
| `/stagent:publish <dir> [--name <n>] [--description <d>] [--dry-run]` | local ワークフローを hub に publish |
| `/stagent:login` / `:logout` / `:whoami` | hub アイデンティティの管理 |

**`--flow=<ref>`** が受け付けるもの：
- *(省略)* — cloud モードは hub から `cloud://demo` を取得；local モードはプラグイン同梱ワークフローを使用
- `cloud://author/name` — hub から取得（cloud モード）
- `/abs/path` または `./rel/path` — ローカルワークフローディレクトリ
- `<bare-name>` — まずプラグイン同梱ワークフローを照合し、なければ hub の `cloud://<bare-name>` として解決

**環境変数：**

| 変数 | デフォルト | 効果 |
|---|---|---|
| `STAGENT_DEFAULT_MODE` | `cloud` | `local` に設定するとシェル内のすべての run でデフォルトを反転 |

## Local vs Cloud

| 項目 | Local | Cloud |
|---|---|---|
| 権威ある状態 | `<project>/.stagent/<session>/state.md` | Postgres `sessions` 行；local shadow がミラー |
| ファイルの保存場所 | プロジェクト worktree | `~/.cache/stagent/sessions/<session>/` — terminal で消去 |
| ライブビューア | なし — ファイルを読む | `https://stagent.worldstatelabs.com/s/<session_id>` |
| マシン間 continue | 非対応 | `/stagent:continue --session <id>` (project-fingerprint 検証付き) |
| 必要な `.gitignore` | `echo '/.stagent/' >> .gitignore` | 不要 |

### マシン間 / clone 間の引き継ぎに関する注意

`/stagent:continue --session <id>` はワークフローの **状態**（`state.md`、ステージレポート、加えて `baseline` run-file — ワークフロー開始時にキャプチャした git SHA）を新しいマシンにミラーします。プロジェクトのソースコードは **コピーしません**。コードはあなたの git リポジトリにあり、プラグインの中にはありません。

`continue-workflow.sh` は次を検証します：

1. 新しい workdir が同じリポジトリであること（root-commit fingerprint）。
2. 新しい workdir の HEAD が、ワークフローが最後に見た HEAD（`state.md` の `last_seen_head`、ステージ遷移と `/interrupt` のたびに更新）から遅れていない／分岐していないこと。遅れている／分岐している HEAD は `--force-project-mismatch` を渡さない限り **ハードブロック** — そうしないと再開されたステージが古いコードに対して走り、終わった作業をやり直したり矛盾したりすることになる。
3. 新しい workdir のコミットされていない変更はソフト警告 — 次のステージの出力と衝突する可能性があります。

元のセッションが中断前に subagent の作業をコミットしていれば、新しいマシンで `git fetch && git checkout <last_seen_head>`（またはそのブランチをマージ）すると `/continue` の前に同期できます。

## 主要な設計判断

- **設定駆動** — ステージ、遷移、interruptible フラグ、subagent タイプ／モデル、入力依存はすべて `workflow.json` に存在。ステージの追加や遷移の変更は config 編集であって、コード変更ではない。
- **ひとつの汎用 subagent** — すべての subagent ステージは単一の `workflow-subagent` の下で実行；ステージごとのプロトコルは `<workflow-dir>/<stage>.md` にあり、subagent が実行時に読む。ステージごとの `subagent_type` フィールドはなし。
- **必須入力が遷移をブロック** — `update-status.sh` は `required` 入力 artifact が欠けているステージへの遷移を拒否。ステートマシンレベルの強制。
- **Epoch スタンプ付き artifact** — 各ステージの artifact は生成時の epoch を持つ。stop hook は `state.md` の epoch と一致する artifact だけを信頼 — 前回イテレーションの古い artifact は無視される。
- **自己完結** — skill は agent に外部 skill を呼び出さないよう指示し、フローのハイジャックを防ぐ。
- **正常終了は自動 interrupt** — Claude Code セッションが正常終了するとき（例：`/exit`、ウィンドウを閉じる）、stagent の `SessionEnd` hook がアクティブなワークフローを `interrupted` にひっくり返し、別の Claude セッションが `/stagent:continue` で引き継げるようにする。クラッシュ／`kill -9` ではトリガーされない；cloud モードではサーバー側の stale 検出がバックストップ。
- **1 セッション = 1 run** — 各 Claude セッションの run は独自の session-keyed サブディレクトリ内で生活する。同じ worktree 内の複数の Claude セッションが互いに干渉せずに独立したワークフローを実行できる。

## アーキテクチャと内部

[ARCHITECTURE.md](./ARCHITECTURE.md) を参照：
- プラグインのディレクトリレイアウト
- ランタイムのファイルレイアウト（local + cloud）
- `workflow.json` スキーマリファレンス
- ステートマシンプロトコル（epoch、result、transitions）
- Stop-hook の挙動
- エンドツーエンドのサイクルウォークスルー

## License

MIT
