#!/bin/sh
# 実装エージェント（.claude/agents/issue-implementer.md）の PreToolUse hook（matcher Bash）。
# `git -C <作業ツリー> push` の前に、その作業ツリーで `gleam format --check src test dev` を
# 実行し、通らなければ deny の JSON を出して止める（定義の「PR を作る前の検査」の手順 4 の保険）。
# `gleam build` と `gleam test` は数分伸びるので行わない（CI が検査する）。
#
# stdin に hook の JSON を受け取り、tool_input.command を読む。
#   `git -C <path> push` の形でない、-C の無い `git push`、jq が読めない  何も出力せず 0 で終わる
#   <path> がユーザーの作業ツリーの下、gleam.toml が無い、gleam が無い      何も出力せず 0 で終わる
#   <path> に $ や ` がある                                                deny（hook はエージェントのシェルの変数を展開できない。絶対パスで書かせる）
#   format --check が通る                                                  何も出力せず 0 で終わる
#   format --check が失敗                                                  deny（理由に出力の要点）
#
# 使い方: echo '{"tool_input":{"command":"git -C /path/wt push -u origin x"}}' | sh dev/hook_push_format_check.sh
set -u

user_tree=/home/lina/workspace/projects/nostr-no-su

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
[ -f "$tree/gleam.toml" ] || exit 0
command -v gleam > /dev/null 2>&1 || exit 0

if out=$(cd "$tree" && gleam format --check src test dev 2>&1); then
  exit 0
fi
summary=$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | head -n 20)
deny "gleam format --check src test dev が $tree で通らない。gleam format src test dev をかけてコミットしてから push する（.claude/agents/issue-implementer.md の「PR を作る前の検査」の手順 4）:
$summary"
