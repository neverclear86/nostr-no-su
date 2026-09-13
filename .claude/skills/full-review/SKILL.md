---
name: full-review
description: nostr-no-su の main に溜まったマージ済みの変更を、前回の全体確認からの範囲でまとめて fable に見直させ、所見を issue #63 にコメントし、must を issue に起票する手順。「全体確認して」「溜まった分をまとめて見て」「full-review」と頼まれたときに使う。issue-workflow の PR ごとの確認とは別に、ユーザーが余裕のあるときに呼ぶ。
---

# 全体確認（nostr-no-su）

対象のリポジトリは `neverclear86/nostr-no-su`（private）である。
issue-workflow スキルは fable を使わずに PR を 1 件ずつマージする。このスキルは、その代わりにマージが溜まった範囲をまとめて fable（エージェント定義 `full-reviewer`、fable / high）に見直させる。
PR ごとのレビューでは見えない、PR 同士の相互作用と範囲全体の設計の歪みを探すのが目的である。

所見の置き場は issue #63（全体レビューの親 issue）で、コメント「## 全体確認（from..to）」として積む。次回はその `to` から始める。

## 守ること

- **ユーザーの作業ツリーに触れない**：検証はスクラッチパッドに `git worktree add --detach` した `origin/main` で行う。ファイルは絶対パスで扱う
- **fable は 1 件だけ**：エージェントは 1 つ立て、並行させない。範囲が大きい（diff が 30 万文字を超える）ときは、範囲を 2 つに分けて順に回す
- **コードは直さない**：must は issue に起票する。should と nit は所見にとどめ、起票するかはユーザーに聞く
- **文体**：issue のコメントは標準的な技術文体の日本語で書く

## 手順

### 0. 範囲を決める

```sh
R=neverclear86/nostr-no-su
git -C /home/lina/workspace/projects/nostr-no-su fetch origin main
TO=$(git -C /home/lina/workspace/projects/nostr-no-su rev-parse origin/main)
FROM=$(gh api repos/$R/issues/63/comments --paginate --jq '[.[] | select(.body | startswith("## 全体確認（"))] | last | .body' | sed -n 's/^## 全体確認（\([0-9a-f]*\)\.\.\([0-9a-f]*\)）.*/\2/p')
[ -n "$FROM" ] || FROM=c730ed180e2e3cb0a63faeed96f8078594f45a7e   # #63 の全体レビューの対象
git -C /home/lina/workspace/projects/nostr-no-su log --oneline $FROM..$TO
git -C /home/lina/workspace/projects/nostr-no-su diff --stat $FROM..$TO | tail -1
git -C /home/lina/workspace/projects/nostr-no-su diff $FROM..$TO | wc -c
```

- `FROM..TO` の PR 番号は、`git log` の件名の `(#N)` から拾う。閉じた issue は各 PR 本文の `Closes #N` から拾う
- diff が空なら、ユーザーに「前回から変更が無い」と伝えて終える
- 作業ツリー `<scratchpad>/wt-full-review` を `git -C /home/lina/workspace/projects/nostr-no-su worktree add --detach <scratchpad>/wt-full-review $TO` で作る
- テスト用 Postgres のポートを `ss -ltn` で選ぶ（ユーザーの 5432、他セッションの 5433 は避ける）

### 1. エージェントを立てる

`Agent` ツールで `subagent_type: "full-reviewer"` を立てる（`model` は渡さない）。依頼文は次のとおり。

```
main の {{FROM}}..{{TO}} を全体確認してほしい。
- 範囲の PR: #{{A}}, #{{B}}, …（{{N}} 件）。閉じた issue: #…
- 作業ツリー: {{WORKTREE}}（origin/main の {{TO}} を取り出してある）
- テスト用 Postgres のポート: {{PG_PORT}}
- 所見の書き先: {{SCRATCHPAD}}/full-review-{{TO の短い SHA}}.md
返答は must、should、nit の件数と各指摘の見出しだけにし、所見の全文は返さない。
```

結果は後から届く通知で受け取る。届くまで待つ。

### 2. 所見を投稿する

所見のファイルを読み、書式（`## 全体確認（from..to）` で始まること、検証結果の表があること）を確かめて、issue #63 にコメントする。

```sh
gh issue comment 63 -R neverclear86/nostr-no-su --body-file <scratchpad>/full-review-<SHA>.md
```

### 3. must を起票する

must の指摘ごとに issue を作る（#63 のサブ issue と同じ形）。

```sh
gh issue create -R neverclear86/nostr-no-su --title "<見出し>" --body-file <scratchpad>/issue-<n>.md
```

本文は「## 背景（どの PR で入ったか、全体確認のコメントの URL）」「## 問題」「## 受け入れ条件」「## 根拠」で書く。
should と nit は起票せず、ユーザーに一覧を見せて起票するものを選んでもらう。

### 4. 片付けと報告

```sh
git -C /home/lina/workspace/projects/nostr-no-su worktree remove --force <scratchpad>/wt-full-review
```

ユーザーへの報告は、範囲（PR の件数）、検証結果、must / should / nit の件数、起票した issue の番号、所見のコメントの URL を短くまとめる。
