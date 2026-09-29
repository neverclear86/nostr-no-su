#!/usr/bin/env node
// Workflow ツールのスクリプト（issue-workflow.js / retrospective.js）を、agent() を立てずに node で実行する。
// スクリプトの dry run（args.dryRun）は agent() を呼ばずに fake() で結果を作るので、ここでは agent() を
// 呼ばれたら失敗にする。log() は標準エラーに、戻り値は JSON で標準出力に出す。
// Workflow ツールと同じく、Date.now()・Math.random()・引数の無い new Date() は例外にする。
//
// 使い方: node dryrun.mjs <スクリプト> <args の JSON ファイル | JSON 文字列> [--quiet]
import { readFileSync } from 'node:fs'

const [, , scriptPath, argsSpec, ...rest] = process.argv
if (!scriptPath || !argsSpec) {
  console.error('usage: node dryrun.mjs <script.js> <args.json | JSON> [--quiet]')
  process.exit(2)
}
const quiet = rest.includes('--quiet')
const src = readFileSync(scriptPath, 'utf8')
const args = JSON.parse(argsSpec.trim().startsWith('{') ? argsSpec : readFileSync(argsSpec, 'utf8'))

// meta は純粋なリテラルでなければならない（Workflow ツールの制約）。変数や関数呼び出しが混ざっていないかを粗く見る
const metaMatch = src.match(/^export const meta = (\{[\s\S]*?\n\});?\n/m)
if (!metaMatch) { console.error('meta が見つからない（export const meta = {...} で始める）'); process.exit(2) }
// 文字列リテラル（'…'、"…"）の中身を剥がしてから、テンプレート文字列・スプレッド・関数呼び出しが無いかを見る
const bare = metaMatch[1].replace(/'(?:[^'\\\n]|\\.)*'/g, "''").replace(/"(?:[^"\\\n]|\\.)*"/g, '""')
if (/`|\.\.\.|\w\s*\(/.test(bare)) { console.error('meta が純粋なリテラルでない'); process.exit(2) }

const body = src.replace(/^export const meta = /m, 'const meta = ')
const logs = []
const log = (m) => { logs.push(String(m)); if (!quiet) console.error(`[log] ${m}`) }
const agent = async (_prompt, opts) => { throw new Error(`dry run なのに agent() が呼ばれた（${opts && opts.label}）`) }
const phase = () => {}
const RealDate = Date
class GuardDate extends RealDate {
  constructor(...a) { if (a.length === 0) throw new Error('new Date() は Workflow のスクリプトで使えない'); super(...a) }
  static now() { throw new Error('Date.now() は Workflow のスクリプトで使えない') }
}
const guardMath = Object.create(Math)
guardMath.random = () => { throw new Error('Math.random() は Workflow のスクリプトで使えない') }

const fn = new Function('args', 'agent', 'log', 'phase', 'Date', 'Math', `return (async () => {\n${body}\n})()`)
try {
  const result = await fn(args, agent, log, phase, GuardDate, guardMath)
  process.stdout.write(JSON.stringify({ result, logs }, null, 2) + '\n')
} catch (err) {
  console.error(`script error: ${err && err.stack || err}`)
  process.exit(1)
}
