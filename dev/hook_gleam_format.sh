#!/bin/sh
# 実装エージェント（.claude/agents/issue-implementer.md）の PostToolUse hook。
# Edit / Write の後に、編集したファイルが .gleam なら、そのファイルが属する作業ツリーで
# `gleam format <file>` をかける（定義の「PR を作る前の検査」の手順 4 の保険）。
#
# stdin に hook の JSON を受け取り、tool_input.file_path を読む。
#   .gleam 以外、file_path が無い、jq が読めない  何もせず 0 で終わる
#   ユーザーの作業ツリーの下                         何もせず 0 で終わる（定義はユーザーの
#                                                    作業ツリーを編集しないと定めているので、
#                                                    ここで整形が走るのは異常であり、黙って直さない）
#   gleam format が失敗（構文エラーなど）            出力を stderr に出して 2 で終わる（エージェントに見える）
# hook の cwd はセッションの cwd（ユーザーの作業ツリー）なので、パスは絶対パスで扱う。
#
# 使い方: echo '{"tool_input":{"file_path":"/path/to/x.gleam"}}' | sh dev/hook_gleam_format.sh
set -u

user_tree=/home/lina/workspace/projects/nostr-no-su

file=$(jq -r '.tool_input.file_path // empty' 2> /dev/null) || exit 0
[ -n "$file" ] || exit 0
case "$file" in
  *.gleam) ;;
  *) exit 0 ;;
esac
case "$file" in
  "$user_tree" | "$user_tree"/*) exit 0 ;;
esac
[ -f "$file" ] || exit 0
tree=$(git -C "$(dirname "$file")" rev-parse --show-toplevel 2> /dev/null) || exit 0
command -v gleam > /dev/null 2>&1 || exit 0

if ! out=$(cd "$tree" && gleam format "$file" 2>&1); then
  printf 'hook_gleam_format: gleam format %s failed\n%s\n' "$file" "$out" >&2
  exit 2
fi
exit 0
