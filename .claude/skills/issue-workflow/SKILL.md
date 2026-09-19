---
name: issue-workflow
description: nostr-no-su の GitHub issue を、分割の判定（opus low）→ プラン作成（opus low）→ プランレビュー（opus medium）の往復 → 実装と PR 作成（sonnet high）→ PR レビュー（opus medium）の往復 → 最終確認（fable low）→ squash マージ（opus low）まで、Workflow ツールのスクリプト `.claude/workflows/issue-workflow.js` で進める手順。「#64 を進めて」「issue を実装してマージまで」「プランからマージまで回して」「いつもの流れで」「must-fix を順に片付けて」「/issue-pipeline 57 83」のように、issue 番号を挙げて実装や対応を頼まれたときは、プランや実装だけを頼まれたように見えても必ずこのスキルを使う。
---

# issue ごとの分業パイプライン（nostr-no-su）

対象のリポジトリは `neverclear86/nostr-no-su`（private）である。
1 件の issue を、役割ごとに別のエージェントで、次の順に進める。進行はスクリプト `.claude/workflows/issue-workflow.js` が行い、このセッションは進行役ではなく、入力の準備と結果の処理だけを行う。

| 段階 | エージェント（`agentType`） | モデル / effort | 成果物 |
| --- | --- | --- | --- |
| 判定 | `issue-planner` | opus / low | issue だけ読んで tier（none / light / full）と分割の要否を決める。大きければサブ issue と親コメント「## 分割の設計」 |
| デザイン（UI を変える issue で tier が light 以上） | `issue-designer` | opus / medium | issue コメント（デザインの方針）。分割した親でも 1 回だけで、サブ issue は親の URL を継ぐ |
| プラン作成（tier が light 以上） | `issue-planner` | opus / low | `<scratchpad>/plans/{{N}}-v{{V}}.md` |
| プランレビュー（tier が light 以上） | `issue-plan-reviewer` | opus / medium | `<scratchpad>/plans/{{N}}-r{{R}}.md` と判定。APPROVE なら issue コメント「## 実装プラン（版 N）」を投稿。最大 2 ラウンド |
| 実装 | `issue-implementer` | sonnet / high | ブランチ、コミット、PR。tier none では PR 本文の「## 設計メモ」がプランの代わり。レビューの指摘への対応と rebase も同じ定義で新しいエージェントを立てる |
| PR レビュー | `issue-pr-reviewer` | opus / medium | PR コメント「## レビュー（ラウンド N）」。最大 2 ラウンド。must 0 なら条件付きで APPROVE |
| 最終確認 | `issue-final-gate` | fable / low | PR コメント「## 最終確認」と、APPROVE のとき「## まとめ」。diff とレビューの経緯だけを読み、再現はしない |
| マージ | `issue-merger` | opus / low | 承認・CI・衝突を確かめて `gh pr merge --squash --delete-branch`。1 件ずつ |

ふりかえり（`retrospective`、opus / medium）は 1 件の issue の段階ではなく、この表の全 issue が終わった実行の後に 1 回だけ回す（「### 2. 結果の処理」の「実行の後: ふりかえり」）。

tier は判定が決める。`none`（追加 100 行未満・3 ファイル以下・決めたこと 0〜1 件）はデザインとプランを飛ばし、`light`（300 行以下）と `full`（300 行超か決めたこと 2 件以上。まず分割する）は同じ流れでプランを書く。

役割ごとの基準、出力の書式、安全策は `.claude/agents/issue-*.md` のエージェント定義に書いてあり、モデルと effort もそこで固定している。各段階の依頼文はスクリプトの `P` にある。返答は構造化出力（`schema`）で判定や URL だけを返し、プランやレビューの全文はファイルと GitHub のコメントで受け渡す。
書式は [references/formats.md](references/formats.md)。

## なぜスクリプトで進めるか（2026-09-13 の実測）

進行役を opus low のセッションにしていた 09-13 のセッションでは、28 件で $718、うち 22%（$159）が進行役だった。進行役の文脈はエージェントの受け渡し（252 回）のたびに 3.9k ずつ伸びて 95 万トークンに達し、費用は受け渡し回数の 2 乗で効いていた。モデルを混ぜたことによるキャッシュの損は $5 で、無視できる。
スクリプトにすると、受け渡しは変数で行われて LLM の文脈に入らず、待機中のエージェントのキャッシュ失効（$39）も無くなる。判断が要る箇所（質問、逸脱、収束しない往復）だけがこのセッションに戻る。

## なぜ網羅をスクリプトと手順に任せるか（2026-09-13 の実測）

09-13 のプランレビュー 28 件と PR レビュー 21 件の指摘を分類すると、往復の大半は文書・Doc コメントの追随漏れ、手順の再現性、PR 本文の数値の転記という「網羅」の失敗で、「判断」の失敗ではなかった。
プランレビューのラウンド 1 で APPROVE は 3 / 28 で、must 0・should 1 だけで往復した件が 9 件あった。PR レビューのラウンド 1 の指摘 25 件のうちコードの動作の誤りは 1 件で、ラウンド 3 以上になった 6 件はすべてコード以外が原因だった。
網羅は effort を上げるより `dev/sweep_refs.sh`、`dev/pr_facts.sh`、`dev/check_procedure.sh` に任せるほうが確実で安く、置換文で直る should は条件付き承認で往復せずに済ませる。定義は「手順（機械的）→ 判断」の順に組み、モデルには判断だけを残す。

## なぜ tier と上限 2 と条件付き承認にしたか（2026-09-19）

6 run（マージ 52 件、$999）の実測では、往復した件のうちラウンド 1 の must が 0（should だけ）だったのがプランで 62%、PR で 52% だった。deviation は 0 件、設計に起因する must は 3 / 55 件である。追加 100 行未満の PR はラウンド 1 が REQUEST CHANGES になるのが 34%、最終確認の差し戻しが 1 / 29 なのに対し、300 行超ではそれぞれ 75%、5 / 36 だった。
つまり、小さい issue はプランの段階に見合う効果が無く、往復の大半は must の無い should で起きている。文献も同じ向きである。自己修正の改善はラウンド 1〜2 に集中する（arXiv 2604.10508）。レビュアーに説明と修正案を同時に求めると誤判定が増える（arXiv 2603.00539）。150 行を超える diff はレビュー精度が落ちる（arXiv 2606.15689）。
そこで、小さい issue はプランを飛ばし（tier `none`）、往復はプランも PR も 2 ラウンドで打ち切り、must が無い should は PR レビューでも条件付き承認にして往復させないことにした。

## 前提と守ること

- **このセッションの仕事**は、段階 0 の準備、Workflow の起動、結果の処理（質問への回答、止まった issue の報告、再開）である。エージェントの結果を自分で読み直したり、段階を自分で実行したりしない。モデルは何でもよい（受け渡しをしないので文脈は小さいまま）
- **ワークフローの中ではユーザーに質問できない**。プランエージェントが `status: question`、レビュアーが `NEEDS_USER` を返すと、その issue は `blocked` で戻る。ユーザーに聞いてから `decisions` に答えを入れて再開する。事前に決められる論点は、起動の前にまとめて聞く（段階 0）
- **再開は `Workflow` に `scriptPath` と `resumeFromRunId` を渡して行う**（起動の結果に出る Run ID）。完了したエージェントの結果は、起動順の接頭辞で依頼文が変わっていない範囲まで再利用される（公式文書: 「最初に依頼文が変わったエージェントと、それ以降は走り直す」）。`base` と `portBase` と `trailers` は再開でも同じ値を渡す（変えると依頼文が変わり、全部やり直しになる）。同じ Claude Code のセッションの中でしか再開できない（Agent SDK リファレンスの `resumeFromRunId` の項の「Same session only」）
- **同時に進める issue は `window` 件**（既定 4）。1 issue につき動くエージェントは常に 1 体なので、同時のエージェント数も `window` になる。マージは 1 件ずつ直列で、衝突は実装エージェントの rebase で解く
- **依存する issue** は `after` に書く。依存先がマージされてから、そのマージのコミットを土台にして始まる。依存先が失敗すると `blocked` になり、`after` が循環していれば待たずに `blocked` になる
- **CI が通るまでレビューしない**：実装エージェントは push の前に origin/main に rebase して CI と同じ検査を手元で通し（push のやり直しは CI の実行を増やす。#305）、PR を作ったら（指摘への対応や rebase の push でも）`gh pr checks --watch` で CI の `test` ジョブの pass を待ち、fail は直してから返す（`ciPassed`）。通らないまま返ると `blocked`。PR の CI は軽い検査（build、単体テスト、format、CSS、vendor、プラグイン、.env.example）だけで、Postgres の統合テストと E2E は実装エージェントが手元で通して PR 本文に貼る。PR レビュアーはどちらも再現せず、CI にも PR 本文にも無い検証だけを再現する。docker イメージと strfry の E2E は手動のワークフロー（`manual.yml`）で、リリースの前にオーナーが起動する
- **大きい issue は分割する**：プランの前に「判定」の段階（`issue-planner` に判定だけを依頼）が issue だけ読んで見込みを出し、tier が `full`（変更の見込みが 300 行を超えるか、独立に出せる「決めたこと」が 2 つ以上）のとき、`gh issue create --parent` でサブ issue を作り、親に「## 分割の設計」をコメントして `status: split` を返す。各サブ issue は単独でしきい値（300 行・6 ファイル・決めたこと 2 件）に収まる粒度で切り、兄弟への依存 `after` は論理的な順序と同じファイルを触る場合だけ付ける。スクリプトはサブ issue を同じ実行に足し、`after` の無いものは並列に進める（親のデザインは 1 回だけで、サブ issue は URL を継ぐ）。サブ issue は判定を飛ばし、再分割しない（プランが再分割を求めたら `blocked` で戻る）。親は `split`（`subIssues` と `children` の結果つき）で返る。親の issue は PR の `Closes` では閉じないので、最後のサブ issue をマージした `issue-merger` が兄弟の全部の完了を確かめて閉じる（親の親にも遡る）。しきい値より小さい issue は分けない（固定費が増える）。09-13 夜の実行では、分割の 2 番目の子が再分割される連鎖（#126 → #185 → #202 → #214 → #221）で同時 10 件の枠が直列に潰れ、最後の 3 件に 4.5 時間かかった
- **tier**（判定が決め、スクリプトが流れを分ける）：`none` はデザインもプランも書かず、実装者が issue を直接読んで実装し、PR 本文に「## 設計メモ」（決めたこと／受け入れ条件 → 満たす変更 → 検証の手順の表）を書く。PR レビューはプランの代わりにこの節と issue に照合する。`light` と `full` の流れは同じで、違うのは判定の意味（`full` はまず分割を試み、分割できない理由があるときだけそのまま進む）だけである。分割で生まれたサブ issue は判定を飛ばして `light` 固定。A/B や再開で tier を固定したいときは `issues[].tier` に書くと判定を飛ばす
- **往復の上限**（スクリプトが行う）：プランレビューも PR レビューも 2 ラウンドで、APPROVE にならなければ `stalled`。最終確認は 3 回のままである。effort の昇格は行わない（モデルと effort は定義で固定）。PR レビューがプランの設計に起因する must（`designMust`）を出したら、プランの版を上げて再承認させてから直す。`tier none` でこれが出たら、その PR レビューのコメントを根拠にその場でプランを作らせる（2 回目の `designMust` は `stalled`）。実装がプランどおりに作れないと報告したら（`deviation`）同じ手順で版を上げ、新しいエージェントに続きを実装させる（`tier none` には上げるプランが無いので、その場でプラン v1 を書かせ、途中の作業ツリーから続きを実装させる。tier の記録は判定が付けた `none` のまま残す）
- **PR レビューの条件付き承認**：PR レビューは must が 0 件なら APPROVE にし、残った should を全部 `conditions`（置換文か 1 行の直し方）で返す。条件が 1 件以上あれば、スクリプトが実装者に直させて push させ（対応コメントのマーカーは `kind=fix`）、**再レビューはせずに**最終確認へ進む。最終確認は、レビュー APPROVE の head から対応後の head までの差分が条件の範囲に収まっているかも見る。PR レビューの must には直し方の案を書かせない（説明と修正案を同時に求めると誤判定が増えるため）。must は再現か差分の読解で確かめたものだけで、推測は should に落とす
- **コメントのマーカー**：ワークフローが投稿するコメントは 1 行目を `<!-- nns kind=<plan|plan-review|pr-review|fix|gate|summary|design|split> round=<N> verdict=<APPROVE|REQUEST CHANGES|NEEDS_USER|-> head=<SHA|-> -->` にし、見出しは 2 行目以降に置く。マージ担当は承認の検出をこのマーカーで行う（見出しの完全一致は使わない）。長い本文（プランの全文、指摘、確認したこと）は `<details>` に畳む
- **まとめ**：最終確認が APPROVE を出すと、同じエージェントが続けて「## まとめ」を 1 本投稿する（tier、プランと PR レビューのラウンド数、条件の件数、実装起因の must の件数、学び 0〜3 件）。学びは `lessons` で返り、`results` と最後の `log` に集計が出る。次の改修の材料なので、実行の後に `retrospective` が拾う
- **往復は新しいエージェント**で行う。プランの往復も、PR レビューの往復も、修正も、前のファイルや PR コメントの URL を渡して新しいエージェントを立てる（同じエージェントに戻す `SendMessage` は使わない。待機中にキャッシュが切れて文脈全体を書き直すため）。引き継ぎは、プランの「指摘への対応」の表、レビューの「前ラウンドの指摘の照合」の表、PR の対応コメントで行う
- **レビューの「承認」は PR コメントで表す**：全エージェントが同じ GitHub アカウントで動くので、自分の PR に `gh pr review --approve` は使えない。PR レビューは `判定: APPROVE`（must が 0 件）を承認とみなす。should は条件として残り、nit は残っていてもよい
- **プランの条件付き承認**：プランレビューは must 0 で、should のすべてが置換文か 1 行の追記で直るもの（文書と Doc の文言、テスト名、手順の書き足し）なら APPROVE にし、それらを投稿する版の「### 実装時の条件」に列挙して `conditions` で返す。スクリプトは実装の依頼文に「実装時の条件」として渡し（`planUrl` で始めた issue は投稿済みのプランの冒頭を読ませる）、実装者が取り込んで PR 本文の「プランからの変更」に書き、PR レビュアーが「確認したこと」の表で照合する。設計・正しさ・テストの検証力に関わる should は今までどおり REQUEST CHANGES
- **ユーザーの作業ツリーに触れない**：実装もレビューの再現も、スクラッチパッドに `git worktree add` した作業ツリーで行う。docker のプロジェクト名とポートは issue ごとに固有で、スクリプトが `portBase` から割り当てる
- **文書の長さ**：プランは 2 万字以内でコードは 1 割まで、レビューの「確認したこと」は表だけ、最終確認は指摘と「読んだもの」だけ（定義の「文書の長さ」の節）。投稿する側は、読み手が最初に見る部分（プランなら「決めたこと」と受け入れ条件の表で 3,000 字以内、レビューなら判定と件数の行）だけを出し、残りを `<details>` に畳む
- **文体**：issue、PR、コミット、コード内コメントは標準的な技術文体の日本語で書く（ギャル口調は使わない）。issue と PR の文章はスキル `japanese-tech-writing` の規範に従う（サブエージェントには読み込まれないので、エージェント定義の「である調、一文一行、根拠の無い形容を避ける」が契約）
- **実装とレビューの基準**：DRY、シンプルさ、命名、仕様（issue とプラン）への準拠を厳しめに見る。関数型の書き方を重視し、全関数に簡潔な Doc コメントを書く。コメントは日本語（ログ文字列と識別子は英語のまま）
- **互換性は持たない**：v0.1 未満で非公開なので、消した設定や API は「最初から無かったもの」として扱い、廃止ログ、移行案内、互換レイヤーは作らない。バンカー無効での起動は想定しない
- **UI を変える issue** は `ui: true` を付ける。スクリプトがデザインエージェントを先に立て、プランに取り込ませ、実装エージェントに変更前（main）と変更後のスクリーンショットを PR に貼らせる（変えた画面だけを日本語で。英語は英語画面の修正が主題の issue のときだけ。見た目が変わらないリファクタリングでも貼る）。`ui` を付けない issue ではスクリーンショットは撮らない。管理 UI の `.gleam` を変えたら `npm run build:css` の結果をコミットする（CI が差分を検査する）
- **文書を動かす issue は先に単独で**：README の分割など、他の PR が触る文書の置き場所を変える issue は、並行させずに 1 件だけの実行でマージしてから次を始める（09-13 の #149 は並行した 4 件と衝突して 4 ラウンドかかった）
- **コミットのトレーラー**：サブエージェントはこのセッションの system-reminder を見ないので、`Co-Authored-By` と `Claude-Session` の行と Claude-Session の URL を `trailers` で渡す
- **キャッシュ**：ワークフローのエージェントのキャッシュは既定 5 分で切れる。1 issue の段階は続けて動くので通常は足りるが、待ちが長くなるなら設定 `subagentPromptCacheTtl` を `1h` にする（書き込みの単価が上がる）

## 手順

### 0. 準備

対象の issue（1 件でも複数でも）について、次を集めて `args` を組み立てる。

```sh
R=neverclear86/nostr-no-su
gh issue view {{N}} -R $R --comments          # issue ごとに本文とコメントを読む
git -C /home/lina/workspace/projects/nostr-no-su fetch origin main
git -C /home/lina/workspace/projects/nostr-no-su rev-parse origin/main   # base
ss -ltn | awk 'NR>1 {print $4}' | sed 's/.*://' | sort -n | uniq        # 使用中のポート
mkdir -p <scratchpad>/plans <scratchpad>/runs
```

- **base**：`origin/main` の先頭。全 issue で同じ
- **issues**：issue ごとに `n`、`branch`（`feat/…`、`fix/…`、`docs/…`、`refactor/…` の形で英語）、UI を変えるなら `ui: true`、依存があれば `after: [n]`、issue コメントで決まった事項や補足があれば `note`
- **portBase**：issue ごとに 10 個ずつ使う空きポートの先頭。`portBase + i*10` から `+9` までが issue i の分（実装用 Postgres は `+0`、アプリ `+1`、strfry `+2`、レビュー用は `+5`〜`+7`）。ユーザーの 8080 と 5432、他セッションの 5433 と 7777 と重ならない範囲を選ぶ
- **trailers**：このセッションの system-reminder にある `Co-Authored-By` 行、`Claude-Session` 行、Claude-Session の URL
- **window**：同時に進める件数。既定 4。文書を動かす issue や大きい issue は 1。5 時間枠の残量を見て決める。残りが 30% 未満なら `window` を 2 にし、新しい issue を足さない（枠切れで止まったエージェントの再開は、途中の副作用を確かめる分だけ高くつく）
- **tier の固定**：A/B を取るときや、判定をやり直したくない再開のときは `issues[].tier` に `none` / `light` / `full` を書く。判定の段階が飛ぶ
- **既存のプラン**：issue にすでに承認済みの「## 実装プラン（版 N）」が投稿されていれば、そのコメントの URL を `planUrl` に書く。スクリプトはプランの段階を飛ばして実装から始める。土台が古びていて作れない箇所があれば、実装エージェントが `deviation` を返し、スクリプトがプランの版を上げる
- **事前に聞く論点**：issue の本文とコメントに未決の設計判断（どの鍵で応答するか、既定値をどうするか、など）があれば、起動の前に `AskUserQuestion` でまとめて聞き、`decisions[n]` に書く。09-13 の実績では 28 件で 9 件の質問があり、すべてプラン段階の設計判断だった
- **`args` を保存する**：組み立てた `args` を `<scratchpad>/runs/<base の短い SHA>-<連番>.json` に書いてから起動する。再開はそのファイルを読んで同じ `args` を渡し、`decisions` だけを足す（`base`、`portBase`、`trailers` を組み直すと依頼文が変わって全部やり直しになる）

### 1. 起動

`Workflow` ツールを `name: "issue-pipeline"`（スクリプトの `meta.name`。スキルと別の名前にしてある）か `scriptPath: ".claude/workflows/issue-workflow.js"` と、`args` で呼ぶ。ユーザーが `/issue-pipeline` と打ったときも、先に段階 0 を行ってから起動する（issue 番号だけではスクリプトが動かない）。`args` は JSON のオブジェクトで渡す（文字列にしない）。

```json
{
  "issues": [
    { "n": 57, "branch": "feat/watch-all-accounts", "note": "since は最後に受け取った created_at から" },
    { "n": 83, "branch": "fix/half-open-websocket", "after": [57] },
    { "n": 86, "branch": "feat/log-level-and-timestamp", "planUrl": "https://github.com/neverclear86/nostr-no-su/issues/86#issuecomment-…" },
    { "n": 58, "branch": "feat/theme-toggle", "ui": true }
  ],
  "base": "ad787b6…",
  "scratchpad": "/tmp/claude-1000/…/scratchpad",
  "portBase": 5600,
  "window": 4,
  "trailers": {
    "coAuthoredBy": "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>",
    "claudeSession": "Claude-Session: https://claude.ai/code/session_…",
    "sessionUrl": "https://claude.ai/code/session_…"
  },
  "decisions": { "57": "起動直後の購読は DB に保存した最後の受信時刻から" }
}
```

起動は背景で走り、完了の通知で `results` が届く。途中経過は `/workflows`。結果を待つ間に `ListAgents` を繰り返したり催促したりしない。

### 2. 結果の処理

`results` の各要素は `status` で分ける。

- `split`：親が分割された。`subIssues`（番号の配列）と `children` の各結果を、それぞれ上の分類で扱う。`children` が全部 `merged` なら親の issue は閉じているはずなので、開いたままなら閉じる
- `merged`：PR 番号、マージのコミット、tier、プランのラウンド数、PR レビューのラウンド数、条件の件数（`prConditionCount`）、最終確認の回数、残した nit の数、最終確認の学び（`lessons`）を報告に載せる
- `blocked`：`stage` と `questions` がある。`questions` をユーザーに聞き、答えを `decisions[n]` に入れて、同じ `args` に `resumeFromRunId` を付けて再開する。依存先の失敗（`stage: deps`）は依存先を先に直す
- `stalled`：往復が収束しなかった issue。`reason` を添えてユーザーに報告し、指示を待つ（プランの論点が割れたなら `decisions` で決めて再開、実装が難しいなら issue を分ける）
- `failed`：エージェントが結果を返さなかった（打ち切り、API のエラー、auto モードの分類器による停止）。`stage` を報告し、同じ `args` で再開する。走り直したエージェントが済んだ副作用に出会う場合（PR がある、ブランチがある、マージ済み）は、実装エージェントと merger の定義がそれを検知して続きから進める（失敗したエージェントとその後が走る。issue を並行させていると起動順が揺れるので、それより前に完了した他の issue の段階も走り直すことがある。最初の実運用で `journal.jsonl` の再利用の実績を確かめて、ここに書き足す）

再開のときは `args` を変えない（`decisions` の追加だけ）。`base` を今の `origin/main` に更新すると全 issue の依頼文が変わり、完了した結果が再利用されない。main が進んで土台が古びた issue は、次の実行で新しい `base` から始める。

#### 実行の後: ふりかえり

この実行に含めた issue が全部終わったら（`blocked` や `stalled` が残っていてもよい）、`retrospective` を 1 回回す。

1. このセッションの journal のパスを `ls -tr <セッションの subagents/workflows>/wf_*/journal.jsonl` で mtime の昇順に集める（`aggregate` は後の run の値で上書きするため）。mtime が `since` より前のものと、`result` イベントが 1 件も無いものは `runs` に入れない
2. journal ごとに次の jq を通し、`events` を組み立てる。
   ```sh
   jq -s '(map(select(.type=="started"))|INDEX(.key)) as $s | map(select(.type=="result") | {label:$s[.key].label, phase:$s[.key].phase} + (.result|{status,tier,pr,verdict,must,should,nit,designMust,lessons,sha,conditions:(.conditions|length)}|with_entries(select(.value!=null))))' <journal>
   ```
3. `Workflow` ツールを `name: "retrospective"` と `args` で呼ぶ。

```json
{
  "runs": ["/tmp/.../wf_a22397c8-55c/journal.jsonl"],
  "events": { "/tmp/.../wf_a22397c8-55c/journal.jsonl": [ { "label": "Triage #157", "phase": "判定", "status": "plan", "tier": "light" } ] },
  "since": "2026-09-13T00:00:00Z",
  "base": "2f0a2ebff249f5b995a6647a1b0476549ede24d7",
  "scratchpad": "/tmp/claude-1000/…/scratchpad",
  "trailers": { "coAuthoredBy": "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>", "claudeSession": "Claude-Session: https://claude.ai/code/session_…", "sessionUrl": "https://claude.ai/code/session_…" }
}
```

学びが 0 件なら issue は起票されない。起票された issue は次の実行の `issues` に入れる。

### 3. ユーザーへの報告

1 件ごとに、issue 番号、tier、プランのラウンド数、PR 番号、PR レビューのラウンド数と条件の件数、最終確認の結果、マージのコミット、残した nit と後続の issue にした事項を短くまとめる。
止まった issue は、どの段階で、何が決まらなかったかを書く。
最後に `retrospective` を回し、起票された issue の番号とその根拠の表をユーザーに渡す（学びが 0 件なら起票されない）。

## dry run（スクリプトを変えたとき）

`args.dryRun` に issue 番号ごとのシナリオを渡すと、エージェントを立てずに制御の流れだけを確かめられる。シナリオは `happy`、`tier-none`（判定が none → プラン無しで実装 → PR レビュー APPROVE → 最終確認 → マージ）、`tier-none-design-must`（none で PR ラウンド 1 が `designMust` → その場でプラン v1 / r1 → 修正 → ラウンド 2 で APPROVE）、`tier-none-deviation`（none の実装が見込みを超えて `deviation` → その場でプラン v1 / r1 → 続きを実装 → マージ）、`pr-conditions`（PR ラウンド 1 が APPROVE ＋ 条件 2 件 → 条件対応 → 再レビュー無しで最終確認）、`approve-with-conditions`（プランレビューがラウンド 1 で条件 2 件つきの APPROVE。実装の依頼文に条件が入る）、`plan2`（プラン 2 ラウンド）、`plan-stall`（2 ラウンドで `stalled`）、`question`、`needs-user`（プランレビュアーが判断を求める）、`pr-needs-user`、`gate-needs-user`、`null`（実装が結果を返さない）、`null-fix`（修正が結果を返さない）、`impl-blocked`、`fix-blocked`、`deviation`、`planurl-deviation`（`planUrl` と組み合わせる）、`replan-reject`（版上げが承認されない）、`replan-question`、`pr2`、`design-must`、`gate`（最終確認で差し戻し）、`split`（判定で 2 件に分割、2 番目は 1 番目の後）、`split-parallel`（判定で依存の無い 2 件に分割）、`triage-question`（判定で質問）、`plan-split`（判定は plan だったがプランの調査で分割）、`child-split`（サブ issue の番号に付ける。サブ issue のプランが再分割を求めて `blocked`）、`ci-fail`（CI が通らず blocked）、`conflict`（マージで rebase）、`not-ready`（マージの条件を 1 回だけ確かめ直す）、`not-ready-twice`。

```json
{ "issues": [{ "n": 1, "branch": "x" }, { "n": 2, "branch": "y", "after": [1] }], "base": "0000000", "scratchpad": "/tmp/dry", "portBase": 5600, "trailers": { "coAuthoredBy": "a", "claudeSession": "b", "sessionUrl": "c" }, "dryRun": { "1": "plan2", "2": "conflict" } }
```

スクリプトを変えたら、上の `args` の `dryRun` のシナリオ名を 1 つずつ差し替えて全シナリオを回し、`results` の `status` が期待どおりであることを確かめる。`planurl-deviation` は `issues[0]` に `planUrl` を、`child-split` はサブ issue の番号（親が `split` のとき `n * 100 + 1`）に付ける。`issues[].tier` を足した `args` も 1 回回し、判定が飛んで tier が固定されることを見る。

`retrospective` は `args.dryRun: true` を渡すとエージェントを立てずに集計だけ返す。
