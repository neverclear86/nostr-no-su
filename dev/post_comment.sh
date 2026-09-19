#!/bin/sh
# issue/PR にワークフローのマーカー付きコメントを投稿する。マーカー行は引数から
# 機械的に作って本文ファイルの前に置き、`gh issue comment` / `gh pr comment` を
# `--body-file` で実行する。本文ファイルにはマーカーを書かせない（付け忘れと
# 二重付けを防ぐ）ので、1 行目が `<!-- nns ` で始まるファイルは拒否する。
#
# マーカーの書式と kind の意味は .claude/skills/issue-workflow/references/formats.md
# の「マーカー」を参照。引数の検査（kind、round、verdict、head、本文ファイル）で
# 1 つでも外れると、何も投稿せず終了コード 1 で終わる。
# GitHub には issue または PR へのコメント投稿だけを行う。
#
# 使い方: sh dev/post_comment.sh <issue|pr> <番号> <kind> <round> <verdict> <head> <本文ファイル>
set -eu

usage() { echo "usage: sh dev/post_comment.sh <issue|pr> <number> <kind> <round> <verdict> <head> <body-file>" >&2; }

[ $# -eq 7 ] || { usage; exit 1; }
target="$1"
number="$2"
kind="$3"
round="$4"
verdict="$5"
sha="$6"
body="$7"
repo=neverclear86/nostr-no-su

case "$target" in
  issue | pr) ;;
  *) echo "invalid target: $target" >&2; exit 1 ;;
esac

case "$number" in
  '' | *[!0-9]*) echo "invalid number: $number" >&2; exit 1 ;;
esac

case "$kind" in
  design | split | plan | plan-review | pr-review | fix | gate | summary | retro) ;;
  *) echo "invalid kind: $kind" >&2; exit 1 ;;
esac

case "$round" in
  '' | *[!0-9]*) echo "invalid round: $round" >&2; exit 1 ;;
esac

case "$verdict" in
  APPROVE | "REQUEST CHANGES" | NEEDS_USER | -) ;;
  *) echo "invalid verdict: $verdict" >&2; exit 1 ;;
esac

case "$sha" in
  -) ;;
  *[!0-9a-f]* | "") echo "invalid head: $sha" >&2; exit 1 ;;
  *)
    len=${#sha}
    [ "$len" -ge 7 ] && [ "$len" -le 40 ] || { echo "invalid head: $sha" >&2; exit 1; }
    ;;
esac

[ -s "$body" ] || { echo "body file does not exist or is empty: $body" >&2; exit 1; }
head -n 1 "$body" | grep -q '^<!-- nns ' && { echo "body file must not start with a marker: $body" >&2; exit 1; }

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
printf '<!-- nns kind=%s round=%s verdict=%s head=%s -->\n\n' "$kind" "$round" "$verdict" "$sha" > "$tmp"
cat "$body" >> "$tmp"

gh "$target" comment "$number" -R "$repo" --body-file "$tmp"
