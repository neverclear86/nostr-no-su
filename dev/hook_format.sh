#!/bin/sh
# 実装エージェント（.claude/agents/issue-implementer.md）の PostToolUse hook（matcher Edit|Write）。
# Edit / Write の後に、編集したファイルが整形の対象（下の「設定」の ext_re）なら、そのファイルが属する
# 作業ツリーで整形のコマンドをかける（定義の「PR を作る前の検査」の整形の手順の保険）。
#
# stdin に hook の JSON を受け取り、tool_input.file_path を読む。
#   対象外の拡張子、file_path が無い、jq が読めない  何もせず 0 で終わる
#   ユーザーの作業ツリーの下                         何もせず 0 で終わる（定義はユーザーの
#                                                    作業ツリーを編集しないと定めているので、
#                                                    ここで整形が走るのは異常であり、黙って直さない）
#   整形のコマンドが無い、コマンドが 127 で終わる    何もせず 0 で終わる（127 は道具が無いの意。版を選ぶ
#                                                    ラッパーが合う版を見つけられないときなど。CI が検査する）
#   整形が失敗（構文エラーなど）                     出力を stderr に出して 2 で終わる（エージェントに見える）
# hook の cwd はセッションの cwd（ユーザーの作業ツリー）なので、パスは絶対パスで扱う。
# ユーザーの作業ツリーは Claude Code が hook に渡す CLAUDE_PROJECT_DIR（無ければ cwd）から取る。
#
# 使い方: echo '{"tool_input":{"file_path":"/path/to/x.ext"}}' | sh dev/hook_format.sh
set -u

# --- 設定（issue-workflow-kit が導入時に埋める） ---
# 整形の対象のファイル名（grep -E）
ext_re='[.]gleam$'
# 1 ファイルを整形するコマンド（作業ツリーの最上位で、末尾にファイルの絶対パスを付けて実行する）
format_file_cmd='sh dev/ci_gleam.sh . format'

user_tree=${CLAUDE_PROJECT_DIR:-$(pwd)}

file=$(jq -r '.tool_input.file_path // empty' 2> /dev/null) || exit 0
[ -n "$file" ] || exit 0
printf '%s\n' "$file" | grep -Eq "$ext_re" || exit 0
case "$file" in
  "$user_tree" | "$user_tree"/*) exit 0 ;;
esac
[ -f "$file" ] || exit 0
tree=$(git -C "$(dirname "$file")" rev-parse --show-toplevel 2> /dev/null) || exit 0
# shellcheck disable=SC2086
command -v ${format_file_cmd%% *} > /dev/null 2>&1 || exit 0

# shellcheck disable=SC2086
out=$(cd "$tree" && $format_file_cmd "$file" 2>&1)
status=$?
case $status in 0 | 127) exit 0 ;; esac
printf 'hook_format: %s %s failed\n%s\n' "$format_file_cmd" "$file" "$out" >&2
exit 2
