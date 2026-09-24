# リリースのタグ（vX.Y.Z）が、本体と plugins-src/ の各プラグインの gleam.toml の version、および
# CHANGELOG.md の「## [X.Y.Z] - YYYY-MM-DD」の見出しと一致するかを検査する。
# 版の一致は dev/check_project_versions.sh、見出しの有無は dev/release_notes.sh に任せる。
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

sh "$root/dev/check_project_versions.sh" "$version" || status=1
sh "$root/dev/release_notes.sh" "$version" > /dev/null || status=1

exit "$status"
