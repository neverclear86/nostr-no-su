# リリースのタグ（vX.Y.Z）が、本体と plugins-src/ の各プラグインの gleam.toml の version、および
# CHANGELOG.md の「## [X.Y.Z] - YYYY-MM-DD」の見出しと一致するかを検査する。
# release.yml がイメージの公開の前に実行する。タグを切る前に手元でも実行する。
# 全項目が一致すれば 0 で終わる。どれかがずれていれば、ずれをすべて標準エラーに出して 1 で終わる。
# 使い方: sh dev/check_release_version.sh v0.1.0
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
[ $# -ge 1 ] || { echo "usage: sh dev/check_release_version.sh vX.Y.Z" >&2; exit 1; }
tag="$1"

if ! echo "$tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "tag $tag is not in the form vMAJOR.MINOR.PATCH" >&2
  exit 1
fi
version="${tag#v}"
status=0

for toml in gleam.toml $(cd "$root" && echo plugins-src/*/gleam.toml); do
  actual=$(sed -n 's/^version = "\([^"]*\)"$/\1/p' "$root/$toml")
  if [ "$actual" != "$version" ]; then
    echo "$toml has version \"$actual\", expected \"$version\"" >&2
    status=1
  fi
done

# 版の . を正規表現のリテラルにして見出しを探す。
heading="^## \[$(echo "$version" | sed 's/\./\\./g')\] - [0-9]{4}-[0-9]{2}-[0-9]{2}\$"
if [ ! -f "$root/CHANGELOG.md" ]; then
  echo "CHANGELOG.md does not exist" >&2
  status=1
elif ! grep -Eq "$heading" "$root/CHANGELOG.md"; then
  echo "CHANGELOG.md has no \"## [$version] - YYYY-MM-DD\" heading" >&2
  status=1
fi

exit "$status"
