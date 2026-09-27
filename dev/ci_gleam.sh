#!/bin/sh
# 作業ツリーの CI（.github/workflows/ci.yml の最初の gleam-version）と同じ版の gleam で、
# その作業ツリーを cwd にして gleam のコマンドを実行する。hook（dev/hook_gleam_format.sh、
# dev/hook_push_format_check.sh）が、ホストの gleam の版が CI と違うときに古い版の整形で
# 判定しないために使う。
#
#   ホストの `gleam --version` が CI の版と同じ          その gleam で実行する
#   違う（または無い）が mise にその版が入っている        `$(mise where gleam@<版>)/bin/gleam` で実行する（mise install はしない）
#   版の合う gleam が無い、ci.yml から版が読めない        何も実行せず 127 で終わる（呼び出し側は CI に任せて省く）
#   それ以外                                              gleam の終了コードで終わる
#
# 使い方: sh dev/ci_gleam.sh <作業ツリー> <gleam の引数>...
set -u

[ $# -ge 2 ] || { echo "usage: sh dev/ci_gleam.sh <worktree> <gleam args>..." >&2; exit 2; }
tree="$1"
shift

version=$(sed -n 's/^[[:space:]]*gleam-version:[[:space:]]*"\([^"]*\)".*/\1/p' "$tree/.github/workflows/ci.yml" 2> /dev/null | head -n 1)
[ -n "$version" ] || exit 127

if [ "$(gleam --version 2> /dev/null)" = "gleam $version" ]; then
  gleam_bin=gleam
elif command -v mise > /dev/null 2>&1 && dir=$(mise where "gleam@$version" 2> /dev/null) && [ -x "$dir/bin/gleam" ]; then
  gleam_bin="$dir/bin/gleam"
else
  exit 127
fi

cd "$tree" && exec "$gleam_bin" "$@"
