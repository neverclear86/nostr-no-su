# 本体（gleam.toml）と plugins-src/ の各プラグインの gleam.toml の version が、すべて同じ値かを検査する。
# 引数に版（X.Y.Z）を渡せばその版と、渡さなければ本体の gleam.toml の version と比べる。
# ci.yml が引数なしで、dev/check_release_version.sh がタグの版を渡して実行する。
# 全部が一致すれば何も出さずに 0 で終わる。ずれていれば、ずれたファイルをすべて標準エラーに出して 1 で終わる。
# 使い方: sh dev/check_project_versions.sh [X.Y.Z]
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"

# gleam.toml の version の行の値を出す。
version_of() {
  sed -n 's/^version = "\([^"]*\)"$/\1/p' "$root/$1"
}

version="${1:-$(version_of gleam.toml)}"
status=0

for toml in gleam.toml $(cd "$root" && echo plugins-src/*/gleam.toml); do
  actual=$(version_of "$toml")
  if [ "$actual" != "$version" ]; then
    echo "$toml has version \"$actual\", expected \"$version\"" >&2
    status=1
  fi
done

exit "$status"
