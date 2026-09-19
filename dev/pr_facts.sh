#!/bin/sh
# PR の事実（head と base の SHA、差分の行数、閉じる issue、CI の各ジョブ）を gh で集め、
# 1 枚の Markdown の表にする。実装者が PR 本文の「## テストと検証」の直下に貼るので、
# 見出しは「###」で出す。PR レビュアーとマージ担当が同じ表で照合する。SHA と数値を
# モデルが転記しないためのもの。
#
# 差分の行数は GitHub の files API（git diff --numstat 相当）の合計とファイルごとの内訳。
# CI は gh pr checks の各ジョブの状態で、pending や fail があってもそのまま表に出す。
# GitHub には何も書き込まない。
#
# 使い方: sh dev/pr_facts.sh <PR 番号>（gh と jq を使う）
set -eu

[ $# -eq 1 ] || { echo "usage: sh dev/pr_facts.sh <pr-number>" >&2; exit 1; }
pr="$1"
repo=neverclear86/nostr-no-su

view=$(gh pr view "$pr" -R "$repo" --json \
  number,title,url,state,headRefName,headRefOid,baseRefName,baseRefOid,closingIssuesReferences,additions,deletions,changedFiles)
files=$(gh api --paginate "repos/$repo/pulls/$pr/files?per_page=100" --jq '.[]')
# gh pr checks は fail や pending があると 0 以外で終わるので、出力だけを使う。
checks=$(gh pr checks "$pr" -R "$repo" --json name,state,bucket,link 2>/dev/null) || true

echo "### PR #$pr の事実（$(date -u +%Y-%m-%dT%H:%MZ) 時点）"
echo
echo "| 項目 | 値 |"
echo "|--|--|"
printf '%s' "$view" | jq -r '
  "| 題 | \(.title | gsub("\\|"; "\\|")) |",
  "| URL | \(.url) |",
  "| 状態 | \(.state) |",
  "| head | `\(.headRefName)` \(.headRefOid) |",
  "| base | `\(.baseRefName)` \(.baseRefOid) |",
  "| 差分 | +\(.additions) / -\(.deletions)、\(.changedFiles) ファイル |",
  "| 閉じる issue | \(if (.closingIssuesReferences | length) == 0 then "無し" else
      (.closingIssuesReferences | map("#\(.number)") | join("、")) end) |"'

echo
echo "| ファイル | 状態 | 追加 | 削除 |"
echo "|--|--|--|--|"
printf '%s' "$files" | jq -r '"| `\(.filename)` | \(.status) | \(.additions) | \(.deletions) |"'
printf '%s' "$files" | jq -s -r '"| 合計 | \(length) ファイル | \(map(.additions) | add // 0) | \(map(.deletions) | add // 0) |"'

echo
echo "| CI のジョブ | 状態 | 結果 |"
echo "|--|--|--|"
if [ -z "$checks" ] || [ "$checks" = "[]" ]; then
  echo "| （無し） | - | - |"
else
  printf '%s' "$checks" | jq -r 'sort_by(.name) | .[] | "| \(.name) | \(.state) | [\(.bucket)](\(.link)) |"'
fi
