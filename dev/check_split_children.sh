#!/bin/sh
# 分割の親のサブ issue の本文が、親の「## 分割の設計」の表と一致し、兄弟の複写でないことを検査する。
# 検査は 2 つ。(1) 同じ親のサブ issue どうしで、空白を 1 つの空白に正規化した本文が同一の組が無い。
# (2) 親の分割の設計（マーカー kind=split の最後のコメント）の表の各行について、その番号のサブ issue が
# 親にあり、本文が 2 列目の項目の ID（`E1-6` の形）をすべて含む。表に無いサブ issue も挙げる。
# 別の親のサブ issue の複写（本文の ID が表と違う）は (2) で見つかる。
# 不一致を 1 件 1 行で出し、1 件でもあれば 1 で終わる。親にサブ issue か分割の設計の表が無いときも 1。
# GitHub は読むだけで、書き込まない。
#
# 使い方: sh dev/check_split_children.sh <親の番号>
set -eu

[ $# -eq 1 ] || { echo "usage: sh dev/check_split_children.sh <parent-number>" >&2; exit 1; }
case "$1" in '' | *[!0-9]*) echo "invalid number: $1" >&2; exit 1 ;; esac
parent="$1"
# --- 設定（issue-workflow-kit が導入時に埋める。マーカーの接頭辞は post_comment.sh と同じ値にする） ---
repo='neverclear86/nostr-no-su'
marker='nns'

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
gh api graphql -F n="$parent" -f query='query($n:Int!){repository(owner:"'"${repo%/*}"'",name:"'"${repo#*/}"'"){issue(number:$n){subIssues(first:100){nodes{number body}}}}}' \
  --jq '.data.repository.issue.subIssues.nodes[] | "\(.number)\t\(.body | gsub("\\s+"; " "))"' > "$tmp/children"
[ -s "$tmp/children" ] || { echo "#$parent にサブ issue が無い" >&2; exit 1; }
while IFS="$(printf '\t')" read -r n body; do printf '%s\n' "$body" > "$tmp/body-$n"; done < "$tmp/children"
gh api "repos/$repo/issues/$parent/comments" | jq -r --arg m "<!-- $marker kind=split " \
  '[.[] | select(.body | split("\n")[0] | startswith($m))] | last | .body // empty' | grep -E '^\| *#[0-9]+ *\|' > "$tmp/rows" || true
[ -s "$tmp/rows" ] || { echo "#$parent に「## 分割の設計」（kind=split）の表が無い" >&2; exit 1; }

{
  # (1) 本文が同一の組（cksum が同じファイルを番号でまとめる）
  cksum "$tmp"/body-* | awk '{ sub(/.*body-/, "", $3); k = $1 " " $2; g[k] = (k in g) ? g[k] " #" $3 : "#" $3; c[k]++ }
    END { for (k in c) if (c[k] > 1) print "本文が同一: " g[k] }'
  # (2) 表の各行の番号と ID（2 列目の `E1-6` の形の語をすべて）
  while IFS= read -r row; do
    n=$(printf '%s\n' "$row" | sed -E 's/^\| *#([0-9]+).*/\1/')
    [ -f "$tmp/body-$n" ] || { echo "表の #$n は #$parent のサブ issue に無い"; continue; }
    for id in $(printf '%s\n' "$row" | cut -d'|' -f3 | grep -oE '[A-Z][0-9]*-[0-9]+' | sort -u); do
      grep -qFw -- "$id" "$tmp/body-$n" || echo "#$n の本文に表の $id が無い"
    done
  done < "$tmp/rows"
  for f in "$tmp"/body-*; do n=${f##*body-}; grep -qE "^\| *#$n *\|" "$tmp/rows" || echo "#$n は表に無い"; done
} > "$tmp/bad"
if [ -s "$tmp/bad" ]; then cat "$tmp/bad"; echo "不一致 $(wc -l < "$tmp/bad" | tr -d ' ') 件"; exit 1; fi
echo "#$parent のサブ issue $(wc -l < "$tmp/children" | tr -d ' ') 件は表と一致し、本文の重複は無い"
