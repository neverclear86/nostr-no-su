#!/bin/sh
# コードのコメント（Gleam の //、///、//// と Erlang の %）から、.claude/rules/code-comments.md が
# 書かないとする語（issue 番号、テスト名、「従来」）を含む行を「path:行:内容」の形で一覧にする。
# 一致が無ければ 0、あれば 1、引数の誤りと無いファイルは 2 で終わる。CI では実行しない。
#
# 使い方: sh dev/check_comments.sh <作業ツリー> [ファイル...]
#   ファイル: 作業ツリーからの相対パス。省くと src/ と plugins-src/*/src の追跡中の .gleam と .erl を全部見る
set -eu

[ $# -ge 1 ] || { echo "usage: sh dev/check_comments.sh <worktree> [file...]" >&2; exit 2; }
tree="$1"
shift
git -C "$tree" rev-parse --show-toplevel > /dev/null 2>&1 || { echo "not a git worktree: $tree" >&2; exit 2; }

if [ $# -eq 0 ]; then
  # shellcheck disable=SC2046
  set -- $(git -C "$tree" ls-files 'src/*.gleam' 'src/*.erl' 'plugins-src/*/src/*.gleam' 'plugins-src/*/src/*.erl')
fi

out=$(
  for f in "$@"; do
    [ -f "$tree/$f" ] || { echo "no such file: $f" >&2; exit 2; }
    case $f in
      *.gleam) mark='//' ;;
      *.erl) mark='%' ;;
      *) continue ;;
    esac
    grep -nE "^[[:space:]]*$mark.*(#[0-9]{2,}|_test\b|従来)" "$tree/$f" | sed "s|^|$f:|" || true
  done
)

if [ -n "$out" ]; then
  printf '%s\n' "$out"
  exit 1
fi
exit 0
