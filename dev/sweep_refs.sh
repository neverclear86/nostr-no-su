#!/bin/sh
# 語（識別子、環境変数、kind の番号、表名、画面名など）ごとに、作業ツリーの中の参照を
# git grep で列挙し、プランや PR 本文にそのまま貼れる Markdown の表にする。
# 変更する語の追随先（Doc コメント、文書、設定、テスト）の洗い出しに使う。
#
# 探す範囲は下の「設定」の paths の追跡されたファイル（build/ と node_modules は除く）。
# 語は大文字小文字を区別し、単語の境界で一致させる（git grep -w -F）。
# `Persist` は `Persisted` に一致しないので、部分一致が要るときは語を分けて渡す。
#
# 種別は次のとおり（判定の式は「設定」）。doc-comment: Doc コメントの行（テストの下でも）、test: テストのファイル、
# docs: 文書、config: 設定、code: それ以外。
# 0 件の語も「0 件」と出す（確かめたことの証拠になる）。作業ツリーには書き込まない。
#
# 使い方: sh dev/sweep_refs.sh <作業ツリー> <語>...
set -eu

[ $# -ge 2 ] || { echo "usage: sh dev/sweep_refs.sh <worktree> <word>..." >&2; exit 1; }
tree="$1"
shift
git -C "$tree" rev-parse --show-toplevel > /dev/null

# --- 設定（issue-workflow-kit が導入時に埋める） ---
# 探す範囲（空白区切り）。存在しないパスは git grep が黙って 0 件にする
paths='src test dev docs examples README.md README.ja.md CLAUDE.md CONTRIBUTING.md CHANGELOG.md NOTICE LICENSE .env.example setup-env.sh install.sh docker-compose.yml docker-compose.release.yml .claude .github plugins-src docker'
# 行の内容（先頭の空白を除く）が Doc コメントであることを表す awk の ERE
doc_re='^///'
# ファイルのパスで種別を決める awk の ERE（test、docs、config の順に見る）
test_re='^test/'
docs_re='^docs/|[.]md$|^(NOTICE|LICENSE)$'
config_re='^([.]env[.]example|[.]claude/|docker/)|[.](toml|yml|yaml)$'

echo "| 語 | ファイル:行 | 種別 | 行の内容 |"
echo "|--|--|--|--|"
summary=""
for word in "$@"; do
  # git grep は 0 件のとき 1、誤りのとき 2 以上で終わる。1 だけを 0 件として扱う。
  status=0
  # shellcheck disable=SC2086
  hits=$(git -C "$tree" grep -n -I -w -F -e "$word" -- $paths \
    ':(exclude)**/build/**' ':(exclude)**/node_modules/**') || status=$?
  [ "$status" -le 1 ] || exit "$status"
  if [ "$status" -eq 1 ]; then
    count=0
  else
    count=$(printf '%s\n' "$hits" | wc -l)
    # ファイル:行:内容 の 3 つ目以降を内容として、種別を付けて表の行にする。
    printf '%s\n' "$hits" | awk -v word="$word" -v doc_re="$doc_re" -v test_re="$test_re" -v docs_re="$docs_re" -v config_re="$config_re" -F ':' '
      {
        file = $1; line = $2
        text = substr($0, length(file) + length(line) + 3)
        sub(/^[ \t]+/, "", text)
        kind = "code"
        if (doc_re != "" && text ~ doc_re) kind = "doc-comment"
        else if (test_re != "" && file ~ test_re) kind = "test"
        else if (docs_re != "" && file ~ docs_re) kind = "docs"
        else if (config_re != "" && file ~ config_re) kind = "config"
        if (length(text) > 80) text = substr(text, 1, 77) "..."
        gsub(/\|/, "\\|", text); gsub(/`/, "\047", text)
        printf "| `%s` | %s:%s | %s | `%s` |\n", word, file, line, kind, text
      }'
  fi
  [ "$count" -gt 0 ] || echo "| \`$word\` | - | - | 0 件 |"
  summary="$summary
| \`$word\` | $count |"
done

echo
echo "| 語 | 件数 |"
echo "|--|--|$summary"
