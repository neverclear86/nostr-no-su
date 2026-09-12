---
name: issue-workflow
description: nostr-no-su の GitHub issue を 1 件ずつ、プラン作成（opus）→ プランレビュー（fable）の往復 → プランを issue に投稿 → 実装と PR 作成（opus）→ PR レビュー（opus）の往復 → fable の最終確認 → squash マージまで、エージェントの分業で進める手順。「#64 を進めて」「issue を実装してマージまで」「プランからマージまで回して」「いつもの流れで」「must-fix を順に片付けて」のように、issue 番号を挙げて実装や対応を頼まれたときは、プランや実装だけを頼まれたように見えても必ずこのスキルを使う。
---

# issue ごとの分業パイプライン（nostr-no-su）

対象のリポジトリは `neverclear86/nostr-no-su`（private）である。
1 件の issue を、役割ごとに別のエージェントで、次の順に進める。

| 段階 | エージェント（`subagent_type`） | モデル / effort | 成果物 |
| --- | --- | --- | --- |
| 1. プラン作成 | `issue-planner` | opus / medium | 実装プランのファイル `<scratchpad>/plans/{{N}}-v{{V}}.md` |
| 2. プランレビュー | `issue-plan-reviewer` | fable / high | レビューのファイル `<scratchpad>/plans/{{N}}-r{{R}}.md` と判定。REQUEST CHANGES なら新しいプランエージェントに戻す |
| 3. プランの投稿 | オーケストレーター（自分） | | issue コメント「## 実装プラン（版 N）」 |
| 4. 実装 | `issue-implementer` | opus / medium | ブランチ、コミット、PR |
| 5. PR レビュー | `issue-pr-reviewer` | opus / high | PR コメント「## レビュー（ラウンド N）」。REQUEST CHANGES なら実装エージェントに戻す |
| 5b. 最終確認 | `issue-final-gate` | fable / medium | PR コメント「## 最終確認」。diff とレビューの経緯だけを読み、再現はしない |
| 6. マージ | オーケストレーター（自分） | | `gh pr merge --squash --delete-branch` |

役割ごとの基準、出力の書式、安全策は `.claude/agents/issue-*.md` のエージェント定義に書いてあり、モデルと effort もそこで固定している。`Agent` ツールでは `subagent_type` に定義の名前を渡し、`model` は渡さない。
fable を使うのはプランレビューと、マージ直前の最終確認だけである。設計の誤りは後の段階で見つかるほど高くつくので、いちばん賢いモデルをプランレビューに集中させ、実装と PR レビュー（再現を含む読む量の多い作業）は opus で済ませる。最終確認は diff とレビューの経緯だけを読む軽い確認なので、fable でも読む量が小さい。オーケストレーター自身も、全エージェントの結果が流れ込む長い文脈を持つので、fable ではなく opus で動かす。

実行ごとに変わる値（issue 番号、ブランチ、作業ツリー、ポート、トレーラー）はプロンプトで渡す。

- [references/task-messages.md](references/task-messages.md) — 各エージェントへの依頼文の型（最初の依頼と、往復で返すときの文）
- [references/formats.md](references/formats.md) — issue コメント、PR 本文、レビューの書式（#56 と #61 で確立した形）

## 費用の実測から決めたこと（2026-09-12 のセッションの集計）

22 件の issue を並行で回したセッションでは、費用の 49% がプラン作成、20% がプランレビュー、14% がオーケストレーターだった。
重さの正体はモデルや effort ではなく「文脈の大きさ × リクエスト回数」で、次の 4 つが効いていた。この節の決定はそれぞれに対応する。

- 先行して 22 件のプランを作ったが、実装まで進んだのは 9 件だった。残りは main が進むと古びる → **先行プランは 1〜2 件まで**
- サブエージェントのプロンプトキャッシュは 5 分で切れる。レビューを待つ 20〜30 分の間に失効し、`SendMessage` で戻すとラウンドの最初に文脈全体（30〜70 万トークン）を書き直していた。書き直しだけで費用の 13% → **プランの往復は新しいエージェントで行う**
- プラン全文（3〜7 万文字）を依頼文に貼り、版ごとに全文を返させ、オーケストレーター経由で各段階に貼り回していた。オーケストレーターの文脈が 40 万トークンを超えて圧縮が走った → **プランはファイルと issue の URL で受け渡し、返答は要旨と判定だけにする**
- プランにコードが丸ごと入っていた（最大 7.4 万文字） → **コードを書くのは複雑な処理だけにする**

## 前提と守ること

- **先行プランは 1〜2 件まで**：実装中の issue の次の 1〜2 件だけプランを進める。それより先のプランは、前の issue がマージされてから始める。プランは main が進むと古びるし、レビューが承認しても実装まで進まなければ費用が無駄になる
- **プランの往復は新しいエージェントで行う**：プランレビューが REQUEST CHANGES を返したら、同じプランエージェントに `SendMessage` で戻さず、新しい `issue-planner` を立てて、前の版のファイルとレビューのファイルを渡す。次のラウンドのレビューも新しい `issue-plan-reviewer` を立て、前のレビューのファイルと新しい版のファイルを渡す。サブエージェントのキャッシュは 5 分で切れるので、待ち時間のあとに同じエージェントへ戻すと文脈全体を書き直す。新しいエージェントは、レビューの「該当」が指す箇所だけ読めばよいので文脈が小さい。引き継ぎは、プランの先頭の「指摘への対応」の表と、レビューの先頭の「前ラウンドの指摘の照合」の表で行う。新しいプランエージェントには「前の版の決めたことは変えず、指摘の該当箇所だけ直す」と伝え、再議論を防ぐ
- **プランはファイルで受け渡す**：プランエージェントは `<scratchpad>/plans/{{N}}-v{{V}}.md` に書き、レビュアーは `<scratchpad>/plans/{{N}}-r{{R}}.md` に書く。依頼文にはパスだけを書き、全文を貼らない。エージェントの返答は要旨と判定だけにし、全文を返させない。承認の後は issue に投稿し、実装以降の段階には issue コメントの URL だけを渡す。オーケストレーターがプランの全文を読むのは、投稿する前に先頭の書式を整えるときだけにする
- **実装と PR レビューの往復は同じエージェントに戻す**：実装エージェントは作業ツリーとビルドの状態を持ち、PR レビュアーは再現の環境を持つので、`SendMessage` で同じエージェントに送る（書き直しの費用は小さく、状態を引き継ぐ価値が大きい）。`SendMessage` は遅延ツールなので、最初に `ToolSearch` の `select:SendMessage` で読み込んでおく。エージェントは `Agent` ツールで `subagent_type` を指定して立てる。エージェントの結果と `SendMessage` への返答は、戻り値ではなく後から届く通知で受け取る。届くまで待ち、`ListAgents` を繰り返し呼んだり催促の送信をしたりしない
- **レビューの「承認」は PR コメントで表す**：全エージェントが同じ GitHub アカウントで動くので、自分の PR に `gh pr review --approve` は使えない（GitHub が拒否する）。レビューは PR コメントに残し、`判定: APPROVE` かつ must と should が 0 件であることを承認とみなす。nit は残っていてもよい
- **ユーザーの作業ツリーに触れない**：実装もレビューの再現も、スクラッチパッドに `git worktree add` した作業ツリーで行う。Bash の cwd はユーザーの作業ツリーに戻るので、ファイルは絶対パスで扱う。docker を使うときはプロジェクト名とポートを固有にし、エージェント定義の docker の節の安全策が効くようにプロジェクト名とポートを依頼文で渡す
- **文体**：issue、PR、コミット、コード内コメントは標準的な技術文体の日本語で書く（ギャル口調は使わない）。issue と PR の文章はスキル `japanese-tech-writing` の規範に従う（サブエージェントには読み込まれないので、プロンプトの「である調、一文一行、根拠の無い形容を避ける」が契約であり、詳しく従わせたいときは `~/.claude/skills/japanese-tech-writing/SKILL.md` を読ませる）
- **実装とレビューの基準**：DRY、シンプルさ、命名、仕様（issue とプラン）への準拠を厳しめに見る。関数型の書き方を重視し、全関数に簡潔な Doc コメントを書く。コメントは日本語（ログ文字列と識別子は英語のまま）
- **互換性は持たない**：v0.1 未満で非公開なので、消した設定や API は「最初から無かったもの」として扱い、廃止ログ、移行案内、互換レイヤーは作らない。バンカー無効での起動は想定しない
- **UI を変える issue**：プランの前にデザインエージェント（`Agent` の `model: "opus"`。専用の定義は無い）を立て、画面構成、コンポーネント、テーマ、狭い幅、空とエラーの状態の方針を issue にコメントさせ、プランエージェントに取り込ませる。PR には変更前（main）と変更後のスクリーンショットを `gh pr comment --attach` で貼る。見た目が変わらないリファクタリングでも貼る（変わらないことの証拠になる）。管理 UI の `.gleam` を変えたら `npm run build:css` の結果をコミットする（CI が差分を検査する）
- **往復に回数の上限は設けない**：must と should が 0 になるまで回す。ただし機械的に回し続けず、次のどれかになったら止めてユーザーに報告する。レビュアーが同じ趣旨の指摘を言い換えて繰り返している、作成側とレビュアーの判断が割れて両方が根拠を出し尽くしている、レビュアーが「ユーザーの判断が要る」と返した、指摘が issue の範囲を超え始めた
- **複数の issue は順に処理する**：どれも main にマージされるので並行させると衝突する。1 件をマージしてから次の issue を `origin/main` の最新から始める。同時に動かすエージェントは全体で 4 件までにする
- **コミットのトレーラー**：サブエージェントはこのセッションの system-reminder を見ないので、`Co-Authored-By` と `Claude-Session` の行をこのセッションの指定から写して、実装エージェントのプロンプトに入れる

## 手順

### 0. 準備

```sh
gh issue view {{N}} -R neverclear86/nostr-no-su --comments
git -C /home/lina/workspace/projects/nostr-no-su fetch origin main
mkdir -p <scratchpad>/plans
```

issue の本文とコメントを読み、次を決める。

- **土台のコミット**：`origin/main` の先頭。プランにも PR にも書く
- **ブランチ名**：`feat/…`、`fix/…`、`docs/…`、`refactor/…` の形で英語
- **作業ツリーの場所**：スクラッチパッドの下。プランとプランレビューの調査用に `<scratchpad>/wt-{{N}}-plan`（`--detach` で origin/main）、実装用に `<scratchpad>/wt-{{N}}`、レビュアーの再現用に `<scratchpad>/wt-{{N}}-review`。役割ごとに分けるのは、同じブランチを 2 つの作業ツリーで持てないのと、プラン側の実験が実装の差分に混ざらないようにするため
- **docker が要るか**：要るなら固有のプロジェクト名（`nns-issue{{N}}`、`nns-review{{N}}`）と空いているポート（`ss -ltn` で確かめる。ユーザーの 8080 と 5432、他セッションの 5433 と 7777 は避ける）
- **UI を変えるか**：変えるならデザインエージェントを先に立てる
- **既存のプラン**：issue にすでに「## 実装プラン（版 N）」と `判定: APPROVE` のレビューがあれば、段階 1〜3 は飛ばして 4 から始める。土台のコミットが今の `origin/main` より古いときは、その間の差分がプランの触るファイルに掛かっていないかを確かめ、掛かっていればプランレビューからやり直す

### 1〜2. プランとプランレビューの往復

1. `references/task-messages.md` の依頼文を埋めて `issue-planner` を立てる。プランは `<scratchpad>/plans/{{N}}-v1.md` に書かせ、返答は要旨（方針の要約と、決めたことの見出し）だけにさせる
2. 依頼文にプランのファイルのパスを書いて `issue-plan-reviewer` を立てる。レビューは `<scratchpad>/plans/{{N}}-r1.md` に書かせ、返答は判定と must、should、nit の件数と各指摘の見出しだけにさせる
3. `判定: REQUEST CHANGES` なら、新しい `issue-planner` を立て、前の版とレビューのファイルのパスを渡して、次の版 `{{N}}-v{{V+1}}.md` を書かせる。次に新しい `issue-plan-reviewer` を立て、次の版と前のレビューのファイルのパスを渡して再判定させる
4. `判定: APPROVE` になるまで 3 を繰り返す

プランエージェントは、issue の前提が間違っている、または選択肢がユーザーの判断を要すると考えたら、プランではなく質問を返す。その場合はユーザーに聞いてから続ける。

### 3. プランの投稿

承認された版のファイルの先頭を `references/formats.md` の書式に整えて（`## 実装プラン（版 N）`、レビューのラウンド数と最終ラウンドの指摘の要旨、残した nit）、issue に投稿する。版 2 以降の先頭にある「指摘への対応」の表は投稿には含めない。

```sh
gh issue comment {{N}} -R neverclear86/nostr-no-su --body-file <scratchpad>/plans/{{N}}-post.md
```

プランの途中の版とレビューの全文は issue には貼らない（往復はエージェント間で完結させ、issue には承認済みの版だけを残す）。

### 4. 実装と PR

`references/task-messages.md` の依頼文を埋めて `issue-implementer` を立てる。issue コメントの URL とコミットのトレーラーを渡し、プランは実装エージェント自身に `gh api` で読ませる（全文は貼らない）。
PR を作るところまで任せ、PR 番号と head のコミットを返させる。

実装エージェントは、プランどおりに作れない箇所が見つかったら勝手に設計を変えず、理由を添えて報告する。オーケストレーターは、小さな逸脱なら実装エージェントに判断を返し、設計に関わるなら新しいプランエージェントに承認済みの版と逸脱の内容を渡して版を上げ、issue に追記する。

### 5. PR レビューの往復

1. `references/task-messages.md` の依頼文を埋めて `issue-pr-reviewer` を立てる。レビューを PR コメントに投稿させ、判定を返させる
2. `判定: REQUEST CHANGES` なら、レビューコメントの URL を実装エージェントに `SendMessage` で送る（指摘は実装エージェント自身に `gh api` で読ませる）。実装エージェントは直したコミットを push し、対応の内容を PR コメントに投稿する（`references/formats.md` の「指摘への対応」）
3. 実装エージェントの対応コメントの URL と head のコミットを PR レビュアーに `SendMessage` で送り、次のラウンドをレビューさせる
4. `判定: APPROVE`（must 0、should 0）になるまで 2〜3 を繰り返す

### 5b. 最終確認（fable）

PR レビュアーの APPROVE の後、`references/task-messages.md` の依頼文を埋めて `issue-final-gate` を立てる。再現はさせず、diff、PR 本文、レビューと対応のコメント、プラン、issue の受け入れ条件を読ませて、「## 最終確認」を PR コメントに投稿させる。

- `判定: APPROVE` なら 6 へ進む
- `判定: REQUEST CHANGES` なら、指摘のコメントの URL を実装エージェントに `SendMessage` で送って直させ、対応コメントを投稿させる。次に PR レビュアーに `SendMessage` で対応コミットを再レビューさせ（対応の範囲に収まっているか、再現が要るかはレビュアーが決める）、APPROVE の後に最終確認のエージェントへ `SendMessage` で再確認を頼む。最終確認が APPROVE になるまで繰り返す

### 6. マージ

承認の後、オーケストレーターが自分で次を確かめてからマージする。レビュアーにマージさせない（自分の PR に承認を付けられない構成なので、ハーネスが「Merge Without Review」の警告を出すことがある）。

```sh
R=neverclear86/nostr-no-su
gh pr view {{PR}} -R $R --json headRefOid,mergeable,commits --jq '{head: .headRefOid, mergeable, last: .commits[-1].committedDate}'
gh api repos/$R/issues/{{PR}}/comments --jq '.[] | select(((.body | startswith("## レビュー")) or (.body | startswith("## 最終確認"))) and (.body | contains("の指摘への対応") | not)) | "\(.created_at) \(.body | split("\n") | map(select(startswith("判定"))) | .[0])"'
gh pr checks {{PR}} -R $R
```

- 「## レビュー」の最後の `判定: APPROVE` と、「## 最終確認」の最後の `判定: APPROVE` が、どちらも head のコミットより後の時刻であること
- APPROVE の後に push が無いこと（あれば nit だけの対応で、レビュアーが再レビュー不要と明言しているか、もう 1 ラウンド回す）
- CI の 3 つのジョブ（`test`、`admin-css`、`plugin-event-logger`）が pass であること
- `mergeable` が `MERGEABLE` であること。main が進んで衝突するなら実装エージェントに rebase させ、レビュアーに差分が rebase だけであることを確かめさせる

マージの前に、実装用とレビュー用の作業ツリーを消す（`--delete-branch` はローカルのブランチも消すので、作業ツリーがブランチを持ったままだと失敗する）。

```sh
git -C /home/lina/workspace/projects/nostr-no-su worktree remove --force <scratchpad>/wt-{{N}}
git -C /home/lina/workspace/projects/nostr-no-su worktree remove --force <scratchpad>/wt-{{N}}-review
git -C /home/lina/workspace/projects/nostr-no-su worktree remove --force <scratchpad>/wt-{{N}}-plan
gh pr merge {{PR}} -R $R --squash --delete-branch --subject "{{PR タイトル}} (#{{PR}})" --body "$(printf '%s\n' "{{Co-Authored-By 行}}" "{{Claude-Session 行}}")"
git -C /home/lina/workspace/projects/nostr-no-su fetch --prune origin
```

squash コミットの件名は PR のタイトルに `(#PR番号)` を付けたもの、本文はトレーラーだけにする（直近の main の履歴と同じ形）。
issue が PR の `Closes #N` で閉じたことを `gh issue view` で確かめる。閉じていなければ `gh issue close` で閉じる。

## ユーザーへの報告

1 件ごとに、issue 番号、プランのラウンド数、PR 番号、PR レビューのラウンド数、最終確認の結果、マージのコミット、残した nit と後続の issue にした事項を短くまとめる。
途中で止めたときは、どの段階で、何が決まらなかったかを書く。
