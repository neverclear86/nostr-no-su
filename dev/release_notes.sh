# CHANGELOG.md の「## [X.Y.Z] - YYYY-MM-DD」の節の本文を標準出力に出す。
# 本文は見出しの次の行から、次の「## 」の見出しかリンクの参照定義（[…]: …）の前までで、前後の空行は除く。
# release.yml が GitHub Release の本文に、dev/check_release_version.sh が見出しの有無の検査に使う。
# 見出しがあれば 0 で終わる。CHANGELOG.md か見出しが無ければ、理由を標準エラーに出して 1 で終わる。
# 使い方: sh dev/release_notes.sh 0.1.0
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
[ $# -ge 1 ] || { echo "usage: sh dev/release_notes.sh X.Y.Z" >&2; exit 1; }
version="$1"

if [ ! -f "$root/CHANGELOG.md" ]; then
  echo "CHANGELOG.md does not exist" >&2
  exit 1
fi

# 版の . を正規表現のリテラルにして見出しを探す。
heading="^## \[$(echo "$version" | sed 's/\./\\./g')\] - [0-9]{4}-[0-9]{2}-[0-9]{2}\$"
start=$(grep -En "$heading" "$root/CHANGELOG.md" | head -n 1 | cut -d: -f1)
if [ -z "$start" ]; then
  echo "CHANGELOG.md has no \"## [$version] - YYYY-MM-DD\" heading" >&2
  exit 1
fi

# 見出しの後の行を読み、最初の空でない行より前の空行を捨て、末尾の空行は出さない。
awk -v start="$start" '
  NR <= start { next }
  /^## / || /^\[[^]]*\]: / { exit }
  /^$/ { if (started) blank++; next }
  {
    for (; blank > 0; blank--) print ""
    print
    started = 1
  }' "$root/CHANGELOG.md"
