#!/bin/sh
# 実装エージェント（.claude/agents/issue-implementer.md）の PreToolUse hook（matcher Bash）。
# `gh pr create` の本文（--body-file）に定義の「コミットと PR」の書式の必須の節が揃っているかを
# 見て、欠けていれば deny の JSON を出して止める。
#
# stdin に hook の JSON を受け取り、tool_input.command を読む。
#   `gh pr create` を含まない、jq が読めない  何も出力せず 0 で終わる（許可も拒否もしない）
#   `gh pr create` で本文が揃っている            何も出力せず 0 で終わる（許可の判断は通常の権限の流れに任せる）
#   --body-file が無い、または読めない          deny（理由に「--body-file で本文を渡す」）
#   --body-file のパスに $ や ` がある            deny（hook はエージェントのシェルの変数を展開できない。絶対パスで書かせる）
#   次のどれかが欠けている                      deny（理由に欠けている節と定義の該当箇所）
#     `## 概要`、`## 変更点`、`## テストと検証` の見出し
#     「掃き出した語」を含む行（sweep_refs.sh を回した証拠。0 件でも書く決まり）
#     `Closes #` の行
#     `## 設計メモ` があるとき（tier none）は `### 決めたこと` と `| 受け入れ条件 |` で始まる表の見出し行
# --body-file の相対パスは JSON の cwd（無ければ hook の cwd）から解く。
#
# 使い方: echo '{"tool_input":{"command":"gh pr create ... --body-file /path/body.md"}}' | sh dev/hook_pr_body_gate.sh
set -u

where='.claude/agents/issue-implementer.md の「コミットと PR」の本文の書式'

# deny の JSON を出して終わる。理由は jq で引用する。
deny() {
  jq -n --arg reason "$1" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
  exit 0
}

input=$(cat) || exit 0
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2> /dev/null) || exit 0
case "$cmd" in
  *"gh pr create"*) ;;
  *) exit 0 ;;
esac
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2> /dev/null) || cwd=""
[ -n "$cwd" ] || cwd=$(pwd)

# --body-file <path> / --body-file=<path> / -F <path> の最初の 1 つを取り、引用符を外す。
body=$(printf '%s\n' "$cmd" | tr '\n' ' ' \
  | sed -n 's/.*\(--body-file\|-F\)[= ][ ]*\([^ ]*\).*/\2/p' | sed 's/^["'"'"']//; s/["'"'"']$//')
[ -n "$body" ] || deny "gh pr create に --body-file が無い。PR 本文はファイルに書き、--body-file で渡す（$where）"
case "$body" in
  *'$'* | *'`'*) deny "--body-file のパス $body に変数がある。hook はシェルの変数を展開できないので、絶対パスで書く（$where）" ;;
  /*) ;;
  *) body="$cwd/$body" ;;
esac
[ -r "$body" ] || deny "--body-file のファイル $body が読めない。PR 本文はファイルに書き、--body-file で渡す（$where）"

# 欠けている節の名前を missing に、掃き出した語が無ければ hint に集める。
missing=""
hint=""
for pat in '^## 概要' '^## 変更点' '^## テストと検証' '^Closes #'; do
  grep -q -e "$pat" "$body" || missing="$missing、「${pat#^}」"
done
if ! grep -q '掃き出した語' "$body"; then
  missing="$missing、「掃き出した語」の行"
  hint="。掃き出した語は sweep_refs.sh を回した証拠で、0 件でも書く"
fi
if grep -q '^## 設計メモ' "$body"; then
  for pat in '^### 決めたこと' '^| 受け入れ条件 |'; do
    grep -q -e "$pat" "$body" || missing="$missing、「${pat#^}」（## 設計メモ の下）"
  done
fi
[ -n "$missing" ] || exit 0
deny "PR 本文 $body に必須の節が無い: ${missing#、}$hint（$where）"
