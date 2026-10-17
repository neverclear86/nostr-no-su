#!/bin/sh
# ふりかえり（.claude/workflows/retrospective.js）に渡す events を、Workflow の journal から抽出して
# Workflow のスクリプトの形の JS ファイルに書く。journal ごとに started と result を key で突き合わせ、
# result だけを { label, phase, status, tier, pr, verdict, must, should, nit, designMust, lessons, sha,
# closedParents, conditions（件数） } に絞る（null の項目は落とす）。
# 書く JS は `export const meta = {...}` と `return { events: { "<journal のパス>": [...] } }` だけで、
# retrospective.js が args.eventsScript（このファイルの絶対パス）を workflow({ scriptPath }) で読んで events にする
# （Workflow のスクリプトはファイルを読めず、数十 KB の events は args にインラインで渡せない）。
# 出力先は Workflow が読める場所（セッションのスクラッチパッド）にする。journal には書き込まない。
#
# 使い方: sh dev/retro_events.sh <出力の JS ファイル> <journal>...
set -eu

[ $# -ge 2 ] || { echo "usage: sh dev/retro_events.sh <out.js> <journal>..." >&2; exit 1; }
out="$1"
shift
for j in "$@"; do [ -f "$j" ] || { echo "journal がない: $j" >&2; exit 1; }; done

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
for j in "$@"; do
  jq -s --arg p "$j" '{($p): ((map(select(.type=="started"))|INDEX(.key)) as $s | map(select(.type=="result") | {label:$s[.key].label, phase:$s[.key].phase} + (.result|{status,tier,pr,verdict,must,should,nit,designMust,lessons,sha,closedParents,conditions:(.conditions|length)}|with_entries(select(.value!=null)))))}' "$j"
done | jq -s 'add' > "$tmp"
# 学びの本文には \" や \n の JSON のエスケープが入るので、echo でなく printf '%s' で書く
{
  printf '%s\n' "export const meta = {" \
    "  name: 'retro-events'," \
    "  description: 'retrospective.js に渡す events（dev/retro_events.sh が journal から抽出した result イベント）'," \
    "}"
  printf 'return { events: %s }\n' "$(cat "$tmp")"
} > "$out"
echo "$out に $# 件の journal の events を書いた（$(jq '[.[] | length] | add' "$tmp") イベント）"
