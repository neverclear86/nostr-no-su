#!/bin/sh
# 承認済みプランの「### テスト」の表に挙がったテスト名が、作業ツリーの実装に揃っているかを
# 突き合わせる。プランにあって実装に無い名前を前に出し、PR レビューまで持ち越さないための
# 検査である。実行はしない。
#
# 読むのは「### テスト」の見出しから次の `##` の見出しまでにある表の行（`|` で始まる行）の
# 1 列目だけで、そこにある `名前_test` のバッククォート内の語をテスト名、`dev/名前.sh` を shell の
# 検査のスクリプトとする。取り消し線で囲んだ名前（~~`名前_test`~~）は「消す」テストで、実装に
# 無いことを確かめる。テストのモジュール名（test/ 以下に `<名前>.gleam` があり、その名前の
# `pub fn` が無い語。`dashboard_test` など）は、1 列目にあってもテスト名として数えない。
# 同じ節の文（表の外）に出る `名前_test` のうち、モジュール名でも土台にあるテスト名でもないもの
# （足す名前が表に無い）だけ、「表に載せる」の警告を出す（プランは 1 行に 1 つのテスト名か
# スクリプトを 1 列目に置く決まり）。文にあるファイルパスと既存のテスト名には警告を出さない。
# 「検証の手順」に出る名前は読まない。実装側は、テスト名を作業ツリーの test/ と
# plugins-src/*/test/ の `pub fn 名前_test()` から、スクリプトを作業ツリーのファイルの実在から取る。
#
# 結果は Markdown の表（プランのテスト名 / 実装）で出す。足す名前がすべて実装にあり、消す名前が
# すべて実装に無ければ 0 で、1 件でも外れれば「無し」か「まだある」の行を出して 1 で終わる。
# 警告は終了コードを変えない。
# 「### テスト」の節が無いとき、表の 1 列目にテスト名もスクリプトも 1 つも無いときも、契約の
# 形でないので 1 で終わる。ただし節に「テストの表は置かない」の文があれば（文書だけの変更）、
# 表を突き合わせずに 0 で終わる。改名したテストは
# 「無し」になるので、PR 本文の「プランからの変更」に対応表を書く。作業ツリーには書き込まない。
#
# 使い方: sh dev/check_plan_tests.sh <プランのファイル> <作業ツリー>
set -eu

[ $# -eq 2 ] || { echo "usage: sh dev/check_plan_tests.sh <plan.md> <worktree>" >&2; exit 1; }
file="$1"
tree="$2"
[ -f "$file" ] || { echo "$file does not exist" >&2; exit 1; }
git -C "$tree" rev-parse --show-toplevel > /dev/null

grep -q '^### テスト' "$file" || { echo "「### テスト」の節が $file に無い" >&2; exit 1; }

# 「### テスト」の節の本文（次の `##` の見出しまで）。
section=$(LC_ALL=C awk '/^### テスト/ { s = 1; next } s && /^##/ { exit } s' "$file")
if printf '%s\n' "$section" | grep -qF 'テストの表は置かない'; then
  echo "プランの「### テスト」は「テストの表は置かない」と明記している（文書だけの変更）。突き合わせるテストは無い"
  exit 0
fi

# 実装のテスト名と、その位置（ファイル:行）。モジュール名は test/ 以下の .gleam の basename。
dirs=""
for d in "$tree/test" "$tree"/plugins-src/*/test; do
  if [ -d "$d" ]; then dirs="$dirs $d"; fi
done
# shellcheck disable=SC2086
actual=$(find $dirs -name '*.gleam' -exec grep -Hn '^pub fn [A-Za-z0-9_]*_test()' {} + \
  | sed "s|^$tree/||; s/^\(.*\):\([0-9]*\):pub fn \([A-Za-z0-9_]*_test\)().*/\3 \1:\2/")
# shellcheck disable=SC2086
modules=$(find $dirs -name '*.gleam' | sed 's|.*/||; s/\.gleam$//' | sort -u)
actual_names=$(printf '%s\n' "$actual" | awk '{ print $1 }')

# 名前の一覧（改行区切り）から、実装のテスト名でないモジュール名を除く。
drop_modules() {
  awk -v m="$modules" -v t="$actual_names" '
    BEGIN { n = split(m, a, "\n"); for (i = 1; i <= n; i++) mod[a[i]] = 1
            n = split(t, b, "\n"); for (i = 1; i <= n; i++) fn[b[i]] = 1 }
    NF && !(($0 in mod) && !($0 in fn))'
}

# 表の行の 1 列目。取り消し線の名前（~~`名前_test`~~）は「消す」、残りの `名前_test` と
# `dev/名前.sh` は「足す・変える」（見出し行と区切り行にはバッククォートが無い）。
cells=$(printf '%s\n' "$section" | LC_ALL=C awk '/^[ \t]*\|/ { cell = $0; sub(/^[ \t]*\|/, "", cell); sub(/\|.*/, "", cell); print cell }')
removed=$(printf '%s\n' "$cells" | LC_ALL=C awk '
  {
    cell = $0
    while (match(cell, /~~`[A-Za-z0-9_]*_test`~~/)) {
      print substr(cell, RSTART + 3, RLENGTH - 6)
      cell = substr(cell, RSTART + RLENGTH)
    }
  }
' | sort -u | drop_modules)
planned=$(printf '%s\n' "$cells" | LC_ALL=C awk '
  {
    cell = $0
    gsub(/~~`[A-Za-z0-9_]*_test`~~/, "", cell)
    while (match(cell, /`([A-Za-z0-9_]*_test|dev\/[A-Za-z0-9_]+\.sh)`/)) {
      print substr(cell, RSTART + 1, RLENGTH - 2)
      cell = substr(cell, RSTART + RLENGTH)
    }
  }
' | sort -u | drop_modules)
[ -n "$planned$removed" ] || { echo "「### テスト」の表の 1 列目にテスト名（\`名前_test\`）も shell の検査（\`dev/名前.sh\`）も無い" >&2; exit 1; }

# 表の外の文にある `名前_test` のうち、表にも土台にも無いもの（足す名前が照合から外れる）。
prose=$(printf '%s\n' "$section" | LC_ALL=C awk '
  /^[ \t]*\|/ { next }
  {
    line = $0
    while (match(line, /`[A-Za-z0-9_]*_test`/)) {
      print substr(line, RSTART + 1, RLENGTH - 2)
      line = substr(line, RSTART + RLENGTH)
    }
  }
' | sort -u | drop_modules)
unlisted=$(printf '%s\n' "$prose" | awk -v p="$planned
$removed" -v t="$actual_names" '
  BEGIN { n = split(p, a, "\n"); for (i = 1; i <= n; i++) seen[a[i]] = 1
          n = split(t, b, "\n"); for (i = 1; i <= n; i++) seen[b[i]] = 1 }
  NF && !seen[$0]')

echo "| プランのテスト名・スクリプト | 実装 |"
echo "|--|--|"
missing=0
total=0
for name in $planned; do
  total=$((total + 1))
  case $name in
    *.sh) if [ -f "$tree/$name" ]; then where=$name; else where=""; fi ;;
    *) where=$(printf '%s\n' "$actual" | awk -v n="$name" '$1 == n { print $2 }' | head -1) ;;
  esac
  if [ -n "$where" ]; then
    echo "| \`$name\` | \`$where\` |"
  else
    echo "| \`$name\` | 無し |"
    missing=$((missing + 1))
  fi
done
for name in $removed; do
  total=$((total + 1))
  where=$(printf '%s\n' "$actual" | awk -v n="$name" '$1 == n { print $2 }' | head -1)
  if [ -z "$where" ]; then
    echo "| ~~\`$name\`~~ | 消した |"
  else
    echo "| ~~\`$name\`~~ | まだある \`$where\` |"
    missing=$((missing + 1))
  fi
done
echo
for name in $unlisted; do
  echo "警告: 「### テスト」の文にある \`$name\` は表に無い（プランは表の 1 列目に載せる決まり。突き合わせていない）"
done
if [ "$missing" -eq 0 ]; then
  echo "プランのテスト $total 件はすべて実装と揃っている"
else
  echo "プランのテスト $total 件のうち $missing 件が実装と揃っていない（改名したなら PR 本文の「プランからの変更」に対応表を書く）"
  exit 1
fi
