# エージェントに渡す依頼文

役割ごとの基準と出力の書式はエージェント定義（`.claude/agents/issue-*.md`）にある。
ここには、実行ごとに変わる値だけを渡す依頼文の型を置く。`{{ }}` を埋めて `Agent` の `prompt` に渡す。

## issue-planner（最初の依頼）

```
issue #{{N}} の実装プラン（版 1）を書いてほしい。
- 土台: origin/main の {{BASE_SHA}}
- 調査用の作業ツリー: {{PLAN_WORKTREE}}（`git -C /home/lina/workspace/projects/nostr-no-su worktree add --detach {{PLAN_WORKTREE}} {{BASE_SHA}}` で作る。無ければ作る）
- docker を使う検証の手順を書くときのプロジェクト名: {{DOCKER_PROJECT}}、ポート: {{PORTS}}
{{UI なら: - デザインの方針: {{DESIGN_COMMENT_URL}}。プランはこれを取り込む}}
{{関連する issue や決定があれば書く}}
返答はプランの全文だけにする。
```

## issue-planner（レビューを返す）

```
プランレビュー（ラウンド {{R}}）の結果は REQUEST CHANGES だった。指摘の全文を下に貼る。
指摘ごとに直すか直さないかを表にして、版 {{V+1}} の全文を返してほしい。
---
{{レビューの全文}}
```

## issue-plan-reviewer（最初の依頼）

```
issue #{{N}} の実装プラン（版 1）をレビューしてほしい（ラウンド 1）。
- 土台: origin/main の {{BASE_SHA}}
- 調査用の作業ツリー: {{PLAN_WORKTREE}}（すでにあるので、実行はこの下で行う）
プランの全文は下に貼る。
---
{{プランの全文}}
```

## issue-plan-reviewer（次の版を送る）

```
版 {{V}} が来た（ラウンド {{R}}）。前のラウンドの指摘ごとに直ったかを照合し、再判定してほしい。
---
{{プランの全文}}
```

## issue-implementer（最初の依頼）

```
issue #{{N}} を、承認済みの実装プラン（{{PLAN_COMMENT_URL}}）のとおりに実装し、PR を作ってほしい。
- 土台: origin/main の {{BASE_SHA}}
- 作業ツリー: {{WORKTREE}}、ブランチ: {{BRANCH}}（`git -C /home/lina/workspace/projects/nostr-no-su fetch origin main && git -C /home/lina/workspace/projects/nostr-no-su worktree add -b {{BRANCH}} {{WORKTREE}} origin/main` で作る）
- テスト用 Postgres のポート: {{PG_PORT}}。docker のプロジェクト名: {{DOCKER_PROJECT}}、ポート: {{PORTS}}
- コミットのトレーラー（本文の最後に 2 行）:
  {{CO_AUTHORED_BY}}
  {{CLAUDE_SESSION}}
- PR 本文の末尾（`Closes #{{N}}` の後に 2 行）:
  🤖 Generated with [Claude Code](https://claude.com/claude-code)
  {{CLAUDE_SESSION_URL}}
{{UI なら: - UI を変えるので、変更前と変更後のスクリーンショットを PR に貼る}}
プランの全文は下に貼る。
---
{{プランの全文}}
```

## issue-implementer（レビューを返す）

```
PR #{{PR}} のレビュー（ラウンド {{R}}、{{REVIEW_COMMENT_URL}}）は REQUEST CHANGES だった。指摘の全文を下に貼る。
直して push し、対応コメントを PR に投稿して、コメントの URL と新しい head を返してほしい。
---
{{レビューの全文}}
```

## issue-pr-reviewer（最初の依頼）

```
PR #{{PR}}（issue #{{N}}、ブランチ {{BRANCH}}、head {{HEAD_SHA}}）をレビューしてほしい（ラウンド 1）。
- 承認済みのプラン: {{PLAN_COMMENT_URL}}
- 土台: origin/main の {{BASE_SHA}}
- 再現用の作業ツリー: {{REVIEW_WORKTREE}}（`git -C /home/lina/workspace/projects/nostr-no-su fetch origin {{BRANCH}} && git -C /home/lina/workspace/projects/nostr-no-su worktree add --detach {{REVIEW_WORKTREE}} origin/{{BRANCH}}` で作る）
- テスト用 Postgres のポート: {{PG_PORT}}。docker のプロジェクト名: {{DOCKER_PROJECT}}、ポート: {{PORTS}}
{{UI なら: - UI を変える PR なので、スクリーンショットと CSS の再ビルドも見る}}
レビューを PR コメントに投稿し、URL と判定を返してほしい。
```

## issue-pr-reviewer（次のラウンド）

```
実装側がラウンド {{R-1}} の指摘に対応した（{{RESPONSE_COMMENT_URL}}、head {{HEAD_SHA}}）。
作業ツリーを `git -C {{REVIEW_WORKTREE}} fetch origin {{BRANCH}} && git -C {{REVIEW_WORKTREE}} checkout --detach origin/{{BRANCH}}` で進め、ラウンド {{R}} をレビューしてほしい。
```

## issue-final-gate（最初の依頼）

```
PR #{{PR}}（issue #{{N}}、head {{HEAD_SHA}}）の最終確認をしてほしい。
- 承認済みのプラン: {{PLAN_COMMENT_URL}}
- PR レビューの APPROVE: {{REVIEW_APPROVE_URL}}（ラウンド {{R}}）
再現はせず、diff とレビューの経緯と受け入れ条件の照合だけを行い、「## 最終確認」を PR コメントに投稿して、URL と判定を返してほしい。
```

## issue-final-gate（再確認）

```
最終確認の指摘に実装側が対応し（{{RESPONSE_COMMENT_URL}}）、PR レビュアーも再レビューで APPROVE を出した（{{REVIEW_APPROVE_URL}}）。head は {{HEAD_SHA}} である。
前回の指摘ごとに直ったかを照合し、再確認の結果を PR コメントに投稿して、URL と判定を返してほしい。
```
