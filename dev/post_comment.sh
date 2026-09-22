#!/bin/sh
# issue/PR にワークフローのマーカー付きコメントを投稿する。マーカー行は引数から
# 機械的に作って本文ファイルの前に置き、`gh issue comment` / `gh pr comment` を
# `--body-file` で実行する。本文ファイルにはマーカーを書かせない（付け忘れと
# 二重付けを防ぐ）ので、1 行目が `<!-- nns ` で始まるファイルは拒否する。
#
# マーカーの書式と kind の意味は .claude/skills/issue-workflow/references/formats.md
# の「マーカー」を参照。本文の最初の空でない行は kind に対応する見出し（同じ文書の各節の
# 見出し。`fix` は「レビュー（ラウンド R）の指摘への対応」「レビューの条件への対応」
# 「最終確認の指摘への対応」の 3 形）でなければならない。引数の検査（kind、round、verdict、
# head、本文ファイル）と見出しの検査で 1 つでも外れると、何も投稿せず終了コード 1 で終わる。
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

# kind ごとの見出しの形（formats.md の各節）。本文の最初の空でない行に掛ける。
case "$kind" in
  design) heading='## デザインの方針$' ;;
  split) heading='## 分割の設計$' ;;
  plan) heading='## 実装プラン（版 [0-9]+）$' ;;
  plan-review) heading='## プランレビュー（ラウンド [0-9]+）$' ;;
  pr-review) heading='## レビュー（ラウンド [0-9]+）$' ;;
  fix) heading='## (レビュー（ラウンド [0-9]+）の指摘|レビューの条件|最終確認の指摘)への対応（[0-9a-f]+）$' ;;
  gate) heading='## 最終確認$' ;;
  summary) heading='## まとめ$' ;;
  retro) heading='## 精査$' ;;
esac
first=$(grep -m 1 -v '^[[:space:]]*$' "$body" || true)
printf '%s\n' "$first" | grep -Eq "^$heading" || { echo "body file must start with the heading for kind=$kind (got: $first)" >&2; exit 1; }

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
printf '<!-- nns kind=%s round=%s verdict=%s head=%s -->\n\n' "$kind" "$round" "$verdict" "$sha" > "$tmp"
cat "$body" >> "$tmp"

gh "$target" comment "$number" -R "$repo" --body-file "$tmp"
