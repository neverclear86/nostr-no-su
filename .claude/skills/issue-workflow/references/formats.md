# 書式

下の「マーカー」以降がこの文書の定める今の書式である。迷ったらそちらに従う。
下の各節のブロックは本文ファイルの中身で、投稿されたコメントの 1 行目には `dev/post_comment.sh` が付けるマーカーが入る。
改修前の形の手本として issue #56 のコメント（プラン 4 版とプランレビュー 4 ラウンド）と PR #61 のコメント（レビュー 2 ラウンドと対応 2 件）がある。
これらはマーカーも畳み込みも往復の上限 2 も無い時期のものなので、節の構成だけを参考にし、書式は写さない。
改修後の手本は、最初の実行の PR を後で足す。

```sh
gh api repos/neverclear86/nostr-no-su/issues/56/comments --jq '.[-2].body'   # 承認された版のプラン
gh api repos/neverclear86/nostr-no-su/issues/61/comments --jq '.[0].body'    # PR レビュー（ラウンド 1）
gh api repos/neverclear86/nostr-no-su/issues/61/comments --jq '.[1].body'    # 指摘への対応
gh pr view 61 -R neverclear86/nostr-no-su --json body --jq .body            # PR 本文
```

## マーカー

ワークフローが投稿するコメント（とプランレビューのファイル）は、1 行目を HTML コメントのマーカーにする。見出しは 2 行目以降に置く。

```
<!-- nns kind=<種別> round=<N> verdict=<APPROVE|REQUEST CHANGES|NEEDS_USER|-> head=<短い SHA|-> -->
```

投稿は `sh dev/post_comment.sh <issue|pr> <番号> <kind> <round> <verdict> <head> <本文ファイル>` で行う。マーカー行はスクリプトが引数から機械的に作るので、本文ファイルには書かない。引数の `kind` / `round` / `verdict` / `head` は下の表の欄がそのまま対応する。

| kind | 投稿するもの | round | verdict | head |
| --- | --- | --- | --- | --- |
| `design` | デザインの方針（issue） | `1` | `-` | `-` |
| `split` | 分割の設計（親 issue） | `1` | `-` | `-` |
| `plan` | 承認された実装プラン（issue） | 承認したラウンド | `APPROVE` | `-` |
| `plan-review` | プランレビュー（ファイルの 1 行目） | ラウンド | 判定 | `-` |
| `pr-review` | PR レビュー（PR） | ラウンド | 判定 | レビューした head |
| `fix` | 指摘または条件への対応（PR） | 対応したラウンド | `-` | push した head |
| `gate` | 最終確認（PR） | 何回目か | 判定 | 見た head |
| `summary` | まとめ（PR） | 最終確認の回 | `-` | 見た head |
| `retro` | ふりかえりの issue の精査（issue） | `1` | `-` | `-` |

マージ担当は承認の検出をこのマーカーで行う（`kind=pr-review` と `kind=gate` の最後の 1 件の `verdict`）。見出しの完全一致は使わない。
`round` に `-` は使わない。段階に番号が無いもの（`design`、`split`）は `1` にする。

## 畳み込み

長い本文は `<details>` に畳み、読み手が次に取る行動を決める部分だけを外に出す。

| 投稿 | 外に出すもの | 畳むもの |
| --- | --- | --- |
| プラン | 「決めたこと」と「受け入れ条件 → 満たす変更」の表（合わせて 3,000 字以内） | 本文（方針の要約、変更するファイル、テスト、検証の手順、後続の作業） |
| PR レビュー | 判定と must / should / nit の件数の行 | 指摘、確認したこと |
| 指摘への対応 | 直した件数 | 指摘ごとの対応 |
| 最終確認 | 判定と件数の行 | 指摘、読んだもの |
| まとめ | 全部（短いので畳まない） | — |

## issue に投稿するプラン（プランレビュアーが APPROVE のときに投稿）

```
## 実装プラン（版 N）

#N の実装プランである。土台は origin/main の `SHA` で、…。
プランレビューを R ラウンド行い、ラウンド R で APPROVE になった（must 0、should S、nit K）。
残した nit: …（無ければ「無し」）

### 実装時の条件
（置換文か 1 行の追記で直る should を番号付きで。実装者が取り込む。無ければ「無し」）
### 決めたこと
### 受け入れ条件
| 受け入れ条件 | 満たす変更 |

<details>
<summary>プランの全文</summary>

### 方針の要約
### 変更するファイル
### テスト
### 検証の手順
### 後続の作業

</details>
```

## PR 本文（実装エージェント）

```
## 概要
（devin にコードを書かせたときは「実装: devin（swe-2-max）、検査と PR: Claude」の 1 行を置く）
## 設計メモ
（プランが無いとき（tier none）だけ。「### 決めたこと」と「### 受け入れ条件」の表）
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

判定: REQUEST CHANGES | APPROVE（must M、should S、nit K）

<details>
<summary>指摘</summary>

#### must
#### should
#### nit

</details>

<details>
<summary>確認したこと</summary>

| 受け入れ条件 | 満たす変更（`path:行`） |
| 実行したコマンド | 環境 | 結果 |

</details>
```

「確認したこと」は 2 つの表だけで、問題が無かった観点を文で書かない（2026-09-13 の実測で、レビューの 67% が問題無しの語りだった）。
判定は must が 0 件なら APPROVE で、残った should は `conditions` として返す（再レビューはせず、実装者が直して最終確認に進む）。must には直し方の案を書かない。
nit は 5 件まで本文を書き、残りは「ほかに N 件」と件数だけを書く。判定の行の nit K は書かなかった分を含めた総数である。

## 最終確認（issue-final-gate が投稿）

```
## 最終確認

対象: <短い SHA>（レビュー ラウンド R の APPROVE の後）

判定: APPROVE | REQUEST CHANGES。must M、should S、nit K

<details>
<summary>指摘と読んだもの</summary>

### 指摘
（無ければ「無し」）
### 読んだもの
（3 行以内）

</details>
```

## まとめ（issue-final-gate が APPROVE の後に 1 本投稿）

```
## まとめ

| tier | プランのラウンド | PR レビューのラウンド | 条件 | 実装起因の must |
| --- | --- | --- | --- | --- |
| light | 1 | 2 | 2 件 | 1 件 |

### 学び
（定義・手順・スクリプトの改善に効く気づきを 0〜3 件、1 件 1〜2 行。無ければ「無し」）
```

表の値は依頼文の「この実行の経緯」をそのまま使う（プランのラウンド数の括弧の断りも写す）。学びは定型の言い直しや一般論を書かず、この issue で実際に起きたことから書く。

## 指摘への対応（実装エージェントが投稿）

最終確認の指摘への対応は見出しを「## 最終確認の指摘への対応（<短い SHA>）」、レビューの条件への対応は「## レビューの条件への対応（<短い SHA>）」にする。マーカーはどれも `kind=fix` である（マージ担当がこれで「条件への対応の push」を判別する）。
対応の中でプランの版が上がったときは、`<details>` の中に「### プランの版の差分」の表（新しい版が足した・変えた項目ごとの実装の有無）を置く。

```
## レビュー（ラウンド R）の指摘への対応（<短い SHA>）

レビュー: <コメントの URL>

（直した件数、変えたファイルの範囲）

<details>
<summary>指摘ごとの対応</summary>

### must 1（`path:行`）
（変えた内容と確かめ方）
### should 2（…）

</details>
```

## 指摘の 1 件の形

```
**1. 見出し（何が、どう問題か）**

- 該当: `path:行` またはプランの節
- 問題: …
- 根拠: 読んだファイルと行、実行したコマンドと結果
- 直し方の案: …
```

PR レビューの must だけは「直し方の案」を書かず、該当・問題・根拠で終える（説明と修正案を同時に求めると誤判定が増える）。プランレビューの must と、どちらの should・nit も上の形のままである。

## squash コミット（issue-merger）

件名は PR タイトルに ` (#PR)` を付けたもの。本文はトレーラー 2 行だけ。

```
docs: .env.example を追加し、docker compose で試すときの設定を分かるようにする (#61)

Co-Authored-By: Claude … <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_…
```
