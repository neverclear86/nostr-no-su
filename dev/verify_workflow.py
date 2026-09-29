#!/usr/bin/env python3
"""導入した issue-workflow.js を、エージェントを立てずに dry run の全シナリオで回し、期待する結果と突き合わせる。

モジュール（CONFIG.modules）の有無は、スクリプトの CONFIG から読むか、--modules で上書きする（dry run の
args.modules に渡す）。期待する status はモジュールの有無から決め、あわせて次の不変条件を確かめる。
  - gate が無ければ label に「Final gate」が出ない。design が無ければ「Design」が出ない
  - retro が無ければ、merged の結果の lessons が空。gate が無く retro があれば、PR レビューの学びが残る
  - split が無ければ、分割のシナリオは split にならずに blocked で返る
  - 依存の連鎖で、依存する issue の base が依存先のマージのコミットになる
  - ports が false なら portBase の無い args で動く
  - Sonnet の振り分け（学びの表の L044）: dryRunModels の trace で、段階ごとの model と effort の上書きが期待どおりか

使い方:
  python3 verify_workflow.py <issue-workflow.js> [--modules split=false,gate=false] [--dryrun <dryrun.mjs>] [--verbose]
結果は Markdown の表で標準出力に出し、1 件でも外れれば終了コード 1 で終わる。
"""
import argparse, json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
MODS = ['split', 'design', 'gate', 'ci', 'retro', 'screenshots']


def read_config(src):
    """スクリプトの CONFIG から modules と ports を読む（true / false のリテラルだけを見る）。"""
    mods = {}
    for m in MODS:
        hit = re.search(rf'^\s+{m}: (true|false),', src, re.M)
        if not hit:
            sys.exit(f'CONFIG.modules.{m} が true / false で埋まっていない')
        mods[m] = hit.group(1) == 'true'
    mb = re.search(r'^\s+mergeBuild: (true|false),', src, re.M)
    mods['mergeBuild'] = bool(mb) and mb.group(1) == 'true'
    hit = re.search(r'^\s+ports: (true|false),', src, re.M)
    if not hit:
        sys.exit('CONFIG.ports が true / false で埋まっていない')
    if '{{' in src:
        sys.exit('埋め残しの {{...}} がある: ' + ', '.join(sorted(set(re.findall(r'\{\{[A-Z_]+\}\}', src)))))
    return mods, hit.group(1) == 'true'


def cases(mods):
    """(名前, dryRun, issues の組み立て, 期待する status の列, 追加の検査) の列。期待値はモジュールの有無で決まる。"""
    split_or_blocked = 'split' if mods['split'] else 'blocked'
    one = lambda **kw: [{'n': 1, 'branch': 'x', 'ui': True, **kw}]
    return [
        ('happy', {'1': 'happy'}, one(), ['merged'], None),
        ('tier-none', {'1': 'tier-none'}, one(), ['merged'], None),
        ('tier-none-design-must', {'1': 'tier-none-design-must'}, one(), ['merged'], None),
        ('tier-none-deviation', {'1': 'tier-none-deviation'}, one(), ['merged'], None),
        ('pr-conditions', {'1': 'pr-conditions'}, one(), ['merged'], None),
        ('approve-with-conditions', {'1': 'approve-with-conditions'}, one(), ['merged'], None),
        ('plan2', {'1': 'plan2'}, one(), ['merged'], None),
        ('plan-stall', {'1': 'plan-stall'}, one(), ['stalled'], None),
        ('prev-plan', {'1': 'prev-plan'}, one(prevPlan='/tmp/p/plans/1-v2.md', prevReview='/tmp/p/1-r2.md'), ['merged'],
         lambda r, t: 'Plan #1 v3' in t and 'Plan #1 v1' not in t and 'Triage #1' not in t),
        ('question', {'1': 'question'}, one(), ['blocked'], None),
        ('needs-user', {'1': 'needs-user'}, one(), ['blocked'], None),
        ('pr-needs-user', {'1': 'pr-needs-user'}, one(), ['blocked'], None),
        ('gate-needs-user', {'1': 'gate-needs-user'}, one(), ['blocked' if mods['gate'] else 'merged'], None),
        ('null', {'1': 'null'}, one(), ['failed'], None),
        ('status-only', {'1': 'status-only'}, one(), ['merged'] if mods['ci'] else ['blocked'], None),
        ('null-fix', {'1': 'null-fix'}, one(), ['failed'], None),
        ('impl-blocked', {'1': 'impl-blocked'}, one(), ['blocked'], None),
        ('fix-blocked', {'1': 'fix-blocked'}, one(), ['blocked'], None),
        ('deviation', {'1': 'deviation'}, one(), ['merged'], None),
        ('planurl-deviation', {'1': 'planurl-deviation'}, one(planUrl='https://example/issue/1#plan'), ['merged'], None),
        ('replan-reject', {'1': 'replan-reject'}, one(), ['blocked'], None),
        ('replan-question', {'1': 'replan-question'}, one(), ['blocked'], None),
        ('pr2', {'1': 'pr2'}, one(), ['merged'], None),
        ('pr2-gate', {'1': 'pr2-gate'}, one(), ['merged'], None),
        ('design-must', {'1': 'design-must'}, one(), ['merged'], None),
        ('gate', {'1': 'gate'}, one(), ['merged'], None),
        ('split', {'1': 'split'}, one(), [split_or_blocked], None),
        ('split-parallel', {'1': 'split-parallel'}, one(), [split_or_blocked], None),
        ('split-tier', {'1': 'split-tier'}, one(), [split_or_blocked], None),
        ('triage-question', {'1': 'triage-question'}, one(), ['blocked'], None),
        ('plan-split', {'1': 'plan-split'}, one(), [split_or_blocked], None),
        ('child-split', {'1': 'split', '101': 'child-split'}, one(), [split_or_blocked],
         (lambda r, t: [(c['status'], c['stage']) for c in r[0]['children']] == [('blocked', 'plan'), ('blocked', 'deps')]) if mods['split'] else None),
        ('plan-after', {'2': 'plan-after'}, [{'n': 1, 'branch': 'x'}, {'n': 2, 'branch': 'y'}], ['merged', 'merged'],
         lambda r, t: r[1]['base'] == r[0]['mergeSha']),
        ('ci-fail', {'1': 'ci-fail'}, one(), ['blocked'], None),
        ('conflict', {'1': 'conflict'}, one(), ['merged'], lambda r, t: any(l.startswith('Rebase PR #1001') for l in t)),
        ('merge-build', {'1': 'merge-build'}, one(), ['merged'],
         lambda r, t: any(l.startswith('Rebase PR #1001') for l in t) == mods.get('mergeBuild', False)),
        ('not-ready', {'1': 'not-ready'}, one(), ['merged'], None),
        ('not-ready-twice', {'1': 'not-ready-twice'}, one(), ['stalled'], None),
        ('not-ready-review', {'1': 'not-ready-review'}, one(), ['merged'],
         lambda r, t: t.index('Merge PR #1001 (retry 1)') < t.index('Merge PR #1001 (re-review)')),
        ('not-ready-review-conflict', {'1': 'not-ready-review-conflict'}, one(), ['merged'],
         lambda r, t: 'Merge PR #1001 (re-review, retry 1)' in t),
        ('not-ready-review-reject', {'1': 'not-ready-review-reject'}, one(), ['merged'], None),
        ('not-ready-fix', {'1': 'not-ready-fix'}, one(), ['merged'], None),
        ('chain', {'1': 'happy', '2': 'plan-stall', '3': 'happy'},
         [{'n': 1, 'branch': 'x'}, {'n': 2, 'branch': 'y', 'after': [1]}, {'n': 3, 'branch': 'z', 'after': [2]}],
         ['merged', 'stalled', 'blocked'], lambda r, t: not any('#3' in l for l in t)),
        ('split-dep', {'1': 'split', '102': 'ci-fail', '2': 'happy'},
         [{'n': 1, 'branch': 'x'}, {'n': 2, 'branch': 'y', 'after': [1]}], [split_or_blocked, 'blocked'], None),
        ('tier-fixed', {'1': 'happy'}, one(tier='none'), ['merged'], lambda r, t: 'Triage #1' not in t and not any(l.startswith('Plan') for l in t)),
        ('no-merge', {'1': 'happy'}, one(noMerge=True), ['stalled'], lambda r, t: r[0]['reason'].startswith('noMerge:') and not any(l.startswith('Merge') for l in t)),
        ('cycle', {'1': 'happy', '2': 'happy'}, [{'n': 1, 'branch': 'x', 'after': [2]}, {'n': 2, 'branch': 'y', 'after': [1]}], ['blocked', 'blocked'], None),
    ]


S = ('sonnet', 'high')
O = (None, None)


def model_cases(mods):
    """Sonnet の振り分け（学びの表の L044）の期待値。(名前, dryRun, issues, 追加の args, {label: (model, effort)}, 必ず立つ label)。
    期待値の無い label は O（定義の frontmatter のまま）を期待する。"""
    one = lambda **kw: [{'n': 1, 'branch': 'x', 'ui': True, **kw}]
    gate_fix = ['Fix PR #1001 gate r1'] if mods['gate'] else []
    return [
        # tier light: 版 1、最初の実装、マージが Sonnet。判定・レビュー・最終確認は定義のまま
        ('models-happy', {'1': 'happy'}, one(), {}, {'Plan #1 v1': S, 'Implement #1': S, 'Merge PR #1001': S}, ['Triage #1', 'Plan #1 v1', 'Implement #1', 'Merge PR #1001']),
        # 差し戻された版 2 は Opus に上がる
        ('models-plan2', {'1': 'plan2'}, one(), {}, {'Plan #1 v1': S, 'Implement #1': S, 'Merge PR #1001': S}, ['Plan #1 v2']),
        # tier none の実装は Opus のまま
        ('models-tier-none', {'1': 'tier-none'}, one(), {}, {'Merge PR #1001': S}, ['Implement #1']),
        # tier none の見込み超えで書くプランと続きの実装は Opus
        ('models-tier-none-deviation', {'1': 'tier-none-deviation'}, one(), {}, {'Merge PR #1001': S}, ['Plan #1 v1', 'Implement #1 (続き プラン)']),
        # PR ごとに最初の指摘への対応は Sonnet、2 回目は Opus
        ('models-fixes', {'1': 'pr2-gate'}, one(), {}, {'Plan #1 v1': S, 'Implement #1': S, 'Fix PR #1001 r1': S, 'Merge PR #1001': S}, ['Fix PR #1001 r1'] + gate_fix),
        # 条件の取り込みは Sonnet
        ('models-conditions', {'1': 'pr-conditions'}, one(), {}, {'Plan #1 v1': S, 'Implement #1': S, 'Fix conditions PR #1001': S, 'Merge PR #1001': S}, ['Fix conditions PR #1001']),
        # 最初の rebase は Sonnet
        ('models-rebase', {'1': 'conflict'}, one(), {}, {'Plan #1 v1': S, 'Implement #1': S, 'Rebase PR #1001 (1)': S, 'Merge PR #1001': S, 'Merge PR #1001 (retry 1)': S}, ['Rebase PR #1001 (1)']),
        # PR の検索は Sonnet / low
        ('models-lookup', {'1': 'status-only'}, one(), {}, {'Plan #1 v1': S, 'Implement #1': S, 'Lookup #1': ('sonnet', 'low'), 'Merge PR #1001': S}, ['Lookup #1']),
        # sonnet: false なら上書きは PR の検索の effort だけ
        ('models-off', {'1': 'status-only'}, one(), {'sonnet': False}, {'Lookup #1': (None, 'low')}, ['Plan #1 v1', 'Implement #1', 'Lookup #1']),
    ]


def check_models(mods, trace, expect, must):
    """dryRunModels の trace を期待値と突き合わせ、外れた項目の説明の列を返す。"""
    got = {t['label']: (t['model'], t['effort']) for t in trace}
    bad = [f'{l} が立たない' for l in must if l not in got]
    bad += [f'{l} が {m or "定義"}/{e or "定義"}（期待は {expect.get(l, O)[0] or "定義"}/{expect.get(l, O)[1] or "定義"}）'
            for l, (m, e) in got.items() if (m, e) != expect.get(l, O)]
    return bad


def flat(results):
    out = []
    for r in results:
        out.extend(flat(r.get('children', [])) if r.get('status') == 'split' else [r])
    return out


def invariants(mods, results, trace):
    """モジュールの有無から、どのシナリオでも成り立つべきことを確かめる。外れた項目の説明の列を返す。"""
    bad = []
    if not mods['gate'] and any(l.startswith('Final gate') for l in trace):
        bad.append('gate が無いのに Final gate が立った')
    if not mods['design'] and any(l.startswith('Design') for l in trace):
        bad.append('design が無いのに Design が立った')
    for r in flat(results):
        if r.get('status') != 'merged':
            continue
        if not mods['retro'] and r.get('lessons'):
            bad.append(f"retro が無いのに #{r['n']} に lessons がある")
        if mods['retro'] and not r.get('lessons'):
            bad.append(f"retro があるのに #{r['n']} の lessons が空")
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('script')
    ap.add_argument('--modules', default='')
    ap.add_argument('--dryrun', default=os.path.join(HERE, 'dryrun.mjs'))
    ap.add_argument('--verbose', action='store_true')
    o = ap.parse_args()
    src = open(o.script, encoding='utf-8').read()
    mods, ports = read_config(src)
    override = {}
    for kv in filter(None, o.modules.split(',')):
        k, v = kv.split('=')
        if k not in MODS:
            sys.exit(f'--modules の未知のモジュール: {k}')
        override[k] = v == 'true'
    mods.update(override)
    ng = 0
    print(f"モジュール: {', '.join(f'{k}={str(v).lower()}' for k, v in mods.items())}、ports={str(ports).lower()}\n")
    print('| シナリオ | 期待 | 結果 | 判定 |\n|--|--|--|--|')
    for name, dry, issues, want, extra in cases(mods):
        args = {'issues': issues, 'base': '0000000', 'scratchpad': '/tmp/dry', 'repoDir': '/tmp/dry/repo',
                'trailers': {'coAuthoredBy': 'a', 'claudeSession': 'b', 'sessionUrl': 'c'}, 'dryRun': dry, 'modules': override}
        if ports:
            args['portBase'] = 5600
        p = subprocess.run(['node', o.dryrun, o.script, json.dumps(args), '--quiet'], capture_output=True, text=True)
        if p.returncode:
            ng += 1
            print(f'| {name} | {want} | error | NG: {p.stderr.strip().splitlines()[-1][:120]} |')
            continue
        out = json.loads(p.stdout)['result']
        results, trace = out['results'], out.get('trace', [])
        got = [r['status'] for r in results]
        why = [] if got == want else ['status']
        if extra and got == want:
            try:
                if not extra(results, trace):
                    why.append('追加の検査')
            except (KeyError, ValueError, IndexError) as e:
                why.append(f'追加の検査（{e}）')
        why += invariants(mods, results, trace)
        ng += bool(why)
        print(f"| {name} | {', '.join(want)} | {', '.join(got)} | {'OK' if not why else 'NG: ' + '、'.join(why)} |")
        if o.verbose and why:
            print(f'\n```\n{json.dumps(trace, ensure_ascii=False)}\n```\n')
    print('\n| 振り分け | 判定 |\n|--|--|')
    for name, dry, issues, extra, expect, must in model_cases(mods):
        args = {'issues': issues, 'base': '0000000', 'scratchpad': '/tmp/dry', 'repoDir': '/tmp/dry/repo',
                'trailers': {'coAuthoredBy': 'a', 'claudeSession': 'b', 'sessionUrl': 'c'}, 'dryRun': dry, 'modules': override,
                'dryRunModels': True, **extra}
        if ports:
            args['portBase'] = 5600
        p = subprocess.run(['node', o.dryrun, o.script, json.dumps(args), '--quiet'], capture_output=True, text=True)
        if p.returncode:
            ng += 1
            print(f'| {name} | NG: {p.stderr.strip().splitlines()[-1][:120]} |')
            continue
        why = check_models(mods, json.loads(p.stdout)['result'].get('trace', []), expect, must)
        ng += bool(why)
        print(f"| {name} | {'OK' if not why else 'NG: ' + '、'.join(why)} |")
    print(f'\nNG {ng} 件')
    sys.exit(1 if ng else 0)


if __name__ == '__main__':
    main()
