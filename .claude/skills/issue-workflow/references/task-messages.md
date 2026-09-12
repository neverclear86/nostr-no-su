# エージェントに渡す依頼文

役割ごとの基準と出力の書式はエージェント定義（`.claude/agents/issue-*.md`）にある。
ここには、実行ごとに変わる値だけを渡す依頼文の型を置く。`{{ }}` を埋めて `Agent` の `prompt` に渡す。
プランとレビューの全文は依頼文に貼らず、ファイルのパスか issue コメントの URL で渡す。

## issue-planner（版 1）

```
issue #{{N}} の実装プラン（版 1）を書いてほしい。
- 土台: origin/main の {{BASE_SHA}}
- 調査用の作業ツリー: {{PLAN_WORKTREE}}（`git -C /home/lina/workspace/projects/nostr-no-su worktree add --detach {{PLAN_WORKTREE}} {{BASE_SHA}}` で作る。無ければ作る）
- docker を使う検証の手順を書くときのプロジェクト名: {{DOCKER_PROJECT}}、ポート: {{PORTS}}
- プランの書き先: {{SCRATCHPAD}}/plans/{{N}}-v1.md
{{UI なら: - デザインの方針: {{DESIGN_COMMENT_URL}}。プランはこれを取り込む}}
{{関連する issue や決定があれば書く}}
返答は、方針の要約と決めたことの見出しの一覧だけにし、プランの全文は返さない。
```

## issue-planner（版 2 以降。新しいエージェントを立てる）

```
issue #{{N}} の実装プラン（版 {{V}}）を書いてほしい。前の版のレビューは REQUEST CHANGES だった。
- 前の版: {{SCRATCHPAD}}/plans/{{N}}-v{{V-1}}.md
- レビュー（ラウンド {{R}}）: {{SCRATCHPAD}}/plans/{{N}}-r{{R}}.md
- 土台: origin/main の {{BASE_SHA}}
- 調査用の作業ツリー: {{PLAN_WORKTREE}}（すでにある）
- 書き先: {{SCRATCHPAD}}/plans/{{N}}-v{{V}}.md（前の版をコピーしてから直す）
前の版の「決めたこと」は変えず、レビューの指摘の該当箇所だけ直す。指摘が「決めたこと」の変更を求めているときだけ、その 1 件を直す。
読むのは、issue と、レビューの「該当」と「根拠」が指すファイルに絞る。
返答は、先頭に置いた「指摘への対応」の表だけにし、プランの全文は返さない。
```

## issue-planner（実装中に設計に関わる逸脱が見つかったとき）

版 2 以降と同じ型で新しいエージェントを立てる。「前の版」には投稿済みのファイル `{{SCRATCHPAD}}/plans/{{N}}-post.md`（無ければ issue コメントの URL）を、「レビュー」の代わりに実装エージェントの報告（逸脱の箇所と理由）を書いたファイルを渡す。
「指摘への対応」の表は逸脱ごとの対応の表になる。上げた版は新しいプランレビュアーに渡し、APPROVE の後に issue に追記する。

## issue-plan-reviewer（ラウンド 1）

```
issue #{{N}} の実装プラン（版 1）をレビューしてほしい（ラウンド 1）。
- プラン: {{SCRATCHPAD}}/plans/{{N}}-v1.md
- 土台: origin/main の {{BASE_SHA}}
- 調査用の作業ツリー: {{PLAN_WORKTREE}}（すでにあるので、実行はこの下で行う）
- レビューの書き先: {{SCRATCHPAD}}/plans/{{N}}-r1.md
返答は、判定と、must、should、nit の件数と各指摘の見出しだけにし、レビューの全文は返さない。
```

## issue-plan-reviewer（ラウンド 2 以降。新しいエージェントを立てる）

```
issue #{{N}} の実装プラン（版 {{V}}）をレビューしてほしい（ラウンド {{R}}）。
- プラン: {{SCRATCHPAD}}/plans/{{N}}-v{{V}}.md（先頭に前ラウンドの指摘への対応の表がある）
- 前のラウンドのレビュー: {{SCRATCHPAD}}/plans/{{N}}-r{{R-1}}.md
- 土台: origin/main の {{BASE_SHA}}
- 調査用の作業ツリー: {{PLAN_WORKTREE}}（すでにある）
- レビューの書き先: {{SCRATCHPAD}}/plans/{{N}}-r{{R}}.md
前のラウンドの指摘ごとに直ったかを照合し、再判定してほしい。新しい指摘は前のラウンドで見落としたものに限る。
返答は、判定と、must、should、nit の件数と各指摘の見出しだけにし、レビューの全文は返さない。
```

## issue-implementer（最初の依頼）

```
issue #{{N}} を、承認済みの実装プラン（{{PLAN_COMMENT_URL}}）のとおりに実装し、PR を作ってほしい。プランは `gh api` でその URL のコメント本文を読む。
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
```

## issue-implementer（レビューを返す）

```
PR #{{PR}} のレビュー（ラウンド {{R}}、{{REVIEW_COMMENT_URL}}）は REQUEST CHANGES だった。指摘は `gh api` でその URL のコメント本文を読む。
直して push し、対応コメントを PR に投稿して、コメントの URL と新しい head を返してほしい。
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
