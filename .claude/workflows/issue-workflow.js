export const meta = {
  name: 'issue-pipeline',
  description: 'nostr-no-su の issue を、プラン → プランレビュー → 実装 → PR レビュー → 最終確認 → squash マージまで、役割別のエージェントで進める',
  whenToUse: 'スキル issue-workflow の段階 0 で args（issues、base、scratchpad、portBase、trailers）を組み立ててから呼ぶ。issue 番号だけでは動かない',
  phases: [
    { title: '判定', detail: 'issue だけ読んで分割の要否を決める。大きければサブ issue を作る' },
    { title: 'デザイン', detail: 'UI を変える issue だけ。方針を issue にコメントする。分割した親でも 1 回だけ' },
    { title: 'プラン', detail: 'issue-planner と issue-plan-reviewer の往復。APPROVE でレビュアーが issue に投稿する' },
    { title: '実装', detail: 'issue-implementer がブランチで実装して PR を作る' },
    { title: 'PR レビュー', detail: 'issue-pr-reviewer と修正の往復' },
    { title: '最終確認', detail: 'issue-final-gate が diff とレビューの経緯を読む' },
    { title: 'マージ', detail: 'issue-merger が確認して squash マージする。1 件ずつ' },
  ],
}

// ---------------------------------------------------------------------------
// args の契約（スキル issue-workflow の段階 0 で組み立てる）
//   issues:     [{ n, branch, ui?, after?: [n, ...], note?, planUrl? }]
//               planUrl: issue にすでに投稿済みで承認された「## 実装プラン」のコメント URL。あれば判定・デザイン・プランの段階を飛ばす
//               分割で生まれたサブ issue はスクリプトが足す（designUrl を親から継ぎ、depth 1。再分割はしない）
//   base:       origin/main の SHA。再開のときも同じ値を渡す（変えるとプロンプトが変わり、結果の再利用が効かない）
//   scratchpad: このセッションのスクラッチパッドの絶対パス
//   trailers:   { coAuthoredBy, claudeSession, sessionUrl }
//   portBase:   issue ごとに 10 個ずつ使う空きポートの先頭（ss -ltn で確かめてから渡す）
//   window:     同時に進める issue の数（既定 4）
//   decisions:  { [n]: 'ユーザーの決定の文' }。planner が質問を返した issue に、再開のとき渡す
//   dryRun:     { [n]: シナリオ名 } を渡すとエージェントを立てずに制御の流れだけ確かめる
// ---------------------------------------------------------------------------

const REPO = 'neverclear86/nostr-no-su'
const REPO_DIR = '/home/lina/workspace/projects/nostr-no-su'
const MAX_PLAN_ROUNDS = 5
const ESCALATE_AFTER = 3
const MAX_PR_ROUNDS = 4
const MAX_GATE_ROUNDS = 3
const MAX_REPLANS = 2
const MAX_REBASES = 2

const a = args || {}
if (typeof a !== 'object') throw new Error('args はオブジェクトで渡す（issue 番号だけを受け取ったときは、スキル issue-workflow の段階 0 で base・trailers・portBase を集めてから呼ぶ）')
if (!Array.isArray(a.issues) || a.issues.length === 0) throw new Error('args.issues が空である')
for (const k of ['base', 'scratchpad', 'trailers', 'portBase']) if (a[k] === undefined) throw new Error(`args.${k} が無い`)
const WINDOW = a.window || 4
const PLANS = `${a.scratchpad}/plans`
const decisions = a.decisions || {}
const dry = a.dryRun || null

// --- スキーマ（エージェントの型ごとに 1 つ。型・モデル・effort・スキーマが同じ agent はキャッシュの接頭辞を共有する） ---
const VERDICT = { type: 'string', enum: ['APPROVE', 'REQUEST CHANGES', 'NEEDS_USER'] }
const COUNTS = { must: { type: 'integer' }, should: { type: 'integer' }, nit: { type: 'integer' } }
const S = {
  design: { type: 'object', properties: { commentUrl: { type: 'string' } }, required: ['commentUrl'] },
  planner: {
    type: 'object',
    properties: {
      status: { type: 'string', enum: ['plan', 'question', 'split'], description: '判定の依頼では plan（分けずに進める）か split か question' },
      subIssues: {
        type: 'array',
        items: { type: 'object', properties: { n: { type: 'integer' }, after: { type: 'array', items: { type: 'integer' }, description: '先にマージされている必要がある兄弟サブ issue の番号。無ければ空' } }, required: ['n'] },
        description: 'status が split のとき、作ったサブ issue。after が無いもの同士は並列に進む',
      },
      file: { type: 'string', description: '書いたプランのファイル' },
      summary: { type: 'string', description: '方針の要約。版 2 以降は指摘への対応の表の要旨' },
      questions: { type: 'array', items: { type: 'string' }, description: 'status が question のとき、ユーザーに聞く質問' },
    },
    required: ['status'],
  },
  planReviewer: {
    type: 'object',
    properties: {
      verdict: VERDICT, ...COUNTS,
      file: { type: 'string', description: '書いたレビューのファイル' },
      headings: { type: 'array', items: { type: 'string' }, description: '各指摘の見出し' },
      postUrl: { type: 'string', description: 'APPROVE のときに issue に投稿したプランのコメントの URL' },
      questions: { type: 'array', items: { type: 'string' }, description: 'NEEDS_USER のときの論点' },
    },
    required: ['verdict', 'must', 'should', 'nit'],
  },
  implementer: {
    type: 'object',
    properties: {
      status: { type: 'string', enum: ['pr', 'fixed', 'rebased', 'deviation', 'blocked'], description: 'pr: PR を作った / fixed: 指摘に対応して push した / rebased: rebase して push した / deviation: プランどおりに作れない / blocked: 進められない' },
      pr: { type: 'integer' }, prUrl: { type: 'string' }, head: { type: 'string', description: 'push した head のコミット' },
      commentUrl: { type: 'string', description: 'fixed のとき、投稿した対応コメントの URL' },
      reportFile: { type: 'string', description: 'deviation のとき、逸脱の箇所と理由を書いたファイル' },
      reason: { type: 'string', description: 'deviation / blocked の理由、または rebase で解けなかった衝突' },
      ciPassed: { type: 'boolean', description: 'PR の head で CI の全ジョブが pass したか（pr / fixed / rebased のとき必須）' },
    },
    required: ['status'],
  },
  prReviewer: {
    type: 'object',
    properties: {
      verdict: VERDICT, ...COUNTS,
      commentUrl: { type: 'string', description: '投稿したレビューのコメントの URL' },
      designMust: { type: 'boolean', description: 'must のうち、承認済みプランの設計に起因するものがあるか' },
      questions: { type: 'array', items: { type: 'string' }, description: 'NEEDS_USER のときの論点' },
    },
    required: ['verdict', 'must', 'should', 'nit', 'commentUrl'],
  },
  gate: { type: 'object', properties: { verdict: VERDICT, ...COUNTS, commentUrl: { type: 'string' }, questions: { type: 'array', items: { type: 'string' }, description: 'NEEDS_USER のときの論点' } }, required: ['verdict', 'must', 'should', 'nit', 'commentUrl'] },
  merger: {
    type: 'object',
    properties: {
      status: { type: 'string', enum: ['merged', 'conflict', 'not_ready'], description: 'merged: マージした / conflict: main と衝突していて rebase が要る / not_ready: 承認や CI の条件を満たさない' },
      sha: { type: 'string', description: 'マージのコミット' }, issueClosed: { type: 'boolean' }, problem: { type: 'string' },
    },
    required: ['status'],
  },
}

// --- 小さな道具 -------------------------------------------------------------
/** 同時実行数を n に抑える */
function limiter(n) {
  let active = 0
  const queue = []
  const next = () => { if (active < n && queue.length) { active++; queue.shift()() } }
  return {
    acquire: () => new Promise((res) => { queue.push(res); next() }),
    release: () => { active--; next() },
  }
}
/** 1 つずつ順に実行する */
function mutex() {
  let tail = Promise.resolve()
  return (fn) => {
    const run = tail.then(fn, fn)
    tail = run.catch(() => {})
    return run
  }
}
/** 依存する issue の完了を待つための Promise の表 */
function deferred() {
  let resolve
  const promise = new Promise((r) => { resolve = r })
  return { promise, resolve }
}
class StageError extends Error {
  constructor(stage, message) { super(message); this.stage = stage }
}

const slots = limiter(WINDOW)
let nextIdx = a.issues.length
const mergeLock = mutex()
const done = new Map(a.issues.map((i) => [String(i.n), deferred()]))
/** issue 番号 → after の表。分割で生まれたサブ issue は runSplit が足す */
const afterOf = new Map(a.issues.map((i) => [String(i.n), (i.after || []).map(String)]))
let mergeSeq = 0

/** after の依存関係に循環（自己参照を含む）があるかを調べる */
function inCycle(start) {
  const seen = new Set()
  const stack = [...(afterOf.get(String(start)) || [])]
  while (stack.length) {
    const cur = stack.pop()
    if (cur === String(start)) return true
    if (seen.has(cur)) continue
    seen.add(cur)
    stack.push(...(afterOf.get(cur) || []))
  }
  return false
}

/** エージェントを 1 体立て、null（打ち切りや落ちた）を段階つきの例外にする */
async function call(stage, label, prompt, opts) {
  const result = dry ? fake(label, opts) : await agent(prompt, { ...opts, label })
  if (result === null || result === undefined) throw new StageError(stage, `${label} が結果を返さなかった`)
  return result
}

/** issue ごとの固定値（ポート、作業ツリー、docker のプロジェクト名） */
function env(issue, idx) {
  const p = a.portBase + idx * 10
  return {
    n: issue.n,
    branch: issue.branch,
    base: a.base,
    planWt: `${a.scratchpad}/wt-${issue.n}-plan`,
    wt: `${a.scratchpad}/wt-${issue.n}`,
    reviewWt: `${a.scratchpad}/wt-${issue.n}-review`,
    pgPort: p, ports: `${p + 1}（アプリ）、${p + 2}（strfry）`, project: `nns-issue${issue.n}`,
    reviewPgPort: p + 5, reviewPorts: `${p + 6}（アプリ）、${p + 7}（strfry）`, reviewProject: `nns-review${issue.n}`,
  }
}

// --- 依頼文 -----------------------------------------------------------------
const common = (e) => `- 土台: origin/main の ${e.base}
- 調査用の作業ツリー: ${e.planWt}（無ければ \`git -C ${REPO_DIR} worktree add --detach ${e.planWt} ${e.base}\` で作る）
- docker を使う検証の手順を書くときのプロジェクト名: ${e.project}、ポート: ${e.ports}`
/** docker と GitHub への書き込みで、ユーザーの資源と既存のコメントを壊さないための約束 */
const SAFETY = `- docker の後片付けは、自分が作ったコンテナー名か compose のプロジェクト名（\`--filter label=com.docker.compose.project=<自分のプロジェクト名>\`）で絞ったものだけを消す。\`docker ps -aq | xargs docker rm -f\` のような絞らない削除はしない。ユーザーの compose（プロジェクト nostr-no-su）の資源には触れない
- issue と PR のコメントは \`--body-file <ファイル>\` で投稿する。\`--body @file\` はファイル名がそのまま本文になる。既存のコメントは編集しない`
const P = {
  triage: (e, issue) => `issue #${e.n} を分割するかどうかを判定してほしい（定義の「分割の判定」）。プランはまだ書かない。
issue は \`gh issue view ${e.n} -R ${REPO} --comments\` で読む。触るファイルの当たりは ${REPO_DIR} を \`ls\`、\`grep -n\`、\`wc -l\` で読むだけにし、build や実行はしない。
${issue.note ? `- 補足: ${issue.note}\n` : ''}${decisions[e.n] ? `- ユーザーの決定: ${decisions[e.n]}\n` : ''}変更の見込みが 300 行か 6 ファイルを超えるか、独立に出せる「決めたこと」が 2 つ以上あるときだけ、サブ issue を作って status を split にする。しきい値以内なら status を plan にして返す（何も投稿しない）。issue の前提が間違っているときは status を question にする。
返答（構造化出力）: status、split のときは subIssues（各サブ issue の番号と、先にマージされている必要がある兄弟の番号 after）、summary に見込みの行数とファイル数。`,
  design: (e, issue) => `issue #${e.n} は管理 UI を変える。プランの前にデザインの方針を決めて、issue にコメントしてほしい。
issue は \`gh issue view ${e.n} -R ${REPO} --comments\` で読む。管理 UI のソースは ${REPO_DIR}/src/nostr_no_su/admin/ にある（ユーザーの作業ツリーなので読むだけにする）。
画面構成、使うコンポーネント（daisyUI）、テーマ、狭い幅（375px）、空とエラーの状態の方針を、標準的な技術文体の日本語（である調、一文一行）で \`gh issue comment ${e.n} -R ${REPO} --body-file <スクラッチパッドのファイル>\` で投稿する。
${issue.note ? `補足: ${issue.note}\n` : ''}返すもの: 投稿したコメントの URL。`,
  plan1: (e, issue, designUrl) => `issue #${e.n} の実装プラン（版 1）を書いてほしい。
${common(e)}
- プランの書き先: ${PLANS}/${e.n}-v1.md
${designUrl ? `- デザインの方針: ${designUrl}。プランはこれを取り込む\n` : ''}${issue.note ? `- 補足: ${issue.note}\n` : ''}${decisions[e.n] ? `- ユーザーの決定: ${decisions[e.n]}\n` : ''}issue の前提が間違っている、またはユーザーにしか決められない選択があるときは、プランを書かずに status を question にして質問を返す。${issue.depth ? 'この issue は分割で生まれたサブ issue なので、これ以上分割しない。変更の見込みがしきい値を超えるなら、超える理由をプランの冒頭に 1 行で書く。' : '分割の判定は済んでいる（分けずに進めると決めた）。調査でしきい値を大きく超えると分かったときだけ、定義の「分割の判定」に従ってサブ issue を作り、status を split にして返す。'}
返答（構造化出力）: status、プランのファイル、方針の要約と決めたことの見出し。プランの全文は返さない。`,
  // 版 2 以降は、前の版とレビューのファイル名を規約（{n}-v{v-1}.md、{n}-r{r}.md）で組む
  planNext: (e, v, r, effortNote) => `issue #${e.n} の実装プラン（版 ${v}）を書いてほしい。前の版のレビューは REQUEST CHANGES だった。
- 前の版: ${PLANS}/${e.n}-v${v - 1}.md
- レビュー（ラウンド ${r}）: ${PLANS}/${e.n}-r${r}.md
${common(e)}
- 書き先: ${PLANS}/${e.n}-v${v}.md（前の版をコピーしてから直す）
前の版の「決めたこと」は変えず、レビューの指摘の該当箇所だけ直す。指摘が「決めたこと」の変更を求めているときだけ、その 1 件を直す。
読むのは、issue と、レビューの「該当」と「根拠」が指すファイルに絞る。
${effortNote}返答（構造化出力）: status、プランのファイル、「指摘への対応」の表の要旨。プランの全文は返さない。`,
  planRevise: (e, v, prevPlan, reportFile, why) => `issue #${e.n} の実装プランの版を上げてほしい（${v ? `版 ${v}` : '版の番号は、投稿済みの版の番号に 1 を足す'}）。${why}
- 承認済みの前の版: ${prevPlan}${prevPlan.startsWith('http') ? '（issue コメントの URL。本文は `gh api` で読む）' : ''}
- 逸脱の報告: ${reportFile}${reportFile.startsWith('http') ? '（PR コメントの URL。本文は `gh api` で読む）' : ''}
${common(e)}
- 書き先: ${PLANS}/${e.n}-v${v || '<版>'}.md（前の版をコピーしてから直す）
先頭の表は逸脱ごとの対応の表にする。前の版の「決めたこと」は、逸脱が変更を求めている箇所だけ直す。
返答（構造化出力）: status、プランのファイル、対応の表の要旨。`,
  review1: (e) => `issue #${e.n} の実装プラン（版 1）をレビューしてほしい（ラウンド 1）。
- プラン: ${PLANS}/${e.n}-v1.md
- 土台: origin/main の ${e.base}
- 調査用の作業ツリー: ${e.planWt}（すでにあるので、実行はこの下で行う）
- レビューの書き先: ${PLANS}/${e.n}-r1.md
判定が APPROVE なら、承認した版を issue に投稿する（書き先 ${PLANS}/${e.n}-post.md）。
返答（構造化出力）: 判定、must と should と nit の件数、各指摘の見出し、投稿したコメントの URL。レビューの全文は返さない。`,
  reviewNext: (e, v, r, planFile, prevReview) => `issue #${e.n} の実装プラン（${v ? `版 ${v}` : '版を上げたもの'}）をレビューしてほしい（ラウンド ${r}）。
- プラン: ${planFile}（先頭に前ラウンドの指摘、または逸脱への対応の表がある）
- ${prevReview ? `前のラウンドのレビュー: ${prevReview}` : '前のラウンドのレビューは無い（承認済みの版を、逸脱または PR レビューの must を受けて上げた）'}
- 土台: origin/main の ${e.base}
- 調査用の作業ツリー: ${e.planWt}（無ければ \`git -C ${REPO_DIR} worktree add --detach ${e.planWt} ${e.base}\` で作る）
- レビューの書き先: ${PLANS}/${e.n}-r${r}.md
${prevReview ? '前のラウンドの指摘ごとに直ったかを照合し、再判定してほしい。新しい指摘は前のラウンドで見落としたものに限る。' : '対応の表の各項目が前の版の決定と矛盾しないか、逸脱の解き方が issue の受け入れ条件を満たすかを見て判定してほしい。'}
判定が APPROVE なら、承認した版を issue に投稿する（書き先 ${PLANS}/${e.n}-post.md。先頭の「指摘への対応」の表は含めない）。
返答（構造化出力）: 判定、must と should と nit の件数、各指摘の見出し、投稿したコメントの URL。レビューの全文は返さない。`,
  implement: (e, issue, postUrl) => `issue #${e.n} を、承認済みの実装プラン（${postUrl}）のとおりに実装し、PR を作ってほしい。プランは \`gh api\` でその URL のコメント本文を読む。
- 土台: origin/main の ${e.base}
- 作業ツリー: ${e.wt}、ブランチ: ${e.branch}（無ければ \`git -C ${REPO_DIR} fetch origin main && git -C ${REPO_DIR} worktree add -b ${e.branch} ${e.wt} origin/main\` で作る。ブランチがすでに origin にあり、その PR が \`Closes #${e.n}\` を持つか PR がまだ無ければ、それを取り出して続きから進める。別の issue の PR が付いているブランチなら status を blocked にして reason に書く。PR がすでにあれば新しく作らずに push して本文を直す）
- テスト用 Postgres のポート: ${e.pgPort}。docker のプロジェクト名: ${e.project}、ポート: ${e.ports}
- コミットのトレーラー（本文の最後に 2 行）:
  ${a.trailers.coAuthoredBy}
  ${a.trailers.claudeSession}
- PR 本文の末尾（\`Closes #${e.n}\` の後に 2 行）:
  🤖 Generated with [Claude Code](https://claude.com/claude-code)
  ${a.trailers.sessionUrl}
${issue.ui ? '- UI を変えるので、変更前と変更後のスクリーンショットを PR に貼る\n' : ''}プランどおりに作れない箇所が見つかったら、勝手に設計を変えずに、逸脱の箇所と理由を ${PLANS}/${e.n}-deviation.md に書き、status を deviation にして返す。
PR を作ったら \`gh pr checks <PR> -R ${REPO} --watch\` で CI の全ジョブが pass するのを待ち、fail なら直して push してから返す。
${SAFETY}
返答（構造化出力）: status、PR の番号と URL、head のコミット、ciPassed。`,
  implementContinue: (e, postUrl) => `issue #${e.n} の実装プランが版を上げて承認された（${postUrl}）。前の実装エージェントが途中まで進めたブランチ ${e.branch} と作業ツリー ${e.wt} がすでにある。
新しい版のプランとの差分だけを直して実装を仕上げ、PR を作ってほしい（すでに PR があれば push して本文を直す）。
- テスト用 Postgres のポート: ${e.pgPort}。docker のプロジェクト名: ${e.project}、ポート: ${e.ports}
- コミットのトレーラーと PR 本文の末尾は、作業ツリーの \`git log\` と既存の PR 本文の形に合わせる。無ければ次の 2 行:
  ${a.trailers.coAuthoredBy}
  ${a.trailers.claudeSession}
PR を作ったら（または push したら）\`gh pr checks <PR> -R ${REPO} --watch\` で CI の全ジョブが pass するのを待ち、fail なら直して push してから返す。
${SAFETY}
返答（構造化出力）: status、PR の番号と URL、head のコミット、ciPassed。`,
  fix: (e, pr, reviewUrl, kind, planNote) => `PR #${pr}（issue #${e.n}、ブランチ ${e.branch}）の${kind}（${reviewUrl}）は REQUEST CHANGES だった。指摘は \`gh api\` でその URL のコメント本文を読む。
${planNote ? `${planNote}\n` : ''}
作業ツリー ${e.wt} とブランチはすでにある（無ければ \`git -C ${REPO_DIR} fetch origin ${e.branch} && git -C ${REPO_DIR} worktree add ${e.wt} ${e.branch}\` で作る）。
- テスト用 Postgres のポート: ${e.pgPort}。docker のプロジェクト名: ${e.project}、ポート: ${e.ports}
- コミットのトレーラー: 作業ツリーの \`git log\` の直近のコミットと同じ 2 行
直して push し、「## ${kind}の指摘への対応（<短い SHA>）」を PR に投稿して、コメントの URL と新しい head を返してほしい。
push したら \`gh pr checks ${pr} -R ${REPO} --watch\` で CI の全ジョブが pass するのを待ち、fail なら直して push してから返す。
${SAFETY}
返答（構造化出力）: status は fixed、対応コメントの URL、head のコミット、ciPassed。`,
  prReview1: (e, pr, head, postUrl, issue) => `PR #${pr}（issue #${e.n}、ブランチ ${e.branch}、head ${head}）をレビューしてほしい（ラウンド 1）。
- 承認済みのプラン: ${postUrl}
- 土台: origin/main の ${e.base}
- 再現用の作業ツリー: ${e.reviewWt}（\`git -C ${REPO_DIR} fetch origin ${e.branch} && git -C ${REPO_DIR} worktree add --detach ${e.reviewWt} origin/${e.branch}\` で作る）
- テスト用 Postgres のポート: ${e.reviewPgPort}。docker のプロジェクト名: ${e.reviewProject}、ポート: ${e.reviewPorts}
${issue.ui ? '- UI を変える PR なので、スクリーンショットと CSS の再ビルドも見る\n' : ''}CI は head で pass している。CI が行う検査（build、test、format、CSS、vendor、プラグイン、.env.example）は再現せず、CI に無い検証だけを再現する。
レビューを PR コメントに投稿してほしい。
${SAFETY}
返答（構造化出力）: 判定、must と should と nit の件数、コメントの URL、must が承認済みプランの設計に起因するか。`,
  prReviewNext: (e, pr, r, responseUrl, head, prevUrl, prevKind) => `PR #${pr}（issue #${e.n}、ブランチ ${e.branch}）のレビューをしてほしい（ラウンド ${r}）。
実装側が${prevKind}（${prevUrl}）の指摘に対応した（${responseUrl}、head ${head}）。
- 再現用の作業ツリー: ${e.reviewWt}（\`git -C ${e.reviewWt} fetch origin ${e.branch} && git -C ${e.reviewWt} checkout --detach origin/${e.branch}\` で進める。無ければ \`git -C ${REPO_DIR} worktree add --detach ${e.reviewWt} origin/${e.branch}\` で作る）
- テスト用 Postgres のポート: ${e.reviewPgPort}。docker のプロジェクト名: ${e.reviewProject}、ポート: ${e.reviewPorts}
前のラウンドの指摘ごとに直ったかを照合し、対応コミットの差分がその範囲に収まっているかを確かめて、再判定してほしい。
${SAFETY}
返答（構造化出力）: 判定、must と should と nit の件数、コメントの URL、must が承認済みプランの設計に起因するか。`,
  gate1: (e, pr, head, postUrl, approveUrl, r) => `PR #${pr}（issue #${e.n}、head ${head}）の最終確認をしてほしい。
- 承認済みのプラン: ${postUrl}
- PR レビューの APPROVE: ${approveUrl}（ラウンド ${r}）
再現はせず、diff とレビューの経緯と受け入れ条件の照合だけを行い、「## 最終確認」を PR コメントに投稿してほしい。
返答（構造化出力）: 判定、must と should と nit の件数、コメントの URL。`,
  gateNext: (e, pr, head, responseUrl, approveUrl, prevGateUrl) => `PR #${pr}（issue #${e.n}、head ${head}）の最終確認の再確認をしてほしい。
前回の最終確認（${prevGateUrl}）の指摘に実装側が対応し（${responseUrl}）、PR レビュアーも再レビューで APPROVE を出した（${approveUrl}）。
前回の指摘ごとに直ったかを照合し、再確認の結果を PR コメントに投稿してほしい。見出しは再確認でも「## 最終確認」だけにする（マージ担当が見出しの完全一致で探す）。
返答（構造化出力）: 判定、must と should と nit の件数、コメントの URL。`,
  merge: (e, pr, head, approvedHead) => `PR #${pr}（issue #${e.n}、ブランチ ${e.branch}、head ${head}）をマージしてほしい。
- レビューと最終確認が APPROVE を出した head: ${approvedHead}${head !== approvedHead ? '（その後に rebase で head が変わった。差分が rebase だけであることを確かめてからマージする）' : ''}
- 作業ツリー（マージの前に消す）: ${e.wt}、${e.reviewWt}、${e.planWt}
- squash コミットの本文（トレーラー 2 行）:
  ${a.trailers.coAuthoredBy}
  ${a.trailers.claudeSession}
返答（構造化出力）: status（merged / conflict / not_ready）、マージのコミット、issue が閉じたか、問題があればその内容。`,
  rebase: (e, pr) => `PR #${pr}（issue #${e.n}、ブランチ ${e.branch}）が main と衝突している。作業ツリー ${e.wt}（無ければ \`git -C ${REPO_DIR} fetch origin ${e.branch} && git -C ${REPO_DIR} worktree add ${e.wt} ${e.branch}\` で作る）で \`git fetch origin main && git rebase origin/main\` を行い、衝突を解いて \`gleam build --warnings-as-errors\` と \`gleam test\`（Postgres はポート ${e.pgPort}）を通し、\`git push --force-with-lease\` してほしい。
rebase 以外の変更を入れない。
push したら \`gh pr checks ${pr} -R ${REPO} --watch\` で CI の全ジョブが pass するのを待つ。
${SAFETY}
返答（構造化出力）: status は rebased（解けない衝突があれば blocked にして reason に書く）、新しい head のコミット、ciPassed。`,
}

// --- 段階 -------------------------------------------------------------------
/** subIssues を { n, after } の形にそろえる（番号だけの要素は依存無し） */
function normalizeSubIssues(stage, n, subIssues) {
  if (!Array.isArray(subIssues) || subIssues.length === 0) throw new StageError(stage, `#${n} は split だがサブ issue の番号が無い`)
  const subs = subIssues.map((s) => (typeof s === 'number' ? { n: s, after: [] } : { n: s.n, after: s.after || [] }))
  const nums = new Set(subs.map((s) => s.n))
  for (const s of subs) {
    if (!Number.isInteger(s.n)) throw new StageError(stage, `#${n} のサブ issue の番号が整数でない: ${JSON.stringify(s)}`)
    for (const d of s.after) if (!nums.has(d)) throw new StageError(stage, `#${n} のサブ issue #${s.n} の after #${d} が兄弟にいない`)
  }
  return subs
}

/** 分割の判定。issue だけ読んで、分けずに進めるか、サブ issue に分けるかを決める */
async function triageStage(e, issue) {
  const t = await call('triage', `Triage #${e.n}`, P.triage(e, issue), { agentType: 'issue-planner', phase: '判定', schema: S.planner })
  if (t.status === 'question') return { blocked: { stage: 'triage', questions: t.questions || [t.summary] } }
  if (t.status === 'split') return { split: normalizeSubIssues('triage', e.n, t.subIssues) }
  return {}
}

/** UI を変える issue のデザイン。分割した親で 1 回だけ行い、サブ issue は親の URL を継ぐ */
async function designStage(e, issue, state) {
  if (!issue.ui || issue.designUrl) return {}
  const d = await call('design', `Design #${e.n}`, P.design(e, issue), { agentType: 'issue-designer', phase: 'デザイン', schema: S.design })
  state.designUrl = d.commentUrl
  return {}
}

/** プランとプランレビューの往復。承認された版の issue コメント URL を返す */
async function planStage(e, issue, state) {
  const designUrl = issue.designUrl || state.designUrl || null
  let v = 0, r = 0, escalated = false
  while (true) {
    v++
    const effortNote = escalated ? 'ラウンドが重なっているので、effort は high 相当で、根拠を確かめながら書く。\n' : ''
    const plan = await call('plan', `Plan #${e.n} v${v}`,
      v === 1 ? P.plan1(e, issue, designUrl) : P.planNext(e, v, r, effortNote),
      { agentType: 'issue-planner', phase: 'プラン', schema: S.planner, ...(escalated ? { effort: 'high' } : {}) })
    if (plan.status === 'question') return { blocked: { stage: 'plan', questions: plan.questions || [plan.summary] } }
    if (plan.status === 'split') {
      // サブ issue の再分割は許さない（連鎖が直列化して枠が潰れる）。親の分割の粒度を見直す判断はユーザーに戻す
      if (issue.depth) return { blocked: { stage: 'plan', questions: [`サブ issue #${e.n}（親 #${issue.parent}）のプランがさらに分割を求めた: ${plan.summary || ''}。親の「## 分割の設計」の粒度を見直すか、このまま 1 件で実装させるかを決める`] } }
      return { split: normalizeSubIssues('plan', e.n, plan.subIssues) }
    }
    r++
    const rev = await call('plan-review', `Review plan #${e.n} r${r}`,
      r === 1 ? P.review1(e) : P.reviewNext(e, v, r, plan.file || `${PLANS}/${e.n}-v${v}.md`, `${PLANS}/${e.n}-r${r - 1}.md`),
      { agentType: 'issue-plan-reviewer', phase: 'プラン', schema: S.planReviewer })
    state.planRounds = r
    if (rev.verdict === 'NEEDS_USER') return { blocked: { stage: 'plan-review', questions: rev.questions || rev.headings } }
    if (rev.verdict === 'APPROVE') {
      if (!rev.postUrl) throw new StageError('plan-review', `#${e.n} のプランは APPROVE だが投稿の URL が無い`)
      state.nits += rev.nit || 0
      state.postFile = `${PLANS}/${e.n}-post.md`
      return { postUrl: rev.postUrl, version: v }
    }
    if (r >= MAX_PLAN_ROUNDS) return { stalled: { stage: 'plan', reason: `プランレビューが ${r} ラウンドで収束しない（最後は must ${rev.must}、should ${rev.should}）` } }
    if (r >= ESCALATE_AFTER && !escalated) { escalated = true; log(`#${e.n}: プランレビューが ${r} ラウンドで APPROVE にならないので、次の版は effort high で書く`) }
  }
}

/** 逸脱や設計に起因する must を受けて、承認済みプランの版を上げて再承認させる */
async function revisePlan(e, state, reportFile, why) {
  // planUrl で始めた issue は版の番号が分からないので、プランエージェントに投稿済みの版から決めさせる
  const v = state.version ? state.version + 1 : null
  state.replans = (state.replans || 0) + 1
  const prevPlan = state.postFile || state.postUrl
  const plan = await call('replan', `Plan #${e.n} ${v ? `v${v}` : `revise ${state.replans}`}`, P.planRevise(e, v, prevPlan, reportFile, why), { agentType: 'issue-planner', phase: 'プラン', schema: S.planner, effort: 'high' })
  if (plan.status === 'question') return { blocked: { stage: 'replan', questions: plan.questions || [plan.summary] } }
  if (!plan.file) throw new StageError('replan', `#${e.n} の版上げがプランのファイルを返さなかった`)
  if (v) state.version = v
  state.planRounds++
  const r = state.planRounds
  const rev = await call('replan-review', `Review plan #${e.n} r${r}`, P.reviewNext(e, v, r, plan.file, null), { agentType: 'issue-plan-reviewer', phase: 'プラン', schema: S.planReviewer })
  if (rev.verdict !== 'APPROVE') return { blocked: { stage: 'replan-review', questions: rev.questions || rev.headings || ['版を上げたプランが承認されない'] } }
  if (!rev.postUrl) throw new StageError('replan-review', `#${e.n} の版上げは APPROVE だが投稿の URL が無い`)
  state.postUrl = rev.postUrl
  state.postFile = `${PLANS}/${e.n}-post.md`
  return {}
}

/** 実装と PR 作成。逸脱はプランの版を上げてから続きを実装させる */
async function implementStage(e, issue, state) {
  let impl = await call('implement', `Implement #${e.n}`, P.implement(e, issue, state.postUrl), { agentType: 'issue-implementer', phase: '実装', schema: S.implementer })
  let replans = 0
  while (impl.status === 'deviation') {
    if (replans >= MAX_REPLANS) return { stalled: { stage: 'implement', reason: `逸脱でプランを ${replans} 回上げても実装が終わらない: ${impl.reason || ''}` } }
    replans++
    log(`#${e.n}: 実装がプランから逸脱した（${impl.reason || impl.reportFile}）。プランの版を上げる`)
    const rv = await revisePlan(e, state, impl.reportFile || `${PLANS}/${e.n}-deviation.md`, '実装中にプランどおりに作れない箇所が見つかった。')
    if (rv.blocked) return rv
    impl = await call('implement', `Implement #${e.n} (続き ${replans})`, P.implementContinue(e, state.postUrl), { agentType: 'issue-implementer', phase: '実装', schema: S.implementer })
  }
  if (impl.status === 'blocked') return { blocked: { stage: 'implement', questions: [impl.reason || '実装が進められない'] } }
  if (!impl.pr || !impl.head) throw new StageError('implement', `#${e.n} の実装が PR の番号か head を返さなかった`)
  if (impl.ciPassed !== true) return { blocked: { stage: 'implement', questions: [`PR #${impl.pr} の CI が通っていない（${impl.reason || '理由の報告なし'}）`] } }
  state.pr = impl.pr
  state.head = impl.head
  return {}
}

/** 指摘への対応を新しい実装エージェントにさせる */
async function fixRound(e, state, label, prompt, phase) {
  const fix = await call('fix', label, prompt, { agentType: 'issue-implementer', phase, schema: S.implementer })
  if (fix.status === 'blocked' || fix.status === 'deviation') return { blocked: { stage: 'fix', questions: [fix.reason || '指摘への対応が進められない'] } }
  if (!fix.commentUrl || !fix.head) throw new StageError('fix', `${label} が対応コメントの URL か head を返さなかった`)
  if (fix.ciPassed !== true) return { blocked: { stage: 'fix', questions: [`対応コミット ${fix.head} の CI が通っていない（${fix.reason || '理由の報告なし'}）`] } }
  return fix
}

/** PR レビューと修正の往復。APPROVE のコメント URL を返す */
async function prReviewStage(e, issue, state) {
  let responseUrl = null, prevUrl = null, designReplanned = false
  while (true) {
    state.prRounds++
    const r = state.prRounds
    const rev = await call('pr-review', `PR review #${state.pr} r${r}`,
      r === 1 ? P.prReview1(e, state.pr, state.head, state.postUrl, issue) : P.prReviewNext(e, state.pr, r, responseUrl, state.head, prevUrl, `ラウンド ${r - 1} のレビュー`),
      { agentType: 'issue-pr-reviewer', phase: 'PR レビュー', schema: S.prReviewer })
    prevUrl = rev.commentUrl
    if (rev.verdict === 'NEEDS_USER') return { blocked: { stage: 'pr-review', questions: rev.questions || ['レビュアーがユーザーの判断を求めた'] } }
    if (rev.verdict === 'APPROVE') { state.approveUrl = rev.commentUrl; state.nits += rev.nit || 0; return {} }
    if (r >= MAX_PR_ROUNDS) return { stalled: { stage: 'pr-review', reason: `PR レビューが ${r} ラウンドで収束しない（最後は must ${rev.must}、should ${rev.should}）` } }
    let planNote = ''
    if (rev.designMust && !designReplanned) {
      designReplanned = true
      log(`#${e.n}: PR レビューの must がプランの設計に起因するので、プランの版を上げる`)
      const rv = await revisePlan(e, state, rev.commentUrl, 'PR レビューで、承認済みプランの設計に起因する must が出た。')
      if (rv.blocked) return rv
      planNote = `この must を受けてプランの版が上がり、承認された（${state.postUrl}）。新しい版との差分も含めて直す。`
    }
    const fix = await fixRound(e, state, `Fix PR #${state.pr} r${r}`, P.fix(e, state.pr, rev.commentUrl, `レビュー（ラウンド ${r}）`, planNote), 'PR レビュー')
    if (fix.blocked) return fix
    responseUrl = fix.commentUrl
    state.head = fix.head
  }
}

/** 最終確認。REQUEST CHANGES なら修正 → PR 再レビュー → 再確認 */
async function gateStage(e, state) {
  let prevGateUrl = null, responseUrl = null
  for (let g = 1; g <= MAX_GATE_ROUNDS; g++) {
    state.gateRounds = g
    const gate = await call('gate', g === 1 ? `Final gate PR #${state.pr}` : `Final gate PR #${state.pr} r${g}`,
      g === 1 ? P.gate1(e, state.pr, state.head, state.postUrl, state.approveUrl, state.prRounds) : P.gateNext(e, state.pr, state.head, responseUrl, state.approveUrl, prevGateUrl),
      { agentType: 'issue-final-gate', phase: '最終確認', schema: S.gate })
    prevGateUrl = gate.commentUrl
    if (gate.verdict === 'APPROVE') { state.nits += gate.nit || 0; state.approvedHead = state.head; return {} }
    if (gate.verdict === 'NEEDS_USER') return { blocked: { stage: 'gate', questions: gate.questions || ['最終確認がユーザーの判断を求めた'] } }
    if (g === MAX_GATE_ROUNDS) break
    const fix = await fixRound(e, state, `Fix PR #${state.pr} gate r${g}`, P.fix(e, state.pr, gate.commentUrl, '最終確認', ''), '最終確認')
    if (fix.blocked) return fix
    responseUrl = fix.commentUrl
    state.head = fix.head
    state.prRounds++
    const rev = await call('pr-review', `PR review #${state.pr} r${state.prRounds}`, P.prReviewNext(e, state.pr, state.prRounds, responseUrl, state.head, gate.commentUrl, '最終確認'), { agentType: 'issue-pr-reviewer', phase: '最終確認', schema: S.prReviewer })
    if (rev.verdict !== 'APPROVE') return { stalled: { stage: 'gate', reason: `最終確認の指摘への対応が PR レビューで APPROVE にならない（must ${rev.must}、should ${rev.should}）` } }
    state.approveUrl = rev.commentUrl
  }
  return { stalled: { stage: 'gate', reason: `最終確認が ${MAX_GATE_ROUNDS} 回で APPROVE にならない` } }
}

/** マージ。衝突なら rebase させて再試行。1 件ずつ */
async function mergeStage(e, state) {
  return mergeLock(async () => {
    let notReady = false
    for (let t = 0; t <= MAX_REBASES; t++) {
      const m = await call('merge', t === 0 && !notReady ? `Merge PR #${state.pr}` : `Merge PR #${state.pr} (retry ${t}${notReady ? ' recheck' : ''})`, P.merge(e, state.pr, state.head, state.approvedHead), { agentType: 'issue-merger', phase: 'マージ', schema: S.merger })
      if (m.status === 'merged') { state.mergeSha = m.sha; state.issueClosed = m.issueClosed !== false; state.mergeSeq = ++mergeSeq; return {} }
      if (m.status === 'not_ready') {
        if (notReady) return { stalled: { stage: 'merge', reason: m.problem || 'マージの条件を満たさない' } }
        notReady = true
        log(`#${e.n}: PR #${state.pr} はまだマージの条件を満たさない（${m.problem || ''}）。1 回だけ確かめ直す`)
        t--
        continue
      }
      if (t === MAX_REBASES) return { stalled: { stage: 'merge', reason: `rebase を ${t} 回しても衝突が解けない: ${m.problem || ''}` } }
      log(`#${e.n}: PR #${state.pr} が main と衝突しているので rebase させる`)
      const rb = await call('rebase', `Rebase PR #${state.pr} (${t + 1})`, P.rebase(e, state.pr), { agentType: 'issue-implementer', phase: 'マージ', schema: S.implementer })
      if (rb.status !== 'rebased' || !rb.head) return { stalled: { stage: 'merge', reason: `rebase の衝突に設計の判断が要る: ${rb.reason || rb.status}` } }
      if (rb.ciPassed !== true) return { stalled: { stage: 'merge', reason: `rebase 後の CI が通っていない: ${rb.reason || ''}` } }
      state.head = rb.head
    }
    return { stalled: { stage: 'merge', reason: '到達しないはずの経路' } }
  })
}

/** 分割で生まれたサブ issue を並列に進める。after を宣言した子だけが兄弟のマージを待つ */
async function runSplit(parent, subs, designUrl) {
  // 兄弟の完了の表と after の表は、どの子を始めるより前に全部そろえる（後の兄弟に依存する子が「依存先がいない」で止まらないように）
  for (const s of subs) {
    if (!done.has(String(s.n))) done.set(String(s.n), deferred())
    afterOf.set(String(s.n), (s.after.length ? s.after : (parent.after || [])).map(String))
  }
  return Promise.all(subs.map(async (s) => {
    const child = {
      n: s.n, branch: `${parent.branch}-${s.n}`, ui: parent.ui, designUrl, depth: (parent.depth || 0) + 1, parent: parent.n,
      after: afterOf.get(String(s.n)).map(Number),
      note: `#${parent.n} を分割したサブ issue。親の issue のコメント「## 分割の設計」に全体の方針と兄弟との分担がある`,
    }
    const res = await runIssue(child, nextIdx++)
    done.get(String(s.n)).resolve(res)
    return res
  }))
}

/** 分割された依存先を、子が全部マージされていれば最後にマージされた子で置き換える */
function resolveSplitDep(res) {
  if (res.status !== 'split' || !(res.children || []).length || !res.children.every((c) => c.status === 'merged')) return res
  return res.children.reduce((last, c) => (c.mergeSeq > last.mergeSeq ? c : last))
}

/** 1 件の issue を最初から最後まで進める */
async function runIssue(issue, idx) {
  const e = env(issue, idx)
  const state = { n: issue.n, base: e.base, planRounds: 0, version: 0, prRounds: 0, gateRounds: 0, nits: 0, designUrl: issue.designUrl || null, postUrl: null, postFile: null, pr: null, head: null, approveUrl: null }
  const finish = (extra) => ({ ...state, ...extra })
  let acquired = false
  try {
    // 依存する issue のマージを待つ。循環は待つ前に弾く
    if (inCycle(issue.n)) return finish({ status: 'blocked', stage: 'deps', questions: [`#${issue.n} の after が循環している`] })
    let latestDep = null
    for (const dep of issue.after || []) {
      const d = done.get(String(dep))
      if (!d) return finish({ status: 'blocked', stage: 'deps', questions: [`依存先の #${dep} がこの実行に含まれていない（すでにマージ済みなら after から外す）`] })
      // 分割された依存先は、サブ issue が全部マージされていれば最後にマージされたサブ issue を依存先とみなす
      const res = resolveSplitDep(await d.promise)
      if (res.status !== 'merged') return finish({ status: 'blocked', stage: 'deps', questions: [`依存先の #${dep} が ${res.status} で終わった`] })
      if (!latestDep || res.mergeSeq > latestDep.mergeSeq) latestDep = res
    }
    // should 4: 依存先を取り込んだ main を土台にする（マージは直列なので、最後にマージされた依存先が他を含む）
    if (latestDep) { e.base = latestDep.mergeSha; state.base = e.base }
    await slots.acquire()
    acquired = true
    const stages = [
      // 判定 → デザイン → プラン。承認済みのプランがあれば 3 つとも飛ばす。サブ issue は判定を飛ばし、デザインは親の URL を継ぐ
      async () => {
        if (issue.planUrl) { state.postUrl = issue.planUrl; log(`#${issue.n}: 承認済みのプラン ${issue.planUrl} を使い、プランの段階を飛ばす`); return {} }
        if (!issue.depth) {
          const t = await triageStage(e, issue)
          if (t.blocked) return t
          if (t.split) {
            const d = await designStage(e, issue, state)
            if (d.blocked) return d
            return t
          }
        }
        const d = await designStage(e, issue, state)
        if (d.blocked) return d
        const r = await planStage(e, issue, state)
        if (r.postUrl) { state.postUrl = r.postUrl; state.version = r.version }
        return r
      },
      () => implementStage(e, issue, state),
      () => prReviewStage(e, issue, state),
      () => gateStage(e, state),
      () => mergeStage(e, state),
    ]
    for (const stage of stages) {
      const r = await stage()
      if (r.blocked) return finish({ status: 'blocked', ...r.blocked })
      if (r.stalled) return finish({ status: 'stalled', ...r.stalled })
      if (r.split) {
        // 親の枠を返してから、サブ issue を同じ実行に足す。after の無い子は並列に進む
        slots.release(); acquired = false
        log(`#${issue.n}: 大きいのでサブ issue ${r.split.map((s) => `#${s.n}${s.after.length ? `（${s.after.map((d) => `#${d}`).join(' ')} の後）` : ''}`).join(' ')} に分けた`)
        const children = await runSplit(issue, r.split, state.designUrl)
        return finish({ status: 'split', subIssues: r.split.map((s) => s.n), children })
      }
    }
    log(`#${issue.n}: PR #${state.pr} をマージした（${state.mergeSha}）`)
    return finish({ status: 'merged' })
  } catch (err) {
    return finish({ status: 'failed', stage: err.stage || 'unknown', reason: err.message })
  } finally {
    if (acquired) slots.release()
  }
}

// --- dry run（エージェントを立てずに制御の流れを確かめる） --------------------
function fake(label, opts) {
  // ラベルの番号は issue 番号か PR 番号（dry run では PR 番号 = issue 番号 + 1000）
  const num = Number((label.match(/#(\d+)/) || [])[1])
  const n = String(/PR #|PR review #/.test(label) ? num - 1000 : num)
  const sc = (dry && dry[n]) || 'happy'
  const v = (label.match(/ v(\d+)/) || [])[1]
  const r = Number((label.match(/ r(\d+)/) || [])[1] || 1)
  const t = opts.agentType
  if (sc === 'null-fix' && label.startsWith('Fix')) return null
  if (t === 'issue-designer') return { commentUrl: `https://example/issue/${n}#design` }
  if (t === 'issue-planner') {
    if (label.startsWith('Triage')) {
      // split: 2 番目が 1 番目の後 / split-parallel: 依存無し / triage-question: 判定で質問
      if (sc === 'split') return { status: 'split', subIssues: [{ n: Number(n) * 100 + 1, after: [] }, { n: Number(n) * 100 + 2, after: [Number(n) * 100 + 1] }], summary: '見込み 500 行 / 8 ファイル' }
      if (sc === 'split-parallel') return { status: 'split', subIssues: [{ n: Number(n) * 100 + 1 }, { n: Number(n) * 100 + 2 }], summary: '見込み 400 行' }
      if (sc === 'triage-question') return { status: 'question', questions: ['issue の前提の A は今の main に無い'] }
      return { status: 'plan', summary: '見込み 120 行 / 3 ファイル' }
    }
    if (sc === 'question' && v === '1') return { status: 'question', questions: ['since はどこから？'] }
    // plan-split: 判定は plan だったが調査で大きいと分かった / child-split: サブ issue のプランが再分割を求める（blocked になる）
    if ((sc === 'plan-split' || sc === 'child-split') && v === '1') return { status: 'split', subIssues: [{ n: Number(n) * 100 + 1, after: [] }], summary: '調査で 600 行と分かった' }
    if (sc === 'replan-question' && (label.includes('revise') || Number(v) >= 2)) return { status: 'question', questions: ['逸脱の代案はどちらにするか'] }
    return { status: 'plan', file: `${PLANS}/${n}-v${v || 'next'}.md`, summary: `v${v}${opts.effort ? ` (effort ${opts.effort})` : ''}` }
  }
  if (t === 'issue-plan-reviewer') {
    if (sc === 'needs-user') return { verdict: 'NEEDS_USER', must: 0, should: 0, nit: 0, questions: ['A 案と B 案のどちらか'] }
    if (sc === 'replan-reject' && r >= 2) return { verdict: 'REQUEST CHANGES', must: 1, should: 0, nit: 0, headings: ['逸脱の解き方が受け入れ条件を満たさない'] }
    const rounds = sc === 'plan2' ? 2 : sc === 'escalate' ? 4 : sc === 'plan-stall' ? 99 : 1
    const ok = r >= rounds || ((sc === 'deviation' || sc === 'design-must') && r >= 2) || sc === 'planurl-deviation'
    return ok ? { verdict: 'APPROVE', must: 0, should: 0, nit: 1, postUrl: `https://example/issue/${n}#plan-r${r}` } : { verdict: 'REQUEST CHANGES', must: 1, should: 1, nit: 0, headings: ['x'] }
  }
  if (t === 'issue-implementer') {
    if (label.startsWith('Rebase')) return { status: 'rebased', head: `head-${n}-rebased`, ciPassed: true }
    if (sc === 'ci-fail') return { status: 'pr', pr: Number(n) + 1000, prUrl: `https://example/pr/${Number(n) + 1000}`, head: `head-${n}-1`, ciPassed: false, reason: 'test が fail' }
    if (label.startsWith('Fix')) return sc === 'fix-blocked' ? { status: 'blocked', reason: '指摘がプランと矛盾する' } : { status: 'fixed', commentUrl: `https://example/pr/${n}#fix-${label}`, head: `head-${n}-fixed-${r}`, ciPassed: true }
    if (sc === 'null') return null
    if (sc === 'impl-blocked') return { status: 'blocked', reason: 'テスト用の DB が立たない' }
    if (['deviation', 'planurl-deviation', 'replan-reject', 'replan-question'].includes(sc) && !label.includes('続き')) return { status: 'deviation', reportFile: `${PLANS}/${n}-deviation.md`, reason: '関数が無い' }
    return { status: 'pr', pr: Number(n) + 1000, prUrl: `https://example/pr/${Number(n) + 1000}`, head: `head-${n}-1`, ciPassed: true }
  }
  if (t === 'issue-pr-reviewer') {
    if (sc === 'pr-needs-user') return { verdict: 'NEEDS_USER', must: 0, should: 0, nit: 0, commentUrl: `https://example/pr#needs-user`, questions: ['エラーを握るか落とすか'] }
    const approveAt = ['pr2', 'design-must', 'null-fix', 'fix-blocked'].includes(sc) ? 2 : 1
    const inGate = opts.phase === '最終確認'
    if (inGate || r >= approveAt) return { verdict: 'APPROVE', must: 0, should: 0, nit: 0, commentUrl: `https://example/pr#approve-r${r}` }
    return { verdict: 'REQUEST CHANGES', must: 1, should: 0, nit: 0, commentUrl: `https://example/pr#review-r${r}`, designMust: sc === 'design-must' }
  }
  if (t === 'issue-final-gate') {
    if (sc === 'gate-needs-user') return { verdict: 'NEEDS_USER', must: 0, should: 0, nit: 0, commentUrl: `https://example/pr#gate-needs-user`, questions: ['受け入れ条件の解釈が 2 通りある'] }
    const ok = sc !== 'gate' || r >= 2
    return ok ? { verdict: 'APPROVE', must: 0, should: 0, nit: 0, commentUrl: `https://example/pr#gate-${r}` } : { verdict: 'REQUEST CHANGES', must: 1, should: 0, nit: 0, commentUrl: `https://example/pr#gate-${r}` }
  }
  if (t === 'issue-merger') {
    if (sc === 'conflict' && !label.includes('retry')) return { status: 'conflict', problem: 'CONFLICTING' }
    if (sc === 'not-ready' && !label.includes('recheck')) return { status: 'not_ready', problem: 'mergeable が UNKNOWN' }
    if (sc === 'not-ready-twice') return { status: 'not_ready', problem: 'CI が fail' }
    return { status: 'merged', sha: `merged-${n}`, issueClosed: true }
  }
  throw new Error(`fake: 未知のエージェント型（${label}）`)
}

// --- 実行 -------------------------------------------------------------------
log(`${a.issues.length} 件の issue を、同時 ${WINDOW} 件で進める（土台 ${a.base}${dry ? '、dry run' : ''}）`)
const results = await Promise.all(a.issues.map(async (issue, idx) => {
  const res = await runIssue(issue, idx)
  done.get(String(issue.n)).resolve(res)
  return res
}))
const count = (s) => results.filter((r) => r.status === s).length
log(`merged ${count('merged')} / split ${count('split')} / blocked ${count('blocked')} / stalled ${count('stalled')} / failed ${count('failed')}`)
return { base: a.base, results }
