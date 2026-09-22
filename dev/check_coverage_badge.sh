#!/bin/sh
# README.md と README.ja.md のカバレッジのバッジ（coverage-<整数>%25-<色>）を、
# COVERAGE=1 を付けた gleam test の計測値（build/coverage.txt の total の行から
# 整数に丸めた百分率）と突き合わせる。どちらの差も 1 ポイント以内なら 0、超えて
# いれば食い違いを出して 1 で終わる。
#
# 計測の対象は本体の src/ のモジュールだけである（vendor/、hex の依存、
# plugins-src/、test/、dev/ は入れない。バッジが名乗るのは本体の
# カバレッジで、同梱プラグインはそれぞれ別の gleam test で走る別のプロジェクト
# なので 1 つの数値にまとめない）。
#
# 計測値は環境で変わる（E2E が走るかどうかで動く）ので、完全一致ではなく
# 1 ポイントの許容を置く。ずれを直すときは --update で両方の README のバッジを
# 計測値に書き換える（色は 80 以上 brightgreen、60 以上 yellow、それ未満 red）。
#
# 使い方: sh dev/check_coverage_badge.sh [--update]
#   先に COVERAGE=1 gleam test を実行して build/coverage.txt を作っておくこと。

set -eu
export LC_ALL=C

case "${1:-}" in
  "" | --update) ;;
  *) echo "usage: sh dev/check_coverage_badge.sh [--update]" >&2; exit 1 ;;
esac

root="$(git rev-parse --show-toplevel)"
report="$root/build/coverage.txt"
readmes="$root/README.md $root/README.ja.md"

if [ ! -f "$report" ]; then
  echo "build/coverage.txt is missing; run: COVERAGE=1 gleam test" >&2
  exit 1
fi
measured=$(awk '$1 == "total" { printf "%.0f", 100 * $2 / $3; exit }' "$report")
if [ -z "$measured" ]; then
  echo "build/coverage.txt has no total line; run: COVERAGE=1 gleam test" >&2
  exit 1
fi

if [ "${1:-}" = "--update" ]; then
  if [ "$measured" -ge 80 ]; then
    color=brightgreen
  elif [ "$measured" -ge 60 ]; then
    color=yellow
  else
    color=red
  fi
  for f in $readmes; do
    sed -i "s/coverage-[0-9][0-9]*%25-[a-z]*/coverage-${measured}%25-${color}/" "$f"
  done
  exit 0
fi

fail=0
for f in $readmes; do
  badge=$(sed -n 's/.*coverage-\([0-9][0-9]*\)%25-[a-z]*.*/\1/p' "$f" | head -n 1)
  rel=${f#$root/}
  if [ -z "$badge" ]; then
    echo "$rel: no coverage badge found" >&2
    fail=1
    continue
  fi
  d=$((badge - measured))
  if [ "$d" -lt 0 ]; then d=$((-d)); fi
  if [ "$d" -gt 1 ]; then
    echo "$rel: badge ${badge}% but measured ${measured}% (run: sh dev/check_coverage_badge.sh --update)" >&2
    fail=1
  fi
done
[ "$fail" -eq 0 ]
