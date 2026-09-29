#!/bin/sh
# 承認済みプランの「### テスト」の表に挙がったテスト名が、作業ツリーの実装に揃っているかを
# 突き合わせる。プランにあって実装に無い名前を前に出し、PR レビューまで持ち越さないための
# 検査である。実行はしない。
#
# 読むのは「### テスト」の見出しから次の `##` の見出しまでにある表の行（`|` で始まる行）の
# 1 列目だけで、そこにある name_re に一致するバッククォート内の語をテスト名、`<helpers>/名前.sh` を shell の
# 検査のスクリプトとする（name_re と helpers は下の「設定」。以下の説明の `名前_test` は既定の name_re の例）。取り消し線で囲んだ名前（~~`名前_test`~~。取り消し線の内側に括弧の補足が
# あってもよい）は「消す」テストで、実装に無いことを確かめる。取り消し線の中の `<helpers>/名前.sh` は読まない
# （消す対象はテストだけ）。テストのモジュール名（test_dirs の下のテストのファイルの basename で、
# その名前のテストの定義が無い語。`dashboard_test` など）は、1 列目にあってもテスト名として数えない。
# 同じ節の文（表の外）に出る `名前_test` のうち、モジュール名でも作業ツリーにあるテスト名でもない
# もの（足す名前が表に無い）だけ、「表に載せる」の警告を出す（プランは 1 行に 1 つのテスト名か
# スクリプトを 1 列目に置く決まり）。文にあるファイルパスと作業ツリーにあるテスト名には警告を
# 出さない。
# 「検証の手順」に出る名前は読まない。実装側は、テスト名を作業ツリーの test_dirs の下の
# test_def に一致する行から、スクリプトを作業ツリーのファイルの実在から取る。
#
# 結果は Markdown の表（プランのテスト名 / 実装）で出す。足す名前がすべて実装にあり、消す名前が
# すべて実装に無ければ 0 で、1 件でも外れれば「無し」か「まだある」の行を出して 1 で終わる。
# 消す名前が実装に無いときは「実装に無い」と出す（一度も無かった名前と打ち間違いも同じ表示になる）。
# 警告は終了コードを変えない。
# 「### テスト」の節が無いとき、表の 1 列目にテスト名もスクリプトも 1 つも無いときも、契約の
# 形でないので 1 で終わる。ただし節に「テストの表は置かない」の文があれば（文書だけの変更）、
# 表を突き合わせずに 0 で終わる。改名したテストは
# 「無し」になるので、PR 本文の「プランからの変更」に対応表を書く。作業ツリーには書き込まない。
#
# 使い方: sh dev/check_plan_tests.sh <プランのファイル> <作業ツリー>
set -eu

# --- 設定（issue-workflow-kit が導入時に埋める。言語ごとの例は kit の references/adapting.md） ---
# プランの表に書くテスト名の形（awk の ERE。バッククォートの内側に一致させる）
name_re='[A-Za-z0-9_]*_test'
# 補助スクリプトの置き場（作業ツリーからの相対）
helpers='dev'
# テストのファイルを探すディレクトリ（作業ツリーからの相対。空白区切り、glob 可）とファイル名の形（find -name）
test_dirs='test plugins-src/*/test'
test_glob='*.gleam'
# テストを定義する行（grep -E）と、その行をテスト名だけにする sed -E の置換
test_def='^pub fn [A-Za-z0-9_]*_test\(\)'
test_name_sed='s/^pub fn ([A-Za-z0-9_]*_test)\(\).*/\1/'
# 表の外の文にあるテスト名の警告を出すか（テスト名が識別子でない言語では 0 にする）
prose_check=1

[ $# -eq 2 ] || { echo "usage: sh $helpers/check_plan_tests.sh <plan.md> <worktree>" >&2; exit 1; }
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

# 実装のテスト名と、その位置（ファイル:行）。モジュール名はテストのファイルの basename（拡張子を除く）。
dirs=""
for pat in $test_dirs; do
  # shellcheck disable=SC2086
  for d in "$tree"/$pat; do
    if [ -d "$d" ]; then dirs="$dirs $d"; fi
  done
done
[ -n "$dirs" ] || { echo "テストのディレクトリ（$test_dirs）が $tree に無い" >&2; exit 1; }
# shellcheck disable=SC2086
actual=$(find $dirs -type f -name "$test_glob" | sort | while IFS= read -r f; do
  grep -nE "$test_def" "$f" | while IFS= read -r hit; do
    printf '%s %s:%s\n' "$(printf '%s\n' "${hit#*:}" | sed -E "$test_name_sed")" "${f#"$tree"/}" "${hit%%:*}"
  done
done)
# shellcheck disable=SC2086
modules=$(find $dirs -type f -name "$test_glob" | sed 's|.*/||; s/\.[^.]*$//' | sort -u)
actual_names=$(printf '%s\n' "$actual" | awk '{ print $1 }')

# 名前の一覧（改行区切り）から、実装のテスト名でないモジュール名を除く。
drop_modules() {
  awk -v m="$modules" -v t="$actual_names" '
    BEGIN { n = split(m, a, "\n"); for (i = 1; i <= n; i++) mod[a[i]] = 1
            n = split(t, b, "\n"); for (i = 1; i <= n; i++) fn[b[i]] = 1 }
    NF && !(($0 in mod) && !($0 in fn))'
}

# 表の行の 1 列目。取り消し線の範囲（~~…~~。内側に補足があってもよい）にある `名前_test` は「消す」、
# 範囲の外の `名前_test` と `dev/名前.sh` は「足す・変える」（見出し行と区切り行にはバッククォートが無い）。
cells=$(printf '%s\n' "$section" | LC_ALL=C awk '/^[ \t]*\|/ { cell = $0; sub(/^[ \t]*\|/, "", cell); sub(/\|.*/, "", cell); print cell }')
removed=$(printf '%s\n' "$cells" | LC_ALL=C awk -v re="\`($name_re)\`" '
  {
    cell = $0
    while (match(cell, /~~[^~]*~~/)) {
      range = substr(cell, RSTART, RLENGTH)
      cell = substr(cell, RSTART + RLENGTH)
      while (match(range, re)) {
        print substr(range, RSTART + 1, RLENGTH - 2)
        range = substr(range, RSTART + RLENGTH)
      }
    }
  }
' | sort -u | drop_modules)
planned=$(printf '%s\n' "$cells" | LC_ALL=C awk -v re="\`(($name_re)|$helpers/[A-Za-z0-9_]+[.]sh)\`" '
  {
    cell = $0
    gsub(/~~[^~]*~~/, "", cell)
    while (match(cell, re)) {
      print substr(cell, RSTART + 1, RLENGTH - 2)
      cell = substr(cell, RSTART + RLENGTH)
    }
  }
' | sort -u | drop_modules)
[ -n "$planned$removed" ] || { echo "「### テスト」の表の 1 列目にテスト名（\`$name_re\`）も shell の検査（\`$helpers/名前.sh\`）も無い" >&2; exit 1; }

# 表の外の文にある `名前_test` のうち、表にも作業ツリーにも無いもの（足す名前が照合から外れる）。
prose=$(printf '%s\n' "$section" | LC_ALL=C awk -v re="\`($name_re)\`" -v on="$prose_check" '
  !on || /^[ \t]*\|/ { next }
  {
    line = $0
    while (match(line, re)) {
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
absent=0
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
    absent=$((absent + 1))
  fi
done
for name in $removed; do
  total=$((total + 1))
  where=$(printf '%s\n' "$actual" | awk -v n="$name" '$1 == n { print $2 }' | head -1)
  if [ -z "$where" ]; then
    echo "| ~~\`$name\`~~ | 実装に無い |"
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
  # 「無し」があるときだけ改名の案内を添える（「まだある」だけのときは消す対応で、対応表は要らない）
  if [ "$absent" -gt 0 ]; then hint="（改名したなら PR 本文の「プランからの変更」に対応表を書く）"; else hint=""; fi
  echo "プランのテスト $total 件のうち $missing 件が実装と揃っていない$hint"
  exit 1
fi
