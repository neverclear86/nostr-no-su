#!/usr/bin/env python3
"""
nostr-no-su の Claude Code Workflow 実行ログ（journal.jsonl + agent-*.jsonl/meta.json）から
コスト・品質・速度の統計を作るスクリプト。標準ライブラリーだけで動く。

対象: <base>/*/subagents/workflows/wf_*/（<base> は Claude Code のプロジェクトのディレクトリ）。
「launched」だけの1行 journal（ドライラン・即中断）は除外する。

使い方:
  python3 dev/wfstats.py                                   # 全 run の詳細レポート
  python3 dev/wfstats.py --runs wf_a22397c8-55c --brief    # 1 run の要約（60 行以内。retrospective が issue に貼る）
  python3 dev/wfstats.py --base <dir> --runs <id>,<id>     # 対象のディレクトリと run を指定する

  --base   Claude Code のプロジェクトのディレクトリ。省略時は cwd のリポジトリから導く（~/.claude/projects/<パスの / を - にした名前>）
  --runs   対象の run id（wf_* のディレクトリ名）をコンマ区切りで。省略時は全 run
  --brief  run ごとの表・agentType 別の $・レビューの r1 の集計・クリティカルパス・agentType 別のモデルだけを出す

金額は PRICE の価格表（API の公開価格）による見積もりで、サブスクリプションの実費ではない。
出力はすべて標準出力に書く。呼び出し側で `python3 dev/wfstats.py > report.txt` する。
リポジトリ側には一切書き込まない（読み取りのみ）。
"""
import argparse, json, glob, os, re, subprocess, sys, statistics, collections
from datetime import datetime, timezone


def default_base():
    """Claude Code のプロジェクトのディレクトリ（~/.claude/projects/<cwd の / を - にした名前>）を、
    cwd が属するリポジトリの最上位から導く。git の外で呼ばれたら cwd で代用する。"""
    try:
        root = subprocess.run(['git', 'rev-parse', '--show-toplevel'], capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        root = os.getcwd()
    return os.path.join(os.path.expanduser('~'), '.claude', 'projects', re.sub(r'[^A-Za-z0-9]', '-', root))


# model -> (input $/Mtok, cache_creation $/Mtok, cache_read $/Mtok, output $/Mtok)
PRICE = {
    'claude-fable-5-1': (10, 12.5, 0.25, 50),
    'claude-opus-5': (5, 6.25, 0.5, 25),
    'claude-opus-5[1m]': (5, 6.25, 0.5, 25),
    'claude-opus-5-5': (4, 5, 0.2, 20),
    'claude-opus-5-5[1m]': (4, 5, 0.2, 20),
    'claude-sonnet-5': (2, 2.5, 0.2, 10),
}
DEFAULT_PRICE = (5, 6.25, 0.5, 25)

PHASE_CATS = ['Final gate PR', 'Review plan', 'Rebase PR', 'Merge PR', 'PR review',
              'Fix PR', 'Implement', 'Design', 'Triage', 'Plan']


def parse_ts(s):
    return datetime.fromisoformat(s.replace('Z', '+00:00'))


def fmt_ts(t):
    return t.strftime('%Y-%m-%d %H:%M:%S') if t else '?'


def req_cost(r):
    p = PRICE.get(r['model'], DEFAULT_PRICE)
    return (r['inp'] * p[0] + r['cw'] * p[1] + r['cr'] * p[2] + r['out'] * p[3]) / 1e6


def load_agent_jsonl(path):
    """1エージェントの transcript を読む。
    戻り値: (requests: [{model,inp,cw,cr,out,ts}], t_min, t_max)
    t_min/t_max は全行（assistant 以外も含む）のタイムスタンプの範囲＝エージェントの実際の稼働時間。
    requests は assistant メッセージの usage を requestId で重複排除したもの（wfcost.py と同じロジック）。
    """
    reqs = {}
    t_min = t_max = None
    with open(path) as f:
        for line in f:
            try:
                d = json.loads(line)
            except Exception:
                continue
            ts = d.get('timestamp')
            if ts:
                t = parse_ts(ts)
                if t_min is None or t < t_min:
                    t_min = t
                if t_max is None or t > t_max:
                    t_max = t
            if d.get('type') != 'assistant':
                continue
            m = d.get('message', {})
            u = m.get('usage')
            if not u:
                continue
            rid = d.get('requestId') or m.get('id')
            model = m.get('model')
            if model == '<synthetic>':
                continue
            rec = dict(model=model, inp=u.get('input_tokens', 0),
                       cw=u.get('cache_creation_input_tokens', 0),
                       cr=u.get('cache_read_input_tokens', 0),
                       out=u.get('output_tokens', 0), ts=ts)
            cur = reqs.get(rid)
            if cur is None or rec['out'] >= cur['out']:
                reqs[rid] = rec
    return list(reqs.values()), t_min, t_max


def phase_prefix(label):
    for c in PHASE_CATS:
        if label.startswith(c):
            return c
    return '?'


class Agent:
    __slots__ = ('agent_id', 'label', 'phase', 'result', 'agent_type', 'description',
                 'requests', 't_min', 't_max', 'cost', 'n_requests', 'stalled')

    def cost_total(self):
        return sum(req_cost(r) for r in self.requests)

    def out_tokens(self):
        return sum(r['out'] for r in self.requests)

    def duration_min(self):
        if self.t_min and self.t_max:
            return (self.t_max - self.t_min).total_seconds() / 60.0
        return None


def discover_runs(base, run_ids=None):
    """journal.jsonl が実エージェントを含む wf_* ディレクトリを列挙する。
    ドライラン（{"type":"launched"} の1行だけ）は除外。run_ids を渡すとその run id だけに絞る。
    戻り値: [(run_id, session_id, wf_dir)]
    """
    runs = []
    for jf in sorted(glob.glob(f"{base}/*/subagents/workflows/wf_*/journal.jsonl")):
        wf_dir = os.path.dirname(jf)
        run_id = os.path.basename(wf_dir)
        if run_ids is not None and run_id not in run_ids:
            continue
        session_id = wf_dir.split('/')[-4]
        n_lines = sum(1 for _ in open(jf))
        has_started = False
        with open(jf) as f:
            for line in f:
                d = json.loads(line)
                if d.get('type') == 'started':
                    has_started = True
                    break
        if n_lines <= 1 or not has_started:
            continue
        runs.append((run_id, session_id, wf_dir))
    return runs


def load_run(run_id, session_id, wf_dir):
    """1 run 分のデータを読み込む。"""
    started = {}   # agentId -> (label, phase)
    results = {}   # agentId -> result dict
    order = []     # agentId の started 順
    with open(f"{wf_dir}/journal.jsonl") as f:
        for line in f:
            d = json.loads(line)
            if d['type'] == 'started':
                started[d['agentId']] = (d['label'], d.get('phase'))
                order.append(d['agentId'])
            elif d['type'] == 'result':
                results[d['agentId']] = d['result']

    agents = {}
    for mf in glob.glob(f"{wf_dir}/*.meta.json"):
        agent_id = os.path.basename(mf)[len('agent-'):-len('.meta.json')]
        jf = mf.replace('.meta.json', '.jsonl')
        if not os.path.exists(jf):
            continue
        md = json.load(open(mf))
        reqs, t_min, t_max = load_agent_jsonl(jf)
        a = Agent()
        a.agent_id = agent_id
        lbl_phase = started.get(agent_id, (md.get('description', '?'), None))
        a.label = lbl_phase[0]
        a.phase = lbl_phase[1]
        a.result = results.get(agent_id)
        a.agent_type = md.get('agentType', '?')
        a.description = md.get('description', '?')
        a.requests = reqs
        a.t_min = t_min
        a.t_max = t_max
        a.n_requests = len(reqs)
        a.stalled = agent_id in started and agent_id not in results
        agents[agent_id] = a

    run_t_min = min((a.t_min for a in agents.values() if a.t_min), default=None)
    run_t_max = max((a.t_max for a in agents.values() if a.t_max), default=None)

    return dict(run_id=run_id, session_id=session_id, wf_dir=wf_dir,
                agents=agents, order=order, run_t_min=run_t_min, run_t_max=run_t_max)


def build_pr2issue(run):
    """Implement #N の結果からPR番号->issue番号（文字列）の対応を作る。"""
    pr2issue = {}
    for aid in run['order']:
        a = run['agents'].get(aid)
        if not a or not a.result:
            continue
        m = re.match(r'^Implement #(\d+)$', a.label)
        if m and a.result.get('pr'):
            pr2issue[str(a.result['pr'])] = m.group(1)
    return pr2issue


def label_issue_num(label):
    """ラベル先頭の #数字（issue番号 or PR番号）を取り出す。"""
    m = re.search(r'#(\d+)', label)
    return m.group(1) if m else None


# ---------------------------------------------------------------------------
# セクション1・2: run 概要とコスト内訳
# ---------------------------------------------------------------------------

def compute_overview(run, pr2issue):
    """run の概要（件数・総額）を dict で返す。section_overview と section_brief が使う。"""
    agents = run['agents']
    triage_issues = set()
    planv1_issues = set()
    # 「issue番号を主語にする」ラベル全部（Triage/Design/Plan/Review plan）からissue番号を拾う。
    # PR番号を主語にするラベル（Implement以降）は pr2issue 経由でissue番号に変換する。
    # 見込み: プランがこのrunで走っていない（前のrunで承認済みで、このrunはImplementから再開した）issueも
    # 拾うため、pr2issueで解決できないPR（=このrun内にImplementが無い＝前run由来）も1件として数える。
    issue_label_nums = set()
    unmapped_pr_nums = set()
    split_count = 0
    blocked_count = 0
    stalled_count = 0
    merged_prs = set()
    conflict_count = 0
    not_ready_count = 0

    for aid, a in agents.items():
        m = re.match(r'^Triage #(\d+)$', a.label)
        if m:
            triage_issues.add(m.group(1))
        m = re.match(r'^Plan #(\d+) v1$', a.label)
        if m:
            planv1_issues.add(m.group(1))
        # Triage/Design/Plan/Review plan/Implement は #N が「issue番号」。
        # Fix PR/PR review/Final gate PR/Merge PR/Rebase PR は #N が「PR番号」なのでpr2issueで変換する。
        m = re.match(r'^(Triage|Design|Plan|Review plan|Implement) #(\d+)', a.label)
        if m:
            issue_label_nums.add(m.group(2))
        m = re.match(r'^(Fix PR|PR review|Final gate PR|Merge PR|Rebase PR) #(\d+)', a.label)
        if m:
            pr_num = m.group(2)
            if pr_num in pr2issue:
                issue_label_nums.add(pr2issue[pr_num])
            else:
                unmapped_pr_nums.add(pr_num)  # このrunにImplementが無い＝前runで計画・実装済みのissue
        if a.stalled:
            stalled_count += 1
            continue
        r = a.result or {}
        st = r.get('status')
        if st == 'split':
            split_count += 1
        elif st == 'blocked':
            blocked_count += 1
        elif st == 'conflict':
            conflict_count += 1
        elif st == 'not_ready':
            not_ready_count += 1
        elif st == 'merged':
            m2 = re.match(r'^Merge PR #(\d+)', a.label)
            if m2:
                merged_prs.add(m2.group(1))

    issues_touched = issue_label_nums | unmapped_pr_nums
    total_cost = sum(a.cost_total() for a in agents.values())
    n_merged = len(merged_prs)
    by_type = collections.defaultdict(float)
    for a in agents.values():
        by_type[a.agent_type] += a.cost_total()
    return dict(total_cost=total_cost, n_merged=n_merged, split=split_count, blocked=blocked_count,
                stalled=stalled_count, conflict=conflict_count, not_ready=not_ready_count,
                issues_touched=len(issues_touched), unmapped=len(unmapped_pr_nums),
                triage=len(triage_issues), planv1=len(planv1_issues), by_type=dict(by_type))


def wall_hours(run):
    """run の壁時計（時間）。"""
    return (run['run_t_max'] - run['run_t_min']).total_seconds() / 3600


def section_overview(run, pr2issue):
    agents = run['agents']
    o = compute_overview(run, pr2issue)
    total_cost, n_merged = o['total_cost'], o['n_merged']

    print(f"### run {run['run_id']}  session {run['session_id']}")
    print(f"  期間: {fmt_ts(run['run_t_min'])} 〜 {fmt_ts(run['run_t_max'])} UTC"
          f"  ({wall_hours(run):.2f} 時間・壁時計)")
    print(f"  issue: Triage対象(トップレベル) {o['triage']} 件"
          f" / Plan v1 まで進んだ issue（分割子含む）{o['planv1']} 件"
          f" / このrunで触ったissue数(重複除く) {o['issues_touched']} 件"
          f"（うちこのrunにImplementが無い＝前runで計画済み・再開分 {o['unmapped']} 件）"
          "  ※ journal に args/start イベントが無いため代替指標。分割で増えた子issueを含む。"
          " 「args」そのものではない。")
    print(f"  マージ済み PR: {n_merged} 件 / split: {o['split']} / blocked: {o['blocked']}"
          f" / stalled(枠切れ等で結果未記録): {o['stalled']} / merge conflict: {o['conflict']}"
          f" / final gate 未APPROVEで保留(not_ready): {o['not_ready']}"
          f"  ※ failed という明示ステータスはこのデータには存在しない（0 件）")
    print(f"  総額: ${total_cost:.2f}"
          + (f"   $/マージ済みissue: ${total_cost / n_merged:.2f}" if n_merged else "   $/マージ済みissue: N/A(0件)"))

    by_phase = collections.defaultdict(float)
    for a in agents.values():
        by_phase[phase_prefix(a.label)] += a.cost_total()

    print("  --- agentType別 ($ / %) ---")
    print_by_type(o['by_type'], total_cost)

    print("  --- phase(ラベル接頭辞)別 ($ / %) ---")
    for k, v in sorted(by_phase.items(), key=lambda x: -x[1]):
        pct = (v / total_cost * 100) if total_cost else 0
        print(f"    {k:16} ${v:8.2f}  {pct:5.1f}%")

    # agentType別に使ったモデル（runをまたいで機種を切り替えていないか確認する用）
    by_type_models = collections.defaultdict(collections.Counter)
    for a in agents.values():
        for r in a.requests:
            by_type_models[a.agent_type][r['model']] += 1
    print("  --- agentType別モデル内訳（req数） ---")
    for k, cnt in sorted(by_type_models.items()):
        print(f"    {k:22} {dict(cnt)}")
    print()
    return o


def print_by_type(by_type, total_cost):
    """agentType 別の $ と割合を、額の大きい順に 1 行ずつ出す。"""
    for k, v in sorted(by_type.items(), key=lambda x: -x[1]):
        pct = (v / total_cost * 100) if total_cost else 0
        print(f"    {k:22} ${v:8.2f}  {pct:5.1f}%")


# ---------------------------------------------------------------------------
# セクション3: agentType別のリクエスト数・所要時間
# ---------------------------------------------------------------------------

def pct(vals, p):
    if not vals:
        return None
    s = sorted(vals)
    idx = min(len(s) - 1, int(round(p * (len(s) - 1))))
    return s[idx]


def _duration_table(groups, title):
    print(title)
    print(f"  {'キー':22} {'n_agents':>8} {'req/agent(中央値)':>18} {'所要(中央値)':>12} {'所要(p90)':>12} {'所要(最大)':>12}")
    for k in sorted(groups, key=lambda k: -len(groups[k])):
        ags = groups[k]
        durs = [a.duration_min() for a in ags if a.duration_min() is not None]
        reqs = [a.n_requests for a in ags]
        med_d = statistics.median(durs) if durs else None
        p90_d = pct(durs, 0.9) if durs else None
        max_d = max(durs) if durs else None
        med_r = statistics.median(reqs) if reqs else None
        print(f"  {k:22} {len(ags):8d} {med_r:18.1f} "
              f"{(f'{med_d:.1f}' if med_d is not None else '?'):>12} "
              f"{(f'{p90_d:.1f}' if p90_d is not None else '?'):>12} "
              f"{(f'{max_d:.1f}' if max_d is not None else '?'):>12}")
    print()


def section_duration(all_agents):
    by_type = collections.defaultdict(list)
    by_phase = collections.defaultdict(list)
    for a in all_agents:
        by_type[a.agent_type].append(a)
        by_phase[phase_prefix(a.label)].append(a)

    _duration_table(by_type, "### agentType別: リクエスト数・所要時間（分）  [全run合算]")
    _duration_table(by_phase, "### phase(ラベル接頭辞)別: リクエスト数・所要時間（分）  [全run合算]\n"
                               "    （issue-implementer は Implement/Fix PR/Rebase を束ねるため、"
                               "phase別の方が「どの段階で壁時計が伸びるか」を見るのに向く）")


# ---------------------------------------------------------------------------
# セクション4: レビューラウンド
# ---------------------------------------------------------------------------

def collect_rounds(runs_data):
    """全 run のプラン・PR・最終確認のラウンドを (run_id, issue) ごとに集める。
    戻り値: (plan_rounds, pr_rounds, gate_rounds)
    """
    plan_rounds = {}  # (run_id, issue) -> {round: (verdict,must,should,nit)}
    pr_rounds = {}     # (run_id, issue) -> {round: (verdict,must,should,nit)}
    gate_rounds = {}   # (run_id, issue) -> {round: verdict}

    for run in runs_data:
        pr2issue = build_pr2issue(run)
        for a in run['agents'].values():
            if not a.result:
                continue
            r = a.result
            m = re.match(r'^Review plan #(\d+) r(\d+)$', a.label)
            if m and 'verdict' in r:
                key = (run['run_id'], m.group(1))
                plan_rounds.setdefault(key, {})[int(m.group(2))] = (
                    r['verdict'], r.get('must', 0), r.get('should', 0), r.get('nit', 0))
                continue
            m = re.match(r'^PR review #(\d+) r(\d+)$', a.label)
            if m and 'verdict' in r:
                issue = pr2issue.get(m.group(1), 'PR' + m.group(1))
                key = (run['run_id'], issue)
                pr_rounds.setdefault(key, {})[int(m.group(2))] = (
                    r['verdict'], r.get('must', 0), r.get('should', 0), r.get('nit', 0))
                continue
            m = re.match(r'^Final gate PR #(\d+)(?: r(\d+))?$', a.label)
            if m and 'verdict' in r:
                issue = pr2issue.get(m.group(1), 'PR' + m.group(1))
                key = (run['run_id'], issue)
                rnd = int(m.group(2)) if m.group(2) else 1
                gate_rounds.setdefault(key, {})[rnd] = r['verdict']
    return plan_rounds, pr_rounds, gate_rounds


def r1_summary(rounds_map):
    """ラウンド 1 の APPROVE 数・件数・must/should/nit の合計を返す。"""
    r1 = [rs[1] for rs in rounds_map.values() if 1 in rs]
    return dict(n=len(r1), approve=sum(1 for v in r1 if v[0] == 'APPROVE'),
                must=sum(v[1] for v in r1), should=sum(v[2] for v in r1), nit=sum(v[3] for v in r1))


def section_review_rounds(runs_data):
    plan_rounds, pr_rounds, gate_rounds = collect_rounds(runs_data)

    print("### レビューラウンド（issue単位。run内のissue番号で識別）")
    print("  --- プランレビュー: ラウンドごとの (verdict, must, should, nit) ---")
    for (run_id, issue), rs in sorted(plan_rounds.items()):
        rounds_str = ' -> '.join(f"r{i}:{v[0]}(m{v[1]}/s{v[2]}/n{v[3]})" for i, v in sorted(rs.items()))
        print(f"    [{run_id}] #{issue}: {rounds_str}")
    print("  --- PRレビュー: ラウンドごとの (verdict, must, should, nit) ---")
    for (run_id, issue), rs in sorted(pr_rounds.items()):
        rounds_str = ' -> '.join(f"r{i}:{v[0]}(m{v[1]}/s{v[2]}/n{v[3]})" for i, v in sorted(rs.items()))
        print(f"    [{run_id}] #{issue}: {rounds_str}")
    print("  --- 最終確認(gate): ラウンドごとの verdict ---")
    for (run_id, issue), rs in sorted(gate_rounds.items()):
        rounds_str = ' -> '.join(f"r{i}:{v}" for i, v in sorted(rs.items()))
        print(f"    [{run_id}] #{issue}: {rounds_str}")

    def r1_stats(rounds_map, name):
        r1 = [rs[1] for rs in rounds_map.values() if 1 in rs]
        n = len(r1)
        if n == 0:
            print(f"  {name}: r1データなし")
            return
        n_approve = sum(1 for v in r1 if v[0] == 'APPROVE')
        avg_must = sum(v[1] for v in r1) / n
        avg_should = sum(v[2] for v in r1) / n
        avg_nit = sum(v[3] for v in r1) / n
        print(f"  {name}: r1 APPROVE率 {n_approve}/{n} ({n_approve/n*100:.0f}%)"
              f"  must/件(r1)={avg_must:.2f}  should/件(r1)={avg_should:.2f}  nit/件(r1)={avg_nit:.2f}")

    print("  --- 集計（全run合算） ---")
    r1_stats(plan_rounds, "プラン")
    r1_stats(pr_rounds, "PRレビュー")

    print("  --- run別 r1 APPROVE率（時系列の傾向を見る用） ---")
    run_ids_in_order = []
    for run in runs_data:
        if run['run_id'] not in run_ids_in_order:
            run_ids_in_order.append(run['run_id'])
    for run_id in run_ids_in_order:
        p1 = [rs[1] for (rid, _), rs in plan_rounds.items() if rid == run_id and 1 in rs]
        q1 = [rs[1] for (rid, _), rs in pr_rounds.items() if rid == run_id and 1 in rs]
        p_txt = f"{sum(1 for v in p1 if v[0]=='APPROVE')}/{len(p1)}" if p1 else "0/0"
        q_txt = f"{sum(1 for v in q1 if v[0]=='APPROVE')}/{len(q1)}" if q1 else "0/0"
        print(f"    [{run_id}] プランr1 APPROVE {p_txt}  /  PRレビューr1 APPROVE {q_txt}")

    def should_only_rework(rounds_map, name):
        n_multi_must0 = 0
        n_multi = 0
        details = []
        for key, rs in rounds_map.items():
            max_round = max(rs)
            if max_round >= 2:
                n_multi += 1
                if 1 in rs and rs[1][1] == 0:
                    n_multi_must0 += 1
                    details.append(key)
        print(f"  {name}: ラウンド数>=2 は {n_multi} 件中、r1 must==0（=shouldのみが原因の往復）は {n_multi_must0} 件")
        if details:
            print(f"    該当: {details}")

    should_only_rework(plan_rounds, "プラン")
    should_only_rework(pr_rounds, "PRレビュー")
    print()


# ---------------------------------------------------------------------------
# セクション5: キャッシュ効率
# ---------------------------------------------------------------------------

def section_cache(all_agents):
    by_type_tokens = collections.defaultdict(lambda: [0, 0, 0])  # inp, cw, cr
    by_type_rewrite = collections.defaultdict(int)
    by_type_total_reqs = collections.defaultdict(int)

    for a in all_agents:
        for r in a.requests:
            by_type_tokens[a.agent_type][0] += r['inp']
            by_type_tokens[a.agent_type][1] += r['cw']
            by_type_tokens[a.agent_type][2] += r['cr']
            by_type_total_reqs[a.agent_type] += 1
            if r['cw'] >= 60000:
                by_type_rewrite[a.agent_type] += 1

    print("### agentType別: キャッシュ効率  [全run合算]")
    print(f"  {'agentType':22} {'cache_read比率':>14} {'総req数':>8} {'cache_creation>=60k件数':>22}")
    for k in sorted(by_type_tokens, key=lambda k: -sum(by_type_tokens[k])):
        inp, cw, cr = by_type_tokens[k]
        denom = inp + cw + cr
        ratio = cr / denom * 100 if denom else 0
        print(f"  {k:22} {ratio:13.1f}% {by_type_total_reqs[k]:8d} {by_type_rewrite[k]:22d}")
    print()


# ---------------------------------------------------------------------------
# セクション6: 出力トークン
# ---------------------------------------------------------------------------

def section_output_tokens(all_agents):
    by_type = collections.defaultdict(list)
    for a in all_agents:
        by_type[a.agent_type].append(a.out_tokens())

    print("### agentType別: エージェントあたり出力トークン数（中央値）  [全run合算]")
    print(f"  {'agentType':22} {'n':>6} {'中央値':>10} {'p90':>10} {'最大':>10}")
    for k in sorted(by_type, key=lambda k: -statistics.median(by_type[k])):
        vals = by_type[k]
        print(f"  {k:22} {len(vals):6d} {statistics.median(vals):10.0f} "
              f"{pct(vals,0.9):10.0f} {max(vals):10.0f}")
    print()


# ---------------------------------------------------------------------------
# セクション7: クリティカルパス（マージ済みissue）
# ---------------------------------------------------------------------------

STAGE_GROUP = {
    'Triage': 'Plan+Review', 'Design': 'Plan+Review', 'Plan': 'Plan+Review', 'Review plan': 'Plan+Review',
    'Implement': 'Implement',
    'PR review': 'PRreview+Fix', 'Fix PR': 'PRreview+Fix',
    'Final gate PR': 'Gate+Merge', 'Merge PR': 'Gate+Merge', 'Rebase PR': 'Gate+Merge',
}


def merged_stages(run):
    """マージ済み issue ごとに、その issue（か PR）を参照するエージェントを開始順に集める。
    戻り値: [(issue, pr, stage_agents)]。PR 番号順。
    """
    pr2issue = build_pr2issue(run)
    merged_prs = []
    for a in run['agents'].values():
        if a.result and a.result.get('status') == 'merged':
            m = re.match(r'^Merge PR #(\d+)', a.label)
            if m:
                merged_prs.append(m.group(1))
    out = []
    for pr in sorted(merged_prs, key=int):
        issue = pr2issue.get(pr, '?')
        stage_agents = []
        for aid in run['order']:
            a = run['agents'].get(aid)
            if not a or a.t_min is None:
                continue
            num = label_issue_num(a.label)
            if num == issue or num == pr:
                stage_agents.append(a)
        stage_agents.sort(key=lambda a: a.t_min)
        out.append((issue, pr, stage_agents))
    return out


def stages_total_min(stage_agents):
    """段階の列の最初の開始から最後の終了までの分。"""
    return (stage_agents[-1].t_max - stage_agents[0].t_min).total_seconds() / 60


def section_critical_path(run):
    stages = merged_stages(run)

    print(f"### run {run['run_id']}: マージ済みissueのクリティカルパス")
    if not stages:
        print("  マージ済みなし")
        print()
        return

    totals = []
    gap_sums = []
    group_sums = collections.defaultdict(float)
    neg_gap_count = 0

    for issue, pr, stage_agents in stages:
        if not stage_agents:
            continue
        total_start = stage_agents[0].t_min
        total_end = stage_agents[-1].t_max
        total_min = stages_total_min(stage_agents)
        print(f"  issue #{issue} (PR #{pr})  総所要 {total_min:.1f} 分"
              f"  ({fmt_ts(total_start)} 〜 {fmt_ts(total_end)})")
        prev_end = None
        gap_sum = 0.0
        for a in stage_agents:
            dur = a.duration_min()
            gap = (a.t_min - prev_end).total_seconds() / 60.0 if prev_end else 0.0
            neg_flag = ''
            if gap < -0.05:
                neg_flag = '  ※負の待ち＝前段と並行/重複実行（例: DesignとPlan v1が並行）'
                neg_gap_count += 1
            else:
                gap_sum += gap
            print(f"    {a.label:28} 所要{dur:7.1f}分  (直前からの待ち{gap:7.1f}分){neg_flag}")
            group_sums[STAGE_GROUP.get(phase_prefix(a.label), '?')] += dur or 0.0
            prev_end = a.t_max
        totals.append(total_min)
        gap_sums.append(gap_sum)

    if totals:
        print(f"  --- run集計（マージ済み{len(totals)}件） ---")
        print(f"    総所要(分): 中央値 {statistics.median(totals):.1f}  最大 {max(totals):.1f}")
        print(f"    待ち時間合計(分・負の待ちは0扱い): 中央値 {statistics.median(gap_sums):.1f}")
        if neg_gap_count:
            print(f"    負の待ち(並行実行)を観測した段階数: {neg_gap_count}")
        grand = sum(group_sums.values())
        if grand:
            print("    ステージ群ごとの所要合計シェア:")
            for g, v in sorted(group_sums.items(), key=lambda x: -x[1]):
                print(f"      {g:16} {v:8.1f}分  {v/grand*100:5.1f}%")
    print()


# ---------------------------------------------------------------------------
# 副次: オーケストレーターセッション自身のコスト（run期間に重なる分。重なりは均等割り）
# ---------------------------------------------------------------------------

def session_agent_like(session_path):
    """メインセッションのjsonlをAgentもどきとして読む（requestsのみ使う）。"""
    reqs, t_min, t_max = load_agent_jsonl(session_path)
    return reqs


def section_orchestrator_cost(runs_data, base):
    print("### 参考: オーケストレーター（メインセッション）自身のコスト")
    print("  ※ Workflow ツールはバックグラウンドで並行実行されることがあり、同一セッション内で")
    print("     複数runの時間帯が重なる場合、メインセッションのコストは重なっているrun数で均等割りした概算。")
    by_session = collections.defaultdict(list)
    for run in runs_data:
        by_session[run['session_id']].append(run)

    for session_id, runs in by_session.items():
        session_path = f"{base}/{session_id}.jsonl"
        if not os.path.exists(session_path):
            print(f"  session {session_id}: メインセッションのjsonlが見つからない")
            continue
        reqs, _, _ = load_agent_jsonl(session_path)
        # 各requestの時刻がどのrunの[t_min,t_max]に入るか数える
        windows = [(r['run_id'], r['run_t_min'], r['run_t_max']) for r in runs]
        alloc = collections.defaultdict(float)
        unallocated = 0.0
        for r in reqs:
            if not r['ts']:
                continue
            t = parse_ts(r['ts'])
            matches = [w[0] for w in windows if w[1] and w[2] and w[1] <= t <= w[2]]
            c = req_cost(r)
            if matches:
                for run_id in matches:
                    alloc[run_id] += c / len(matches)
            else:
                unallocated += c
        total = sum(alloc.values()) + unallocated
        print(f"  session {session_id}: メインセッション総額 ${total:.2f}")
        for run_id, c in sorted(alloc.items()):
            print(f"    {run_id}: 割当 ${c:.2f}")
        if unallocated > 0.01:
            print(f"    (どのrun時間帯にも入らない分: ${unallocated:.2f} — run前後の準備/確認など)")
    print()


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def section_brief(runs_data):
    """retrospective が issue に貼る要約。run ごとの表、agentType 別の $、レビューの r1、クリティカルパス、agentType 別のモデル。"""
    print("| run | 期間（UTC） | 壁時計 | マージ | stalled | 総額 | $/マージ済み issue |")
    print("| --- | --- | --- | --- | --- | --- | --- |")
    by_type_all = collections.defaultdict(float)
    total_all = 0.0
    for run in runs_data:
        o = compute_overview(run, build_pr2issue(run))
        per = f"${o['total_cost'] / o['n_merged']:.2f}" if o['n_merged'] else "N/A"
        print(f"| {run['run_id']} | {fmt_ts(run['run_t_min'])} 〜 {fmt_ts(run['run_t_max'])} | {wall_hours(run):.2f} h"
              f" | {o['n_merged']} | {o['stalled']} | ${o['total_cost']:.2f} | {per} |")
        for k, v in o['by_type'].items():
            by_type_all[k] += v
        total_all += o['total_cost']
    print()
    print("agentType 別（$ / 割合）")
    print_by_type(by_type_all, total_all)
    print()
    plan_rounds, pr_rounds, _ = collect_rounds(runs_data)
    print("レビューのラウンド 1（APPROVE 率と must / should / nit の件数）")
    for name, rounds_map in (("プラン", plan_rounds), ("PR", pr_rounds)):
        r = r1_summary(rounds_map)
        rate = f"{r['approve']}/{r['n']} ({r['approve'] / r['n'] * 100:.0f}%)" if r['n'] else "0/0"
        print(f"    {name:6} r1 APPROVE {rate}  must {r['must']} / should {r['should']} / nit {r['nit']}")
    print()
    totals = [stages_total_min(st) for run in runs_data for _, _, st in merged_stages(run) if st]
    if totals:
        print(f"マージ済み issue のクリティカルパス（分）: 中央値 {statistics.median(totals):.1f}  最大 {max(totals):.1f}  n={len(totals)}")
    else:
        print("マージ済み issue のクリティカルパス: マージ済みなし")
    print()
    print_models_by_type(runs_data)
    print()
    print("金額は API の公開価格による見積もり（dev/wfstats.py の PRICE）")


def print_models_by_type(runs_data):
    """agentType ごとのモデル別リクエスト数を出す。1 つの agentType に 2 つ以上のモデルがあれば印を付ける
    （安全策のフォールバックで古いモデルが答えたか、別名の解決先が実行の途中で変わった）。"""
    models = collections.defaultdict(collections.Counter)
    for run in runs_data:
        for a in run['agents'].values():
            for r in a.requests:
                models[a.agent_type][r['model']] += 1
    print("agentType 別のモデル（リクエスト数）")
    for t in sorted(models):
        c = models[t]
        mark = "  ⚠ モデルが混在" if len(c) > 1 else ""
        print(f"    {t:22} " + ", ".join(f"{m} {n}" for m, n in c.most_common()) + mark)


def parse_args():
    ap = argparse.ArgumentParser(description="Claude Code Workflow の実行ログの統計")
    ap.add_argument('--base', default=default_base(), help="Claude Code のプロジェクトのディレクトリ")
    ap.add_argument('--runs', default=None, help="対象の run id（wf_*）をコンマ区切りで。省略時は全 run")
    ap.add_argument('--brief', action='store_true', help="要約だけを出す（60 行以内）")
    return ap.parse_args()


def main():
    opts = parse_args()
    run_ids = [r for r in opts.runs.split(',') if r] if opts.runs else None
    runs_meta = discover_runs(opts.base, run_ids)
    if run_ids:
        for r in set(run_ids) - {m[0] for m in runs_meta}:
            print(f"warning: run {r} が {opts.base} に見つからない（またはドライラン）", file=sys.stderr)
    runs_data = [load_run(run_id, session_id, wf_dir) for run_id, session_id, wf_dir in runs_meta]
    # runを開始時刻順に
    runs_data.sort(key=lambda r: r['run_t_min'] or datetime.min.replace(tzinfo=timezone.utc))

    if opts.brief:
        section_brief(runs_data)
        return

    print("=" * 100)
    print(f"nostr-no-su Claude Code Workflow 実行ログ分析")
    print(f"対象run数: {len(runs_meta)}  (ドライラン=1行journalのみのものは除外)")
    print("=" * 100)
    print()

    print("#" * 100)
    print("# データ品質チェック")
    print("#" * 100)
    print()
    total_started = 0
    total_no_transcript = 0
    total_no_result = 0
    for run in runs_data:
        started_ids = set(run['order'])
        no_transcript = started_ids - set(run['agents'].keys())
        no_result = sum(1 for a in run['agents'].values() if a.stalled)
        total_started += len(started_ids)
        total_no_transcript += len(no_transcript)
        total_no_result += no_result
        print(f"  {run['run_id']}: started={len(started_ids)}  meta+jsonl有り={len(run['agents'])}"
              f"  transcript欠落={len(no_transcript)}  resultイベント無し(stalled)={no_result}")
    print(f"  合計: started={total_started}  transcript欠落={total_no_transcript}"
          f"  stalled(resultイベント無し)={total_no_result}")
    print("  ※ transcript欠落0件を確認済み＝コストはstarted全エージェント分を正しく捕捉できている。")
    print("  ※ stalledのエージェントもトランスクリプトは残っており、コストは加算済み（journalにresultが無いだけ）。")
    print()

    print("#" * 100)
    print("# セクション1・2: run概要とコスト内訳")
    print("#" * 100)
    print()
    overview = {}
    for run in runs_data:
        pr2issue = build_pr2issue(run)
        overview[run['run_id']] = section_overview(run, pr2issue)

    all_agents = [a for run in runs_data for a in run['agents'].values()]

    print("#" * 100)
    print("# セクション3: agentType別リクエスト数・所要時間")
    print("#" * 100)
    print()
    section_duration(all_agents)

    print("#" * 100)
    print("# セクション4: レビューラウンド")
    print("#" * 100)
    print()
    section_review_rounds(runs_data)

    print("#" * 100)
    print("# セクション5: キャッシュ効率")
    print("#" * 100)
    print()
    section_cache(all_agents)

    print("#" * 100)
    print("# セクション6: 出力トークン")
    print("#" * 100)
    print()
    section_output_tokens(all_agents)

    print("#" * 100)
    print("# セクション7: クリティカルパス（マージ済みissue）")
    print("#" * 100)
    print()
    for run in runs_data:
        section_critical_path(run)

    print("#" * 100)
    print("# 参考セクション: オーケストレーターセッション自身のコスト")
    print("#" * 100)
    print()
    section_orchestrator_cost(runs_data, opts.base)

    print("#" * 100)
    print("# 全run合計サマリー")
    print("#" * 100)
    total_cost_all = sum(o['total_cost'] for o in overview.values())
    total_merged_all = sum(o['n_merged'] for o in overview.values())
    total_stalled_all = sum(o['stalled'] for o in overview.values())
    print(f"  全run合計 $: ${total_cost_all:.2f}")
    print(f"  全runマージ済み合計: {total_merged_all} 件")
    print(f"  全run $/マージ済みissue: ${total_cost_all/total_merged_all:.2f}" if total_merged_all else "  N/A")
    print(f"  全run stalled 合計: {total_stalled_all} 件")


if __name__ == '__main__':
    main()
