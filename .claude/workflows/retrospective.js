export const meta = {
  name: 'retrospective',
  description: '実行の「まとめ」の学びを集めて改善の issue を 1 本起票し、fable がそれを精査して実装し PR を作る',
  phases: [
    { title: '集計' },
    { title: 'ふりかえり' },
    { title: '精査と実装', detail: 'issue-retro-implementer（fable）が起票された issue の主張を裏取りし、直すべきものを実装して PR を作る。マージはしない' },
  ],
  whenToUse: 'スキル issue-workflow の「結果の処理」で、実行の後に args を組み立ててから呼ぶ',
}

// ---------------------------------------------------------------------------
// args の契約（スキル issue-workflow の「結果の処理」で組み立てる）
//   runs:       journal の絶対パスの配列（mtime の昇順）。表示と起票する issue の根拠にだけ使う
//   events:     { "<runs[i] と同じパス>": [<抽出済みの result イベント>...] }。journal の中身はここで渡す
//               各要素は { label, phase, status?, tier?, pr?, implementedBy?, verdict?, must?, should?, nit?, designMust?, lessons?, sha?, conditions? }
//               作り方はスキル issue-workflow の「実行の後: ふりかえり」の jq（started と result を key で突き合わせ、result だけを抽出する）
//   since:      集計の対象期間の起点（表示にだけ使う。run の選別はスキル側が journal の mtime で行う）
//   observations: [string]。空でない文字列。セッションが実行の外で観察した学び（ユーザーの指示を含む）。events の label の形に
//               合わないものは集計に入らないので、ここで自由形式のまま渡し、ふりかえりの依頼文に「セッションの観察」として添える
//   base:       起票する issue に書く、この実行の土台にした origin/main の SHA
//   scratchpad: このセッションのスクラッチパッドの絶対パス
//   repoDir:    ユーザーの作業ツリー（このリポジトリの clone）の絶対パス。`git rev-parse --show-toplevel` で取る
//   trailers:   { coAuthoredBy, claudeSession, sessionUrl }
//   dryRun:     true を渡すとエージェントを立てずに集計だけ返す
//   retroIssue: { number, url, decisions?: [string] }。blocked で返った精査と実装を、ユーザーの決定を添えて再開する。
//               集計と起票は飛ばし、精査と実装だけを回す（runs / events / since は要らない）
// 返り値: 集計と、起票した issue（issueNumber など）と、implementation（精査と実装の結果。status は pr / rejected / blocked）
// ---------------------------------------------------------------------------

const REPO = 'neverclear86/nostr-no-su'
const TIERS = ['none', 'light', 'full']

const a = args || {}
if (typeof a !== 'object') throw new Error('args はオブジェクトで渡す')
for (const k of ['scratchpad', 'trailers', 'base', 'repoDir']) if (a[k] === undefined) throw new Error(`args.${k} が無い`)
if (typeof a.repoDir !== 'string' || !a.repoDir.startsWith('/')) throw new Error('args.repoDir はユーザーの作業ツリーの絶対パスで渡す（git rev-parse --show-toplevel）')
const REPO_DIR = a.repoDir
// blocked の再開。集計に要る args は検査しない
const reentry = a.retroIssue && typeof a.retroIssue === 'object' ? a.retroIssue : null
if (reentry) {
  if (!Number.isInteger(reentry.number) || typeof reentry.url !== 'string') throw new Error('args.retroIssue は { number, url, decisions? } で渡す')
} else {
  if (!Array.isArray(a.runs) || a.runs.length === 0) throw new Error('args.runs が空である')
  if (typeof a.events !== 'object' || a.events === null) throw new Error('args.events がオブジェクトでない')
  if (a.since === undefined) throw new Error('args.since が無い')
  for (const p of a.runs) if (!Array.isArray(a.events[p])) throw new Error(`args.events に ${p} の抽出結果が無い（スキル issue-workflow の「実行の後: ふりかえり」の jq で作る）`)
  if (a.observations !== undefined && (!Array.isArray(a.observations) || !a.observations.every((o) => typeof o === 'string' && o.trim() !== ''))) throw new Error('args.observations は空でない文字列の配列で渡す')
}
const observations = a.observations || []
const dry = a.dryRun === true

// --- スキーマ -----------------------------------------------------------
const S = {
  retro: {
    type: 'object',
    properties: {
      issueNumber: { type: 'integer' },
      issueUrl: { type: 'string' },
      adopted: { type: 'integer', description: '定義に足す 1〜3 行にした件数' },
      scriptChanges: { type: 'integer', description: 'dev/ のスクリプトの変更にした件数' },
      rejected: { type: 'integer', description: '採らなかった件数' },
      reason: { type: 'string', description: '起票しなかったときの理由' },
    },
    required: ['adopted', 'scriptChanges', 'rejected'],
  },
  impl: {
    type: 'object',
    properties: {
      status: { type: 'string', enum: ['pr', 'rejected', 'blocked'] },
      pr: { type: 'integer' },
      prUrl: { type: 'string' },
      head: { type: 'string' },
      ciPassed: { type: 'boolean' },
      commentUrl: { type: 'string', description: 'rejected / blocked のとき、issue に投稿した「## 精査」の URL' },
      reason: { type: 'string', description: 'rejected の理由' },
      questions: { type: 'array', items: { type: 'string' }, description: 'blocked のときの論点' },
    },
    required: ['status'],
  },
}

/**
 * エージェントの label を { kind, n, round } に分解する。
 * kind は triage / plan / planReview / implement / prReview / gate / merge / skip / other で、
 * skip はどの値にも寄与しない既知の label（Fix / Fix conditions / Rebase / Design / Lookup）、other は形に合わない label である。
 * n は issue 番号か PR 番号（prReview / gate / merge は PR 番号のまま返し、collectRun が pr → issue の表で引き直す）。
 */
function parseLabel(label) {
  let m
  if ((m = label.match(/^Triage #(\d+)$/))) return { kind: 'triage', n: Number(m[1]), round: null }
  if ((m = label.match(/^Plan #(\d+)(?: v\d+| revise \d+)$/))) return { kind: 'plan', n: Number(m[1]), round: null }
  if ((m = label.match(/^Review plan #(\d+) r(\d+)$/))) return { kind: 'planReview', n: Number(m[1]), round: Number(m[2]) }
  if ((m = label.match(/^Implement #(\d+)(?: \(続き.*\))?$/))) return { kind: 'implement', n: Number(m[1]), round: null }
  if ((m = label.match(/^PR review #(\d+) r(\d+)$/))) return { kind: 'prReview', n: Number(m[1]), round: Number(m[2]) }
  if ((m = label.match(/^Final gate PR #(\d+)(?: r(\d+))?$/))) return { kind: 'gate', n: Number(m[1]), round: Number(m[2] || 1) }
  if ((m = label.match(/^Merge PR #(\d+)(?: \((?:re-review|(?:re-review, )?retry \d+(?: recheck)?)\))?$/))) return { kind: 'merge', n: Number(m[1]), round: null }
  if (/^(Fix( conditions)? PR #|Rebase PR #|Design #|Lookup #)/.test(label)) return { kind: 'skip', n: null, round: null }
  return { kind: 'other', n: null, round: null }
}

// PR 番号だけを持つ kind。issue 番号への引き直しが要る
const VIA_PR = new Set(['prReview', 'gate', 'merge'])
// issue 番号を直接持つ kind。集計の対象にする（plan は値には寄与しないが、触れた issue として記録する）
const DIRECT = new Set(['triage', 'plan', 'planReview', 'implement'])

/**
 * 1 本の run の抽出済みイベントから issue ごとの記録を Map<issue 番号, 記録> にし、label が形に合わず集計に入らなかった
 * イベントの件数（unknown）と一緒に返す（黙って捨てると、セッションが足した観察が集計から消える）。
 * PR 番号しか持たない label は Implement の結果で issue 番号に引き直す（pr → issue の表は
 * 呼び出し側から受け取り、run をまたいで合併できるようにその場で更新する）。
 * どの行も、源になる result がその run に 1 件も無ければ未設定のまま返す（既定は aggregate が全 run の合併の後に埋める）。
 *
 * | 値 | 導出 |
 * | --- | --- |
 * | tier | Triage の結果の tier |
 * | planRounds | Review plan の round の最大 |
 * | prRounds | PR review の round の最大 |
 * | prConditionCount | すべての PR review の verdict: 'APPROVE' の conditions の合計（phase で絞らない） |
 * | implMusts | phase が 'PR レビュー' の PR review で、verdict: 'REQUEST CHANGES' かつ designMust が真でないものの must の合計 |
 * | lessons | 最初の Final gate の verdict: 'APPROVE' の lessons（rebase の差分の再確認の APPROVE は lessons を返さないので、後の APPROVE で上書きしない） |
 * | status | その PR の Merge の result のいずれかに status: 'merged' があれば 'merged'、無ければ 'unfinished' |
 * | pr | Implement の結果の pr |
 * | implementedBy | Implement の結果の implementedBy（devin か claude。無ければ claude） |
 *
 * 同じ label が 2 回以上あれば先のものを採る（後のものを採ると、再開で走り直した結果に上書きされる）。
 * Merge だけは retry で label が変わるので、複数の label の「いずれか」が merged なら merged とする。
 */
function collectRun(events, prToIssue) {
  const seenLabels = new Set()
  const dedup = events.filter((ev) => (seenLabels.has(ev.label) ? false : (seenLabels.add(ev.label), true)))

  // Implement の結果から pr → issue の表を更新する（呼び出し側の Map をそのまま使い、run をまたいで合併する）
  for (const ev of dedup) {
    const { kind, n } = parseLabel(ev.label)
    if (kind === 'implement' && ev.pr) prToIssue.set(ev.pr, n)
  }

  const issues = new Map()
  const get = (n) => {
    if (!issues.has(n)) issues.set(n, { n })
    return issues.get(n)
  }
  let dropped = 0
  let unknown = 0
  for (const ev of dedup) {
    const { kind, n, round } = parseLabel(ev.label)
    if (kind === 'other') { unknown++; log(`collectRun: label が形に合わないので集計に入れない: ${ev.label}`); continue }
    if (!DIRECT.has(kind) && !VIA_PR.has(kind)) continue // Fix / Fix conditions / Rebase / Design / Lookup はどの値にも寄与しない
    const issueN = VIA_PR.has(kind) ? prToIssue.get(n) : n
    if (issueN === undefined) { dropped++; continue }
    const rec = get(issueN)
    if (kind === 'triage') { if (ev.tier) rec.tier = ev.tier }
    else if (kind === 'implement') { if (ev.pr) rec.pr = ev.pr; if (ev.implementedBy) rec.implementedBy = ev.implementedBy }
    else if (kind === 'planReview') { rec.planRounds = Math.max(rec.planRounds || 0, round) }
    else if (kind === 'prReview') {
      rec.prRounds = Math.max(rec.prRounds || 0, round)
      if (ev.verdict === 'APPROVE') rec.prConditionCount = (rec.prConditionCount || 0) + (ev.conditions || 0)
      if (ev.phase === 'PR レビュー' && ev.verdict === 'REQUEST CHANGES' && !ev.designMust) rec.implMusts = (rec.implMusts || 0) + (ev.must || 0)
    } else if (kind === 'gate') {
      if (ev.verdict === 'APPROVE' && rec.lessons === undefined) rec.lessons = ev.lessons || []
    } else if (kind === 'merge') {
      if (ev.status === 'merged') rec.status = 'merged'
    }
  }
  if (dropped) log(`collectRun: PR 番号を issue 番号に引けなかったイベントを ${dropped} 件捨てた`)
  return { issues, unknown }
}

/**
 * 全 run をまとめる。run ごとの記録を 1 つの表にし、tier 別の件数、ラウンド数と条件の平均、
 * 実装起因の must の合計、学びの件数、label が形に合わず集計に入らなかった件数（unknownLabels）を出す。runs は mtime の昇順で渡される前提。
 */
function aggregate(runs, events) {
  const issues = new Map() // issue 番号 → 記録
  const prToIssue = new Map() // pr → issue 番号。collectRun 側で run をまたいで更新される
  let unknownLabels = 0
  for (const path of runs) {
    const { issues: run, unknown } = collectRun(events[path], prToIssue)
    unknownLabels += unknown
    for (const [n, rec] of run) {
      // その run で値が定まった項目だけを上書きする（丸ごと置き換えると再開の run で飛ばされた値が潰れる）
      issues.set(n, { ...(issues.get(n) || { n }), ...rec })
    }
  }
  // 全 run の合併の後に既定を埋める
  for (const rec of issues.values()) {
    rec.tier = rec.tier || 'light'
    rec.implementedBy = rec.implementedBy || 'claude'
    rec.planRounds = rec.planRounds || 0
    rec.prRounds = rec.prRounds || 0
    rec.prConditionCount = rec.prConditionCount || 0
    rec.implMusts = rec.implMusts || 0
    rec.status = rec.status === 'merged' ? 'merged' : 'unfinished'
  }

  const list = [...issues.values()]
  const merged = list.filter((i) => i.status === 'merged')
  const round2 = (x) => Math.round(x * 100) / 100
  const avg = (key) => (merged.length ? round2(merged.reduce((s, i) => s + (i[key] || 0), 0) / merged.length) : 0)
  const byTier = TIERS.reduce((acc, t) => { acc[t] = list.filter((i) => i.tier === t).length; return acc }, {})
  const byImplementer = ['claude', 'devin'].reduce((acc, t) => { acc[t] = list.filter((i) => i.implementedBy === t).length; return acc }, {})
  const totals = {
    runCount: runs.length,
    byTier,
    byImplementer,
    planRoundsAvg: avg('planRounds'),
    prRoundsAvg: avg('prRounds'),
    conditionAvg: avg('prConditionCount'),
    implMusts: list.reduce((s, i) => s + (i.implMusts || 0), 0),
    lessonCount: list.reduce((s, i) => s + (i.lessons || []).length, 0),
    merged: merged.length,
    unfinished: list.length - merged.length,
    unknownLabels,
  }
  return { issues: list, totals }
}

/** 集計の要約を、起票する issue の冒頭にそのまま貼る Markdown の表にする */
function summaryMarkdown(totals, since) {
  const tierRow = TIERS.map((t) => `${t} ${totals.byTier[t]}`).join(' / ')
  const implRow = ['claude', 'devin'].map((t) => `${t} ${totals.byImplementer[t]}`).join(' / ')
  return `| 項目 | 値 |
| --- | --- |
| 対象期間 | ${since} 以降 |
| run 数 | ${totals.runCount} |
| マージ件数 | ${totals.merged}（未完了 ${totals.unfinished}） |
| tier 別の件数 | ${tierRow} |
| 実装者別の件数 | ${implRow} |
| プランと PR レビューのラウンド数の平均 | プラン ${totals.planRoundsAvg} / PR ${totals.prRoundsAvg} |
| 条件の平均 | ${totals.conditionAvg} |
| 実装起因の must の合計 | ${totals.implMusts} |
| 学びの件数 | ${totals.lessonCount} |
| label が形に合わず集計に入らなかった events | ${totals.unknownLabels} |

- run の選別は journal の mtime による（\`since\` より前に始まって後に終わった run は丸ごと含まれる）
- tier は判定の result からだけ取る。\`args.issues[].tier\` で固定した分とサブ issue は journal に出ないので light として数える
- 集計に入らなかった events は \`log\` に label が出る`
}

/** journal のパスから run id（`wf_*` のディレクトリ名）を取る。取れないパスはそのまま返す */
function runId(path) {
  const m = path.match(/wf_[^/]+/)
  return m ? m[0] : path
}

// --- 依頼文 -----------------------------------------------------------------
const P = {
  // 集計の表と学びの一覧に、dev/wfstats.py の実測（--brief）を issue に貼る指示を添える。run id は runs のパスから取る。
  // セッションの観察（args.observations）は学びと同じ扱いで分類させる
  retro: (agg, table, runs) => {
    const lessonList = agg.issues
      .filter((i) => (i.lessons || []).length)
      .map((i) => `#${i.n}\n${i.lessons.map((l) => `- ${l}`).join('\n')}`)
      .join('\n\n')
    const stats = `python3 ${REPO_DIR}/dev/wfstats.py --runs ${runs.map(runId).join(',')} --brief`
    return `実行の「まとめ」で集まった学びを分類し、改善の issue を 1 本起票してほしい。対象のリポジトリは ${REPO}。

${table}

### 学び
${lessonList || '（無し）'}
${observations.length ? `
### セッションの観察（実行の外でセッションが観察した学び。ユーザーの指示を含む。学びと同じ基準で分類する）
${observations.map((o) => `- ${o}`).join('\n')}
` : ''}
- 実測: \`${stats}\` を実行し、その出力を起票する issue の集計の表の直後に「## 実測（wfstats）」として貼る
- 根拠にした run: ${runs.map((r) => `\`${r}\``).join('、')}
- 土台: origin/main の ${a.base}
- コミットのトレーラー: ${a.trailers.coAuthoredBy} / ${a.trailers.claudeSession}
- 起票する issue の本文の書き先: ${a.scratchpad}/retro-issue.md
返答（構造化出力）: issueNumber、issueUrl、adopted、scriptChanges、rejected。起票しなかったときは issueNumber を省いて reason に理由を書く。`
  },
  // 起票された issue の精査と実装。作業ツリーとブランチは issue 番号で決める（issue-workflow の実装エージェントと同じ流儀）。
  // decisions は blocked の再開でユーザーが決めた論点の答え
  impl: (n, url, decisions) => {
    const wt = `${a.scratchpad}/wt-retro-${n}`
    const branch = `retro/${n}`
    return `ふりかえりで起票された issue #${n}（${url}）を精査し、直すべきものなら実装して PR を作ってほしい。対象のリポジトリは ${REPO}。
- 土台: origin/main の ${a.base}
- 作業ツリー: ${wt}、ブランチ: ${branch}（無ければ \`git -C ${REPO_DIR} fetch origin main && git -C ${REPO_DIR} worktree add -b ${branch} ${wt} origin/main\` で作る。ブランチがすでに origin にあれば、それを取り出して続きから進める）
- コミットのトレーラー: ${a.trailers.coAuthoredBy} / ${a.trailers.claudeSession}
- PR 本文の末尾の生成表記: 🤖 Generated with [Claude Code](https://claude.com/claude-code) と、その次の行に ${a.trailers.sessionUrl}
- PR 本文と issue のコメントの下書きの置き場: ${a.scratchpad}/retro-${n}-*.md
${decisions && decisions.length ? `- 前回の精査で blocked にした論点へのユーザーの決定（これに従って実装する）:\n${decisions.map((d) => `  - ${d}`).join('\n')}\n` : ''}issue の主張は定義の「精査」の手順で裏を取ってから直す。マージと \`gh pr review\` はしない。
返答（構造化出力）: status（pr / rejected / blocked）。pr のときは pr、prUrl、head、ciPassed。rejected のときは commentUrl と reason。blocked のときは commentUrl と questions。`
  },
}

/** 起票された issue を issue-retro-implementer に精査・実装させ、結果（status は pr / rejected / blocked）を返す */
async function implement(n, url, decisions) {
  log(`issue #${n} を精査して実装する${decisions && decisions.length ? `（ユーザーの決定 ${decisions.length} 件つき）` : ''}`)
  const impl = await agent(P.impl(n, url, decisions), { label: `Retro implement #${n}`, agentType: 'issue-retro-implementer', phase: '精査と実装', schema: S.impl })
  if (!impl) throw new Error(`Retro implement #${n} が結果を返さなかった`)
  log(`精査と実装: ${impl.status}${impl.status === 'pr' ? `（PR #${impl.pr}）` : ''}`)
  return impl
}

// --- 実行 -------------------------------------------------------------------
if (reentry) {
  log(`blocked の再開: issue #${reentry.number}（集計と起票は飛ばす）${dry ? '（dry run）' : ''}`)
  if (dry) return { issueNumber: reentry.number, issueUrl: reentry.url, implementation: null, reason: 'dry run' }
  return { issueNumber: reentry.number, issueUrl: reentry.url, implementation: await implement(reentry.number, reentry.url, reentry.decisions || []) }
}

log(`${a.runs.length} 件の journal から集計する${dry ? '（dry run）' : ''}`)
const agg = aggregate(a.runs, a.events)
log(`issue ${agg.issues.length} 件、merged ${agg.totals.merged} / unfinished ${agg.totals.unfinished}、学び ${agg.totals.lessonCount} 件、セッションの観察 ${observations.length} 件`)

// 学びが 0 件でもセッションの観察があれば、観察だけを材料にふりかえりを立てる（観察を黙って落とさない）
if (dry || (agg.totals.lessonCount === 0 && observations.length === 0)) {
  log(dry ? 'dry run なので集計だけ返す' : '学びもセッションの観察も 0 件なので issue を起票しない')
  return { ...agg, issueNumber: null, reason: dry ? 'dry run' : '学びも観察も 0 件', implementation: null }
}

const table = summaryMarkdown(agg.totals, a.since)
const retro = await agent(P.retro(agg, table, a.runs), { label: 'Retrospective', agentType: 'issue-retrospective', phase: 'ふりかえり', schema: S.retro })
if (!retro) throw new Error('Retrospective が結果を返さなかった')
if (!retro.issueNumber) {
  log(`issue を起票しなかった: ${retro.reason || '理由なし'}`)
  return { ...agg, ...retro, implementation: null }
}

return { ...agg, ...retro, implementation: await implement(retro.issueNumber, retro.issueUrl, []) }
