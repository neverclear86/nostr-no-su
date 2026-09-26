#!/bin/sh
# 実行の前後の本体のカバレッジを、main への push で走った CI の test ジョブのログ
# （COVERAGE=1 の gleam test が最後に出す「coverage: <実行された行>/<行の合計> lines (<百分率>%)」）
# から取り出し、README のバッジと並べた Markdown を出す。ふりかえり（スキル issue-workflow の
# 「実行の後: ふりかえり」）で毎回呼び、実行の間にカバレッジが下がっていないかを確かめる。
#
# main の CI は連続したマージで取り消される（concurrency）ことがあるので、指定のコミットに
# 計測の行が無ければ first-parent を最大 30 個さかのぼり、行のある最も近いコミットを使う
# （表の「計測したコミット」に出す）。テストが 1 件落ちた実行でも計測の行は出るので使う。
# 指定のコミットの CI が走っている途中なら、終わるまで待つ。
#
# 判定は、終了が開始より 0.2 ポイントを超えて下がったら「低下」、終了の百分率を整数に丸めた値が
# README のバッジと違えば「バッジの更新が要る」（CI の dev/check_coverage_badge.sh は 1 ポイントまで
# 許すので、ずれが溜まる前にここで拾う）。最後の行に機械で読む verdict を出す
# （ok / drop / badge / drop,badge / unknown）。GitHub には何も書き込まない。
#
# 使い方: sh dev/coverage_delta.sh <開始のコミット> <終了のコミット>（gh と jq を使う）
set -eu
export LC_ALL=C

[ $# -eq 2 ] || { echo "usage: sh dev/coverage_delta.sh <start-commit> <end-commit>" >&2; exit 2; }
repo=neverclear86/nostr-no-su
root="$(git rev-parse --show-toplevel)"

# コミットに対応する main の CI の test ジョブのログから計測の行を 1 つ取り出す。無ければ空。
coverage_of() {
  for id in $(gh run list -R "$repo" --workflow ci.yml --branch main --commit "$1" \
    --json databaseId -q '.[].databaseId'); do
    status=$(gh run view "$id" -R "$repo" --json status -q .status)
    if [ "$status" != completed ] && [ "$1" = "$2" ]; then
      gh run watch "$id" -R "$repo" --interval 30 > /dev/null 2>&1 || true
    fi
    job=$(gh run view "$id" -R "$repo" --json jobs -q '.jobs[] | select(.name == "test") | .databaseId')
    [ -n "$job" ] || continue
    line=$(gh run view -R "$repo" --job "$job" --log 2>/dev/null \
      | grep -o 'coverage: [0-9]*/[0-9]* lines' | tail -n 1) || true
    [ -n "$line" ] && { echo "$line"; return; }
  done
}

# 指定のコミットから first-parent をさかのぼり、「<計測したコミット> <実行>/<合計>」を出す。無ければ空。
measure() {
  target=$(git -C "$root" rev-parse "$1")
  for c in $(git -C "$root" rev-list --first-parent -n 30 "$target"); do
    line=$(coverage_of "$c" "$target")
    if [ -n "$line" ]; then
      echo "$c $(echo "$line" | sed 's/coverage: \([0-9]*\/[0-9]*\) lines/\1/')"
      return
    fi
  done
}

git -C "$root" fetch -q origin main
start=$(measure "$1")
end=$(measure "$2")
badge=$(sed -n 's/.*coverage-\([0-9][0-9]*\)%25-[a-z]*.*/\1/p' "$root/README.md" | head -n 1)

echo "### カバレッジ（main の CI の test ジョブの計測）"
echo
echo "| 時点 | 指定 | 計測したコミット | 行 | 百分率 |"
echo "| --- | --- | --- | --- | --- |"
# 表の 1 行を出す。引数は時点の名前、measure の出力（空なら計測なし）、指定のコミット。
row() {
  if [ -z "$2" ]; then
    echo "| $1 | $(git -C "$root" rev-parse --short=7 "$3") | （30 個さかのぼっても計測の行が無い） | - | - |"
  else
    c=${2%% *}
    lines=${2#* }
    pct=$(echo "$lines" | awk -F/ '{ printf "%.2f", 100 * $1 / $2 }')
    echo "| $1 | $(git -C "$root" rev-parse --short=7 "$3") | $(echo "$c" | cut -c1-7) | $lines | $pct% |"
  fi
}
row 開始 "$start" "$1"
row 終了 "$end" "$2"
echo
echo "README のバッジ: ${badge:-（無い）}%"

if [ -z "$start" ] || [ -z "$end" ] || [ -z "$badge" ]; then
  echo "判定: 計測の値かバッジが取れなかった"
  echo "verdict: unknown"
  exit 0
fi
verdict=$(awk -v s="${start#* }" -v e="${end#* }" -v b="$badge" 'BEGIN {
  split(s, x, "/"); split(e, y, "/")
  sp = 100 * x[1] / x[2]; ep = 100 * y[1] / y[2]
  printf "差: %+.2f ポイント\n", ep - sp
  v = ""
  if (ep < sp - 0.2) v = "drop"
  if (sprintf("%.0f", ep) + 0 != b + 0) v = (v == "" ? "badge" : v ",badge")
  if (v == "") v = "ok"
  print v
}')
echo "$verdict" | head -n 1
v=$(echo "$verdict" | tail -n 1)
case "$v" in
  ok) echo "判定: 変化なし（下げ幅 0.2 ポイント以内、バッジと一致）" ;;
  drop) echo "判定: 低下（0.2 ポイントを超えて下がった）" ;;
  badge) echo "判定: バッジの更新が要る（sh dev/check_coverage_badge.sh --update）" ;;
  *) echo "判定: 低下し、バッジの更新も要る" ;;
esac
echo "verdict: $v"
