---
name: issue-workflow
description: nostr-no-su の GitHub issue を、判定 → デザイン → プラン作成 → プランレビューの往復 → 実装と PR 作成 → PR レビューの往復 → 最終確認 → マージまで、Workflow ツールのスクリプト `.claude/workflows/issue-workflow.js` で進める手順。「#64 を進めて」「issue を実装してマージまで」「プランからマージまで回して」「いつもの流れで」「#12 と #13 を並行で」「/issue-pipeline 57 83」のように、issue 番号を挙げて実装や対応を頼まれたときは、プランや実装だけを頼まれたように見えても必ずこのスキルを使う。
---

# issue ごとの分業パイプライン（nostr-no-su）

対象のリポジトリは `neverclear86/nostr-no-su`、PR の base は `main` である。
1 件の issue を、役割ごとに別のエージェントで、次の順に進める。進行はスクリプト `.claude/workflows/issue-workflow.js` が行い、このセッションは進行役ではなく、入力の準備と結果の処理だけを行う。

| 段階 | エージェント（`agentType`） | モデル / effort | 成果物 |
| --- | --- | --- | --- |
| 判定 | `issue-planner` | opus / medium | issue だけ読んで tier（none / light / full）と分割の要否を決める。大きければサブ issue と親コメント「## 分割の設計」 |
| デザイン（UI を変える issue で tier が light 以上） | `issue-designer` | opus / medium | issue コメント（デザインの方針） |
| プラン作成（tier が light 以上） | `issue-planner` | opus / medium。tier light の版 1 は sonnet / high | `<scratchpad>/plans/<N>-v<V>.md` |
| プランレビュー（tier が light 以上） | `issue-plan-reviewer` | opus / medium | `<scratchpad>/plans/<N>-r<R>.md` と判定。APPROVE なら issue コメント「## 実装プラン（版 N）」を投稿。最大 2 ラウンド |
| 実装 | `issue-implementer` | opus / medium。tier light の最初の実装、PR ごとに最初の指摘への対応と条件の取り込み、最初の rebase は sonnet / high | ブランチ、コミット、PR。tier none では PR 本文の「## 設計メモ」がプランの代わり。レビューの指摘への対応と rebase も同じ定義で新しいエージェントを立てる。PR の番号か head を返さなかったときは `issue-pr-lookup`（sonnet / low）が gh で引いて補う |
| PR レビュー | `issue-pr-reviewer` | opus / medium | PR コメント「## レビュー（ラウンド N）」。最大 2 ラウンド。must 0 なら条件付きで APPROVE |
| 最終確認 | `issue-final-gate` | fable / low | PR コメント「## 最終確認」と、APPROVE のとき「## まとめ」。diff とレビューの経緯だけを読み、再現はしない |
| マージ | `issue-merger` | sonnet / high | 承認・CI・衝突と、main とマージした結果の build（使い捨ての作業ツリー）を確かめて `gh pr merge --squash --delete-branch`。1 件ずつ |

ふりかえり（`retrospective`）は 1 件の issue の段階ではなく、この表の全 issue が終わった実行の後に 1 回だけ回す（「### 2. 結果の処理」の「実行の後: ふりかえり」）。`issue-retrospective`（sonnet / high）が学びを分類して改善の issue を 1 本起票し、続けて `issue-retro-implementer`（fable / medium）がその issue の主張を裏取りして実装し、PR を作る。マージはユーザーが判断する。他のリポジトリにも効く学びは `portable` で返り、ユーザーレベルのスキル issue-workflow-kit の学びの表に取り込む。

tier は判定が決める。`none`（追加 100 行未満・3 ファイル以下・決めたこと 0〜1 件）はデザインとプランを飛ばし、`light`（300 行以下）と `full`（300 行超か決めたこと 2 件以上。まず分割する）は同じ流れでプランを書く。

役割ごとの基準、出力の書式、安全策は `.claude/agents/issue-*.md` のエージェント定義に書いてあり、モデルと effort もそこで固定している（Sonnet に振る段階だけは、スクリプトが `agent()` の `model` で上書きする）。
エージェントは CLAUDE.md とスキルの一覧を読み込まずに起動する（定義の `omitClaudeMd: true` と `disallowedTools` の `Skill`。1 体あたり 1 万トークン前後の前提を省く）。エージェントが守るこのリポジトリの方針は定義の ADAPT に写してあるので、CLAUDE.md の方針を変えたら定義の ADAPT も合わせる（`omitClaudeMd` は Claude Code 2.1.271 以降で効く。`.claude/rules/` の `paths` のある規則は、合うファイルを読んだときに届く）。各段階の依頼文はスクリプトの `P` にある。返答は構造化出力（`schema`）で判定や URL だけを返し、プランやレビューの全文はファイルと GitHub のコメントで受け渡す。
`issue-planner`、`issue-plan-reviewer`、`issue-pr-reviewer` は `memory: local` で run をまたぐ記憶を持ち、`.claude/agent-memory-local/<agentType>/MEMORY.md`（git に載らない）に繰り返し見落とす箇所と環境の癖だけを書く。記憶と定義が食い違うときは定義が正であり、定義に書いてあることは記憶に書かない。
書式は [references/formats.md](references/formats.md)。

## 設定

リポジトリごとの値はスクリプトの冒頭の `CONFIG` にある（導入: ユーザーレベルのスキル issue-workflow-kit。導入の記録は `.claude/issue-workflow-kit.json`）。

| 項目 | 値 | 意味 |
| --- | --- | --- |
| repo | `neverclear86/nostr-no-su` | GitHub のリポジトリ |
| baseBranch | `main` | PR の base |
| closeKeyword | `Closes` | PR 本文で issue に触れる語（Refs ならマージ担当が閉じる） |
| helpers | `dev` | 補助スクリプトの置き場 |
| window | 4 | 同時に進める issue の数の既定 |
| マージの方法 | `squash` | `gh pr merge` の方法 |
| modules.split | on | 大きい issue をサブ issue に分ける |
| modules.design | on | UI を変える issue でプランの前にデザインの方針を決める |
| modules.gate | on | PR レビューの後に別のモデルで最終確認をする |
| modules.ci | on | PR の CI を待つ（無ければ手元の検査が代わり） |
| modules.retro | on | 実行の後にふりかえりで学びを集め、改善の PR を作る |
| modules.ports | on | issue ごとにポートと docker のプロジェクト名を割り当てる |
| modules.plan-tests | on | プランのテスト名と実装を機械的に突き合わせる |
| modules.hooks | on | 実装者の hooks（整形、PR 本文の必須の節、push 前の検査） |
| modules.screenshots | on | UI を変える PR に変更前後のスクリーンショットを貼る |

モジュールの有無を変えるときは、`CONFIG.modules` だけでなく定義とこのスキルも合わせる必要があるので、スキル issue-workflow-kit の「更新」で描き直す（手で `CONFIG` だけを変えない）。

## なぜこの形か（このワークフローを育てたリポジトリでの実測）

- **進行をスクリプトに任せる**: 進行役を LLM のセッションにしていた頃は、28 件の費用のうち 22% が進行役だった。進行役の文脈はエージェントの受け渡しのたびに伸び、費用は受け渡し回数の 2 乗で効いた。スクリプトにすると受け渡しは変数で行われて LLM の文脈に入らず、判断が要る箇所（質問、逸脱、収束しない往復）だけがこのセッションに戻る
- **網羅はスクリプトと手順に任せる**: 往復の大半は文書・Doc コメントの追随漏れ、手順の再現性、PR 本文の数値の転記という「網羅」の失敗で、「判断」の失敗ではなかった。網羅は effort を上げるより `dev/` の機械的な検査に任せるほうが確実で安く、定義は「手順（機械的）→ 判断」の順に組んでモデルには判断だけを残す
- **tier と上限 2 と条件付き承認**: 往復した件のうちラウンド 1 の must が 0（should だけ）だったのがプランで 62%、PR で 52% だった。小さい issue はプランの段階に見合う効果が無い。自己修正の改善はラウンド 1〜2 に集中し、レビュアーに説明と修正案を同時に求めると誤判定が増え、150 行を超える diff はレビュー精度が落ちる。そこで小さい issue はプランを飛ばし、往復は 2 ラウンドで打ち切り、must が無い should は条件付き承認にして往復させない
- **書く役と見る役を分ける**: 実装したエージェントの文脈はレビューに持ち込まない。往復のたびに新しいエージェントを立て、ファイルと GitHub のコメントで引き継ぐ
- **書く側の最初の 1 回を Sonnet / high にし、差し戻されたら Opus に上げる**: Sonnet 5.5 の high は、公開ベンチマークで Opus 5.5 の low と medium の間に入り（CursorBench 47.8% と 52.5%、FrontierCode 49.4% と 54.6%）、費用は Opus の medium の 5〜7 割である。Sonnet の medium はコードの作業で大きく落ち（Terminal-Bench で high 43.0% に対して 28.8%）、Sonnet の xhigh と max はほぼ同じ費用の Opus の medium か high を下回るので使わない。そこで、範囲の決まった tier light のプランと実装、指摘への対応、rebase、マージは Sonnet / high で書き、見る側（プランレビュー、PR レビュー）は Opus に残し、差し戻された版と 2 回目以降の対応は Opus に上げる。短い issue だけで書く tier none の実装は FrontierCode 型で Opus が上回るので替えない。最終確認は、実装ともレビューとも別のモデルで見るために Opus と Sonnet のどちらにもしない

## 前提と守ること

- **このセッションの仕事**は、段階 0 の準備、Workflow の起動、結果の処理（質問への回答、止まった issue の報告、再開）である。エージェントの結果を自分で読み直したり、段階を自分で実行したりしない
- **ワークフローの中ではユーザーに質問できない**。プランエージェントが `status: question`、レビュアーが `NEEDS_USER` を返すと、その issue は `blocked` で戻る。ユーザーに聞いてから `decisions` に答えを入れて再開する。事前に決められる論点は、起動の前にまとめて聞く（段階 0）
- **再開は `blocked` / `stalled` / `failed` の issue だけを新しい実行（新しい `base`）で回す**。依頼文は自己完結（`planUrl`、既存 PR の検知）なので、完了済みの段階を走り直す必要が無い。`resumeFromRunId` は、実行が 1 件だけのときか、起動直後の失敗のときに限る（並列の実行を再開すると、完了済みの issue にまで再ディスパッチされる）
- **同時に進める issue は `window` 件**（既定 4）。1 issue につき動くエージェントは常に 1 体なので、同時のエージェント数も `window` になる。マージは 1 件ずつ直列で、衝突は実装エージェントの rebase で解く
- **依存する issue** は `after` に書き、GitHub の Relationships の「blocked by」にもそろえる（段階 0 と分割とプランの承認で記録する）。判定・デザイン・プランは、依存先のプランが承認された時点で、その承認済みプランの URL を依頼文に添えて始まる。実装は依存先のマージを待ち、最後にマージされた依存先のコミットを土台にする。待つ間は `window` の枠を使わない。依存先がプランの前に止まるか、マージされずに終わると `blocked`（stage `deps`）になり、`after` が循環していれば待たずに `blocked` になる。プランが兄弟の部品を前提にして構造化出力の `after` を返したときは、スクリプトが承認の後にその番号を依存先に足し、実装だけがそのマージを待つ
- **CI が通るまでレビューしない**: 実装エージェントは push の前に origin/main に rebase して CI と同じ検査を手元で通し、PR を作ったら `gh pr checks --watch` で CI の全ジョブの pass を待ち、fail は直してから返す（`ciPassed`）。通らないまま返ると `blocked`。PR レビュアーは CI が行う検査を再現せず、CI にも PR 本文にも無い検証だけを再現する
- **大きい issue は分割する**: 判定が tier `full` と決めたら、`gh issue create --parent` でサブ issue を作り（`after` のある子は依存先から順に作って `--blocked-by` を付ける）、親に「## 分割の設計」をコメントして `status: split` を返す。各サブ issue は単独でしきい値（300 行・6 ファイル・決めたこと 2 件）に収まる粒度で切る。兄弟への依存 `after` は論理的な依存のときだけ付け、同じファイルを触るだけなら付けない。スクリプトはサブ issue を同じ実行に足し、`after` の無いものは並列に進める。サブ issue は判定を飛ばし、再分割しない。親は `split`（`subIssues` と `children` の結果つき）で返る。親の issue は最後のサブ issue をマージした `issue-merger` が兄弟の全部の完了を確かめて閉じる
- **往復の上限**（スクリプトが行う）: プランレビューも PR レビューも 2 ラウンドで、APPROVE にならなければ `stalled`。最終確認は 3 回まで。PR レビューがプランの設計に起因する must（`designMust`）を出したら、プランの版を上げて再承認させてから直す。実装がプランどおりに作れないと報告したら（`deviation`）同じ手順で版を上げ、新しいエージェントに続きを実装させる
- **PR レビューの条件付き承認**: must が 0 件なら APPROVE にし、残った should を全部 `conditions` で返す。スクリプトが実装者に直させて push させ（対応コメントのマーカーは `kind=fix`）、**再レビューはせずに**最終確認へ進む。must には直し方の案を書かせない
- **コメントのマーカー**: ワークフローが投稿するコメントは 1 行目を `<!-- nns kind=<…> round=<N> verdict=<…> head=<SHA|-> -->` にする。マーカーは `dev/post_comment.sh` が引数から作るので、エージェントは本文だけを書く。マージ担当は承認の検出をこのマーカーで行う
- **レビューの「承認」は PR コメントで表す**: 全エージェントが同じ GitHub アカウントで動くので、自分の PR に `gh pr review --approve` は使えない
- **ユーザーの作業ツリーに触れない**: 実装もレビューの再現も、スクラッチパッドに `git worktree add` した作業ツリーで行う。docker のプロジェクト名とポートは issue ごとに固有で、スクリプトが `portBase` から割り当てる。スクリプトとエージェントは `repoDir` の `.claude/` を読むので、ユーザーの作業ツリーはこの仕組みを含むブランチにしておく
- **文書の長さ**: プランは 2 万字以内、レビューの「確認したこと」は表だけ。投稿する側は、読み手が最初に見る部分だけを出し、残りを `<details>` に畳む
- **コミットのトレーラー**: サブエージェントはこのセッションの system-reminder を見ないので、`Co-Authored-By` と `Claude-Session` の行と Claude-Session の URL を `trailers` で渡す
- **実装者の定義の hooks**: `issue-implementer` の frontmatter の `hooks`（整形、PR 本文の必須の節、push 前の速い検査）は、その subagent が動いている間だけ発火する。project の subagent の hooks は、ワークスペースの trust を受け入れたフォルダーから起動した対話セッションでだけ動く（動かないときは debug ログに残るだけで、実行は止まらない）
- **対話セッションから起動する**: エージェントが usage limit に当たったとき、対話セッションなら run は一時停止してリセット後に続くが、`claude -p` やバックグラウンドではそのエージェントが失敗する
<!-- ADAPT:rules -->
- **公開のリポジトリ**: `neverclear86/nostr-no-su` は public である
- **文書を動かす issue は先に単独で**: README の分割など、他の PR が触る文書の置き場所を変える issue は、並行させずに 1 件だけの実行でマージしてから次を始める（09-13 の #149 は並行した 4 件と衝突して 4 ラウンドかかった）
- **リリースの PR はマージをユーザーに残す**: リリースの PR（#411 の PR #412 #413 #414、#483 の PR #665）のようにマージとタグ付けをユーザーが行う issue は `issues[].noMerge: true` にする
- **ポートの用途**: `portBase + i*10` からの各 issue の分は、実装が +0 Postgres、+1 アプリ、+2 strfry、レビューが +5〜+7 を同じ順に使う
- **CI と手元の検査**: CI（`.github/workflows/ci.yml`）は build、単体テスト、Postgres の統合テスト、strfry の E2E、カバレッジのバッジ、format、CSS、vendor、プラグイン、.env.example、shipment を検査し、docker イメージは docker に関わるファイルを変えた PR と main への push で検査する。実装エージェントは CI の失敗で push をやり直さないよう、push の前に統合テストまで手元で通す
- **UI を変える issue**: 管理 UI の `.gleam` を変えたら `npm ci && npm run build:css` の結果をコミットする（CI が差分を検査する）。スクリーンショットは変えた画面だけを日本語で貼り、英語は英語画面の修正が主題の issue のときだけ貼る
- **ふりかえりの前のカバレッジ**: `retrospective` を回す前に、実行の間の本体のカバレッジを `sh dev/coverage_delta.sh <最初の実行の base> <今の origin/main>` で確かめる（main の CI の test ジョブのログの計測を README のバッジと並べ、0.2 ポイントを超えて下がったら `drop`、整数に丸めた値がバッジと違えば `badge` を最後の行の `verdict` に出す）。`verdict` が `ok` 以外なら、ユーザーの指示として「カバレッジの判定が <verdict> だった（前後の百分率）。drop なら下がった PR を main の CI の計測（`gh run view --job <test のジョブ> --log` の `coverage:` の行）でたどって原因を学びにし、badge なら `sh dev/check_coverage_badge.sh --update` を受け入れ条件に入れる」を `observations` に足す（学びが 0 件でも起票される）。判定と前後の百分率をユーザーへの報告に載せる
<!-- /ADAPT:rules -->

## 学びの表の候補

ユーザーレベルの学びの表（issue-workflow-kit）にあり、まだ本文に入っていない学びである。条件の付いたものは、当てはまるときだけ守る。

- L055: 依存先を待つ issue は `window` の枠を使わないので、`after` の連鎖があっても `window` を下げない。分割の子が多い実行は 8 まで上げてよい
- L035: 他の文書が参照する文書の置き場所を変える issue は、並行させずに 1 件だけの実行でマージしてから次を始める

## 手順

### 0. 準備

最初に、ワークフローを最新の学びに合わせる。ユーザーレベルのスキル issue-workflow-kit がこのマシンにあるときだけ行い、無ければ（他の人の環境など）飛ばして、コミット済みの定義のまま回す。

```sh
test -f ~/.claude/skills/issue-workflow-kit/scripts/render.py && python3 ~/.claude/skills/issue-workflow-kit/scripts/render.py refresh --repo "$(git rev-parse --show-toplevel)" --trailer "<Co-Authored-By 行>" --trailer "<Claude-Session 行>"
```

- 終了コード 0: 最新だったか、テンプレートと学びの表の変化を取り込んで、kit が管理するファイルだけを専用のコミット（`chore: issue-workflow を issue-workflow-kit <SHA> に更新する`）にした。出力に取り込んだコミットの一覧が出るので、ユーザーへの報告に 1 行で添える。push はしない
- 終了コード 20: 導入の記録が無いか、このマシンの kit の履歴が導入の記録と合わない（kit のファイルだけを写したなど）。更新せずに、コミット済みの定義のまま進める。出力の理由をユーザーへの報告に 1 行で添える
- 終了コード 30: 人の判断が要る（kit が管理するファイルに未コミットの変更がある、kit 自身に未コミットの変更がある（kit をコミットしてから回す）、3-way merge が衝突した、書き換えていない ADAPT がある、テンプレートが ADAPT を外して書いた本文が消える、更新の後の検査が通らない）。作業ツリーは元に戻っている。出力の理由をユーザーに伝え、スキル issue-workflow-kit の「更新」で進めるか、今回は更新せずに回すかを聞く
- それ以外の終了コード（1 など）: refresh そのものが失敗した。`git status --short` で kit が管理するファイル（`.claude/` と `dev/` の描画したもの、`.claude/issue-workflow-kit.json`）に変更が残っていれば `git checkout --` で戻し、コミット済みの定義のまま進める。出力の要点をユーザーに伝える
- 補助スクリプト（`dev/`）の変化は、issue ごとの作業ツリーが base から取り出されるので、この更新が base にマージされてから効く（出力に注意が出る）。定義・スキル・ワークフローの変化は、この直後の起動から効く

続けて、対象の issue（1 件でも複数でも）について、次を集めて `args` を組み立てる。

```sh
R=neverclear86/nostr-no-su
gh issue view <N> -R $R --json title,body,comments,blockedBy   # issue ごとに本文とコメントと blocked by を読む（--comments は本文を落とすことがある）
git rev-parse --show-toplevel                          # repoDir
git fetch origin main
git rev-parse origin/main                   # base
ss -ltn | awk 'NR>1 {print $4}' | sed 's/.*://' | sort -n | uniq   # 使用中のポート
mkdir -p <scratchpad>/plans <scratchpad>/runs
```

- **base**: `origin/main` の先頭。全 issue で同じ
- **repoDir**: ユーザーの作業ツリー（このリポジトリの clone）の絶対パス
- **issues**: issue ごとに `n`、`branch`（`feat/…`、`fix/…`、`docs/…`、`refactor/…` の形で英語）、UI を変えるなら `ui: true`、依存があれば `after: [n]`、issue コメントで決まった事項や補足があれば `note`
- **依存と blocked by**: `blockedBy.nodes` のうち `state` が `OPEN` の issue は依存である（`url` が別のリポジトリのものは `after` に書けないので、ユーザーに伝えるだけにする）。この実行の `issues` にあれば `after` に入れる。実行に無ければ、その issue も含めるか、依存を外して進めるか（すでに変更が土台にある、など）を「事前に聞く論点」に入れる（聞かずに起動すると `blocked`（stage `deps`）で返る）。逆に、`after` に書いたのに `blockedBy` に無い組は、起動の前に `gh issue edit <n> -R neverclear86/nostr-no-su --add-blocked-by <m>`（複数はカンマ区切り）で足す。他のコマンドと連結せず、1 回の Bash 呼び出しに 1 つだけ置く
- **portBase**: issue ごとに 10 個ずつ使う空きポートの先頭。`portBase + i*10` から `+9` までが issue i の分（実装が +0〜+4、レビューが +5〜+9。用途は issue-implementer の定義の「環境」）。ユーザーが使っているポート（`.claude/issue-workflow.local.env` の `USER_PORTS` と、上の `ss` で見た使用中のポート）と重ならない範囲を選ぶ
- **trailers**: このセッションの system-reminder にある `Co-Authored-By` 行、`Claude-Session` 行、Claude-Session の URL
- **window**: 同時に進める件数。既定 4
- **sonnet**: `false` にすると、Sonnet に振る段階（tier light のプランの版 1 と最初の実装、PR ごとに最初の指摘への対応、最初の rebase、PR の検索、マージ）も定義のモデル（opus）で立てる。ふりかえりの起票は別のワークフローなので、このスイッチでは変わらない。モデルを比べるときと切り戻すときに使う。既定は省略（Sonnet に振る）
- **tier の固定**: 判定をやり直したくない再開のときは `issues[].tier` に `none` / `light` / `full` を書く。判定の段階が飛ぶ
- **マージをユーザーに残す issue**: `issues[].noMerge: true` にする。最終確認の APPROVE の後にマージの段階が飛び、`stalled`（reason が `noMerge:`）で返る。これは失敗ではないので、ユーザーに PR のマージを頼む
- **既存のプラン**: issue に承認済みの「## 実装プラン（版 N）」があれば、そのコメントの URL を `planUrl` に書く。判定とプランを飛ばして実装から始める
- **stalled のプランの続き**: 前の実行でプランレビューの上限で `stalled` になった issue は、最後の版（`<前の scratchpad>/plans/<N>-v<V>.md`）を `prevPlan` に、そのレビュー（`<N>-r2.md`）を `prevReview` に書く（両方。`plans/` の外に写してから渡す）。判定と版 1 を飛ばし、版 V+1 から往復を始める
- **事前に聞く論点**: issue の本文とコメントに未決の設計判断があれば、起動の前に `AskUserQuestion` でまとめて聞き、`decisions[n]` に書く
- **`args` を保存する**: 組み立てた `args` を `<scratchpad>/runs/<base の短い SHA>-<連番>.json` に書いてから起動する。再開はそのファイルを読み、`blocked` / `stalled` / `failed` の issue だけを新しい実行の `args` の元にする

### 1. 起動

`Workflow` ツールを `scriptPath: ".claude/workflows/issue-workflow.js"` と `args` で呼ぶ（段階 0 の更新でスクリプトが変わっていても、`scriptPath` なら起動のたびにファイルを読む。`name: "issue-pipeline"` で呼ぶと、更新の後は `/reload-skills` が要る）。ユーザーが `/issue-pipeline` と打ったときも、先に段階 0 を行ってから起動する。`args` は JSON のオブジェクトで渡す（文字列にしない）。

```json
{
  "issues": [
    { "n": 57, "branch": "<57 のブランチ>", "note": "issue のコメントで決まった補足" },
    { "n": 83, "branch": "<83 のブランチ>", "after": [57] }
  ],
  "base": "ad787b6…",
  "scratchpad": "<このセッションのスクラッチパッド>",
  "repoDir": "/path/to/nostr-no-su",
  "portBase": 5600,
  "window": 4,
  "trailers": {
    "coAuthoredBy": "Co-Authored-By: Claude … <noreply@anthropic.com>",
    "claudeSession": "Claude-Session: https://claude.ai/code/session_…",
    "sessionUrl": "https://claude.ai/code/session_…"
  },
  "decisions": { "57": "<事前に聞いたユーザーの決定>" }
}
```

起動は背景で走り、完了の通知で `results` が届く。途中経過は `/workflows`。結果を待つ間に `ListAgents` を繰り返したり催促したりしない。

### 2. 結果の処理

`results` の各要素は `status` で分ける。

- `split`: 親が分割された。`subIssues` と `children` の各結果を、それぞれ下の分類で扱う。`children` が全部 `merged` なら親の issue は閉じているはずなので、開いたままなら閉じる
- どの状態でも、`relationProblems` があれば（プランが前提にした兄弟の blocked by を足せなかった）、`gh issue edit <n> -R neverclear86/nostr-no-su --add-blocked-by <m>` で足すか、ユーザーに伝える
- `merged`: PR 番号、マージのコミット、tier、プランのラウンド数、PR レビューのラウンド数、条件の件数（`prConditionCount`）、最終確認の回数、残した nit の数、学び（`lessons`）を報告に載せる。`issueClosed` が false なら issue を手で閉じる
- `blocked`: `stage` と `questions` がある。`questions` をユーザーに聞き、答えを `decisions[n]` に入れ、その issue だけを新しい実行の `issues` に入れて再開する（`planUrl` と `tier` を引き継ぐ）。依存先の失敗（`stage: deps`）は依存先を先に直す
- `stalled`: 往復が収束しなかった issue。`reason` を添えてユーザーに報告し、指示を待つ。プランレビューの上限で止まったもの（stage `plan`）は、段階 0 の「stalled のプランの続き」で回し直す。`reason` が `noMerge:` で始まるものは失敗ではなく、ユーザーに PR のマージを頼む
- `failed`: エージェントが結果を返さなかった（打ち切り、API のエラー、auto モードの分類器による停止）。`stage` を報告し、その issue だけを新しい実行の `issues` に入れて再開する。走り直したエージェントが済んだ副作用に出会う場合（PR がある、ブランチがある、マージ済み）は、実装エージェントと merger の定義がそれを検知して続きから進める

再開する新しい実行の `args` は、`blocked` / `stalled` / `failed` の issue だけを `issues` に入れ、`base` を今の `origin/main` に更新して組み立てる。`after` に書けるのは同じ実行の `issues` にある番号だけで、依存先がすでにマージ済みなら `after` から外す。分割の子を回し直すときは、その子を `issues` に直接書き、`branch` は前の実行の `<親の branch>-<子の番号>`、`depth: 1`、`parent: <親の番号>`、`tier` は親の「## 分割の設計」の表の値、`ui` は親と同じ値、`note` は `#<親の番号> を分割したサブ issue。親の issue のコメント「## 分割の設計」に全体の方針と兄弟との分担がある`、親が `ui: true` なら `designUrl` に親の「## デザインの方針」の URL にする（`depth` が無い子は判定から入って再分割されうる）。
終わったら作業ツリーを片付ける。`merged` の issue の作業ツリーはマージ担当が消している。それ以外の結果の issue は、`<scratchpad>/wt-<n>-plan` と `<scratchpad>/wt-<n>-review`（merger が途中で止まったときは `<scratchpad>/wt-<n>-merge` も） を `git -C <repoDir> worktree remove --force <パス>` で消す（どちらもブランチを持たず、再開した実行が無ければ作り直す）。`<scratchpad>/wt-<n>` はブランチと push 前のコミットを持ちうるので残す。テストが権限を外したディレクトリを残して `worktree remove` が失敗したら、`chmod -R u+rwX <パス> && rm -rf <パス>` で消す。最後に `git -C <repoDir> worktree prune` で、実体の無くなった作業ツリーの登録を外す（`prune` だけではディスク上のファイルは消えない）。

#### 実行の後: ふりかえり

この実行に含めた issue が全部終わったら（`blocked` や `stalled` が残っていてもよい）、`retrospective` を 1 回回す。起票から PR までが 1 回の実行で進む。

1. このセッションの journal のパスを `ls -tr <セッションの subagents/workflows>/wf_*/journal.jsonl` で mtime の昇順に集める。mtime が `since` より前のものと、`result` イベントが 1 件も無いものは `runs` に入れない
2. journal ごとに次の jq を通し、`events` を組み立てる。
   ```sh
   jq -s '(map(select(.type=="started"))|INDEX(.key)) as $s | map(select(.type=="result") | {label:$s[.key].label, phase:$s[.key].phase} + (.result|{status,tier,pr,verdict,must,should,nit,designMust,lessons,sha,closedParents,conditions:(.conditions|length)}|with_entries(select(.value!=null))))' <journal>
   ```
3. `Workflow` ツールを `scriptPath: ".claude/workflows/retrospective.js"`（`name: "retrospective"`）と `args` で呼ぶ。実行の外で観察した学び（ユーザーの指示、`log` に出た事象）は `observations` に自由形式の文で渡す。

```json
{
  "runs": ["/tmp/.../wf_a22397c8-55c/journal.jsonl"],
  "events": { "/tmp/.../wf_a22397c8-55c/journal.jsonl": [ { "label": "Triage #157", "phase": "判定", "status": "plan", "tier": "light" } ] },
  "since": "2026-09-13T00:00:00Z",
  "observations": ["ユーザーが「PR 本文は短く」と指示した"],
  "base": "2f0a2eb…",
  "scratchpad": "<このセッションのスクラッチパッド>",
  "repoDir": "/path/to/nostr-no-su",
  "trailers": { "coAuthoredBy": "…", "claudeSession": "…", "sessionUrl": "…" }
}
```

学びも `observations` も 0 件なら issue は起票されない。起票されると、同じ実行の中で `issue-retro-implementer`（fable）がその issue を精査して実装し、結果が `implementation` に返る。

- `implementation.status: pr`: PR ができた。`pr` と `prUrl`（stacked PR に分けたときは `prs` の全部）をユーザーに渡す。マージはユーザーが判断する
- `rejected`: 精査で原因の説明が成り立たない、または直す価値が無いと分かり、issue を閉じた。`reason` を報告する
- `blocked`: 直し方が定義の方針に関わる。`questions` をユーザーに聞き、答えを `retroIssue: { "number": <N>, "url": "<issue の URL>", "decisions": ["<答え>"] }` に入れて `retrospective` をもう一度回す（`runs` と `events` は要らない）

`pr` と `rejected` のときは、実装に使った `<scratchpad>/wt-retro-<N>` で始まる作業ツリーを「### 2. 結果の処理」の末尾と同じ手順で消す（ブランチは残るので、PR を直すときは `git worktree add` で取り出し直す）。`blocked` のときは再開で使うので残す。

起票された issue を issue-workflow の `issues` に入れて回さない（同じ issue を 2 回実装するうえ、精査と実装が fable でなくなる）。

結果の `portable`（他のリポジトリにも効く汎用の学び）が空でなければ、ユーザーレベルのスキル issue-workflow-kit の「学びの取り込み」で `~/.claude/skills/issue-workflow-kit/references/lessons.md` に足す（`portable` の配列とこのリポジトリの名前を渡す）。

### 3. ユーザーへの報告

1 件ごとに、issue 番号、tier、プランのラウンド数、PR 番号、PR レビューのラウンド数と条件の件数、最終確認の結果、マージのコミット、残した nit と後続の issue にした事項を短くまとめる。
止まった issue は、どの段階で、何が決まらなかったかを書く。
最後に `retrospective` を回し、起票された issue の番号とその根拠の表、精査と実装の結果、取り込んだ汎用の学びをユーザーに渡す。

## dry run（スクリプトを変えたとき）

`args.dryRun` に issue 番号ごとのシナリオを渡すと、エージェントを立てずに制御の流れだけを確かめられる。シナリオの一覧はスクリプトの `fake` にある。全シナリオは次の 1 行で回せる（期待する結果との突き合わせまで行い、NG が 0 件なら終了コード 0）。

```sh
python3 dev/verify_workflow.py .claude/workflows/issue-workflow.js
```

`Workflow` ツールで個別に回すときは、次の形の `args` の `dryRun` のシナリオ名を差し替える（`dryRunPrompts: true` を足すと、`trace` に依頼文の全文が入る）。

```json
{ "issues": [{ "n": 1, "branch": "x" }, { "n": 2, "branch": "y", "after": [1] }], "base": "0000000", "scratchpad": "/tmp/dry", "repoDir": "/tmp/dry/repo", "portBase": 5600, "trailers": { "coAuthoredBy": "a", "claudeSession": "b", "sessionUrl": "c" }, "dryRun": { "1": "plan2", "2": "conflict" } }
```

`retrospective` は `args.dryRun: true` を渡すとエージェントを立てずに集計だけ返す。
