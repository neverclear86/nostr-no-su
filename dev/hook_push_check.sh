#!/bin/sh
# 実装エージェント（.claude/agents/issue-implementer.md）の PreToolUse hook（matcher Bash）。
# `git -C <作業ツリー> push` の前に、その作業ツリーで速い検査（下の「設定」の check_cmd。整形の検査など）を
# 実行し、通らなければ deny の JSON を出して止める（定義の「PR を作る前の検査」の保険）。
# build とテストは時間が伸びるので行わない（CI か定義の手順が検査する）。
#
# stdin に hook の JSON を受け取り、tool_input.command を読む。
#   `git -C <path> push` の形でない、-C の無い `git push`、jq が読めない  何も出力せず 0 で終わる
#   <path> がユーザーの作業ツリーの下、marker_file が無い、コマンドが無い  何も出力せず 0 で終わる
#   check_cmd が 127 で終わる（道具が無い。版を選ぶラッパーが合う版を見つけられないときなど）  何も出力せず 0 で終わる（CI が検査する）
#   <path> に $ や ` がある                                                deny（hook はエージェントのシェルの変数を展開できない。絶対パスで書かせる）
#   check_cmd が通る                                                       何も出力せず 0 で終わる
#   check_cmd が失敗                                                       deny（理由に出力の要点）
#
# ユーザーの作業ツリーは Claude Code が hook に渡す CLAUDE_PROJECT_DIR（無ければ cwd）から取る。
#
# 使い方: echo '{"tool_input":{"command":"git -C /path/wt push -u origin x"}}' | sh dev/hook_push_check.sh
set -u

# --- 設定（issue-workflow-kit が導入時に埋める） ---
# 作業ツリーの最上位で実行する速い検査のコマンドと、それを実行してよいリポジトリの印のファイル
check_cmd='sh dev/ci_gleam.sh . format --check src test dev'
marker_file='gleam.toml'

user_tree=${CLAUDE_PROJECT_DIR:-$(pwd)}

# deny の JSON を出して終わる。理由は jq で引用する。
deny() {
  jq -n --arg reason "$1" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
  exit 0
}

cmd=$(jq -r '.tool_input.command // empty' 2> /dev/null) || exit 0
# 最初の `git -C <path> push` の <path> を取り、引用符を外す。
tree=$(printf '%s\n' "$cmd" | tr '\n' ' ' \
  | sed -n 's/.*git -C \("[^"]*"\|'"'"'[^'"'"']*'"'"'\|[^ ]*\) push.*/\1/p' | sed 's/^["'"'"']//; s/["'"'"']$//')
[ -n "$tree" ] || exit 0
case "$tree" in
  *'$'* | *'`'*) deny "git -C のパス $tree に変数がある。hook はシェルの変数を展開できないので、作業ツリーは絶対パスで書く（.claude/agents/issue-implementer.md の「コミットと PR」）" ;;
  "$user_tree" | "$user_tree"/*) exit 0 ;;
esac
[ -f "$tree/$marker_file" ] || exit 0
# shellcheck disable=SC2086
command -v ${check_cmd%% *} > /dev/null 2>&1 || exit 0

# shellcheck disable=SC2086
out=$(cd "$tree" && $check_cmd 2>&1)
status=$?
case $status in 0 | 127) exit 0 ;; esac
summary=$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | head -n 20)
deny "$check_cmd が $tree で通らない。直してコミットしてから push する（.claude/agents/issue-implementer.md の「PR を作る前の検査」）:
$summary"
