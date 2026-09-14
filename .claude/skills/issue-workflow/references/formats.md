# 書式（#56 と #61 で確立した形）

手本は issue #56 のコメント（プラン 4 版とプランレビュー 4 ラウンド）と PR #61 のコメント（レビュー 2 ラウンドと対応 2 件）である。
迷ったら次で読む。

```sh
gh api repos/neverclear86/nostr-no-su/issues/56/comments --jq '.[-2].body'   # 承認された版のプラン
gh api repos/neverclear86/nostr-no-su/issues/61/comments --jq '.[0].body'    # PR レビュー（ラウンド 1）
gh api repos/neverclear86/nostr-no-su/issues/61/comments --jq '.[1].body'    # 指摘への対応
gh pr view 61 -R neverclear86/nostr-no-su --json body --jq .body            # PR 本文
```

## issue に投稿するプラン（プランレビュアーが APPROVE のときに投稿）

```
## 実装プラン（版 N）

#N の実装プランである。土台は origin/main の `SHA` で、…。
プランレビューを R ラウンド行い、ラウンド R で APPROVE になった（must 0、should 0、nit K）。
残した nit: …（無ければ「無し」）

### 方針の要約
### 決めたこと
### 変更するファイル
### テスト
### 検証の手順
### 後続の作業
```

## PR 本文（実装エージェント）

```
## 概要
## 変更点
### `path`（何をしたかを 1〜3 行。行数は書かない）
## テストと検証
（`dev/pr_facts.sh <PR>` の表。検証の手順の出力の抜粋。掃き出した語）
## プランからの変更
## 後続の作業

Closes #N

🤖 Generated with [Claude Code](https://claude.com/claude-code)

<Claude-Session の URL>
```

## PR レビュー（PR レビュアーが投稿）

```
## レビュー（ラウンド R）

対象: <短い SHA>

判定: REQUEST CHANGES | APPROVE

### 指摘
#### must
#### should
#### nit
### 確認したこと
| 受け入れ条件 | 満たす変更（`path:行`） |
| 実行したコマンド | 環境 | 結果 |
```

「確認したこと」は 2 つの表だけで、問題が無かった観点を文で書かない（2026-09-13 の実測で、レビューの 67% が問題無しの語りだった）。

## 最終確認（issue-final-gate が投稿）

```
## 最終確認

対象: <短い SHA>（レビュー ラウンド R の APPROVE の後）

判定: APPROVE | REQUEST CHANGES

### 指摘
（無ければ「無し」）
### 読んだもの
（3 行以内）
```

## 指摘への対応（実装エージェントが投稿）

最終確認の指摘への対応は見出しを「## 最終確認の指摘への対応（<短い SHA>）」にする。

```
## レビュー（ラウンド R）の指摘への対応（<短い SHA>）

レビュー: <コメントの URL>

（直した件数、変えたファイルの範囲）

### must 1（`path:行`）
（変えた内容と確かめ方）
### should 2（…）
```

## 指摘の 1 件の形（プランレビューも PR レビューも同じ）

```
**1. 見出し（何が、どう問題か）**

- 該当: `path:行` またはプランの節
- 問題: …
- 根拠: 読んだファイルと行、実行したコマンドと結果
- 直し方の案: …
```

## squash コミット（issue-merger）

件名は PR タイトルに ` (#PR)` を付けたもの。本文はトレーラー 2 行だけ。

```
docs: .env.example を追加し、docker compose で試すときの設定を分かるようにする (#61)

Co-Authored-By: Claude … <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_…
```
