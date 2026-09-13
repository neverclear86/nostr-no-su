#!/bin/sh
# erlang-shipment に、再配布の条件として求められるライセンスのファイルを集める。
# 本体の LICENSE と NOTICE、vendor/stratus の LICENSE と PATCH.md を NOTICE が指す相対パスに置き、
# shipment に入る Hex の依存ごとに、パッケージに含まれるライセンスのファイルを licenses/<アプリ名>/ に
# 写し、licenses/packages.txt に「アプリ名、宣言されたライセンス、ファイル」をタブ区切りで 1 行ずつ書く。
# 全項目を処理してから終わり、問題があればすべてを標準エラーに出して 1 で終わる。
# 直し方は CONTRIBUTING.md の「依存のライセンス」にある。
# 使い方: sh dev/collect_licenses.sh build/erlang-shipment
#（gleam deps download と gleam export erlang-shipment の後に実行する。Dockerfile の build ステージが実行する）
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
packages="$root/build/packages"
overrides="$root/dev/licenses-overrides.txt"
status=0
seen=" "

# 続けられない前提の欠落を出し、即座に 1 で終わる。
fail() {
  echo "collect_licenses: $*" >&2
  exit 1
}

# 1 項目の問題を出し、残りを処理してから 1 で終わるように記録する。
report() {
  echo "collect_licenses: $*" >&2
  status=1
}

# ファイルの「key = [...]」または「{key, [...]}」の配列を、引用符を除いたカンマ区切りで返す。
# 複数行に分かれた配列も読むため、改行を除いてから探す。
list_value() {
  tr -d '\n' <"$1" | grep -o "$2 *[=,] *\[[^]]*\]" | head -n 1 |
    sed 's/^[^[]*\[//; s/\]$//; s/"//g; s/ *, */,/g; s/^ *//; s/[ ,]*$//'
}

[ $# -ge 1 ] || fail "usage: sh dev/collect_licenses.sh <erlang-shipment dir>"
shipment="$1"
out="$shipment/licenses"

[ -d "$shipment" ] || fail "$shipment does not exist; run gleam export erlang-shipment first"
[ -d "$packages" ] || fail "$packages does not exist; run gleam deps download first"
[ -f "$overrides" ] || fail "$overrides does not exist"
mkdir -p "$shipment/vendor/stratus" "$out" || fail "cannot create directories in $shipment"
cp "$root/LICENSE" "$root/NOTICE" "$shipment/" || fail "cannot copy LICENSE and NOTICE"
cp "$root/vendor/stratus/LICENSE" "$root/vendor/stratus/PATCH.md" "$shipment/vendor/stratus/" ||
  fail "cannot copy vendor/stratus/LICENSE and vendor/stratus/PATCH.md"
: >"$out/packages.txt"

for package in "$packages"/*/; do
  package=${package%/}
  name=$(basename "$package")
  # shipment のディレクトリ名は、Gleam のパッケージは gleam.toml の name、Erlang のパッケージは
  # src/<アプリ名>.app.src のファイル名である（hex の hpack_erl は hpack として入る）。
  # どちらも無い形（mix のパッケージなど）はパッケージ名とみなし、宣言は読まない。
  set -- "$package"/src/*.app.src
  if [ -f "$package/gleam.toml" ]; then
    app=$(sed -n 's/^name *= *"\([^"]*\)".*/\1/p' "$package/gleam.toml" | head -n 1)
    declared=$(list_value "$package/gleam.toml" licences)
  elif [ -f "$1" ]; then
    app=$(basename "$1" .app.src)
    declared=$(list_value "$1" licenses)
  else
    app=$name
    declared=""
  fi
  if [ -z "$app" ]; then
    report "cannot read the application name of package $name"
    continue
  fi
  # 開発時だけの依存（gleeunit など）は shipment に入らないので除く。
  [ -d "$shipment/$app" ] || continue
  seen="$seen$app "

  files=""
  for file in "$package"/*; do
    base=$(basename "$file")
    printf '%s\n' "$base" | grep -qiE '^(licen[cs]e|copying|notice)' || continue
    if mkdir -p "$out/$app" && cp -R "$file" "$out/$app/"; then
      files="${files:+$files, }$base"
    else
      report "cannot copy $file"
    fi
  done

  if [ -z "$files" ]; then
    files="(no file in package)"
    if [ -z "$declared" ]; then
      # 宣言もファイルも無い依存は、上流で確かめたライセンスを overrides から読む。
      override=$(grep "^$app " "$overrides" | head -n 1)
      if [ -n "$override" ]; then
        declared=$(printf '%s\n' "$override" | cut -d ' ' -f 2)
        files="(no file in package; confirmed at $(printf '%s\n' "$override" | cut -d ' ' -f 3))"
      else
        report "$app declares no licence and contains no licence file; add it to dev/licenses-overrides.txt"
      fi
    fi
  fi
  printf '%s\t%s\t%s\n' "$app" "${declared:--}" "$files" >>"$out/packages.txt"
done

# shipment のアプリは、次の除外を除いてすべて build/packages のパッケージに対応するはずである。
for dir in "$shipment"/*/; do
  app=$(basename "$dir")
  case "$app" in
  # 本体、vendor/ に写した path の依存の stratus、このスクリプトの出力。
  nostr_no_su | stratus | vendor | licenses) continue ;;
  # ホストに Elixir があると gleam export erlang-shipment が同梱する Elixir の標準のアプリ
  # （Hex のパッケージではない）。Dockerfile の基底イメージには Elixir が無いのでイメージには入らない。
  eex | elixir | logger | mix) continue ;;
  esac
  case "$seen" in
  *" $app "*) ;;
  *) report "$app is in the shipment but no package in build/packages matches it" ;;
  esac
done

exit "$status"
