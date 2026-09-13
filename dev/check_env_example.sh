#!/bin/sh
# docker-compose.yml の ${...} が渡す既定値と、.env.example の変数の行を
# 突き合わせる。一致すれば終了コード 0、しなければ 1 で終わる。
#
# .env.example の変数の行は「NAME=値」か「# NAME=値」の形だけを数える。
# 「# 」の後に他の語が続く行（説明文）は変数の行として扱わない。
#
# docker-compose.yml の ${...} を足す、消す、既定値を変えるときは、
# .env.example の行も合わせてこのスクリプトを通すこと。
#
# 使い方: sh dev/check_env_example.sh

set -eu
export LC_ALL=C

root="$(cd "$(dirname "$0")/.." && pwd)"
compose="$root/docker-compose.yml"
example="$root/.env.example"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# compose の注釈の行を除いた ${...} を 1 つずつ取り出し、NAME=既定値 の形に直す。
grep -v '^[[:space:]]*#' "$compose" | grep -o '\${[^}]*}' > "$tmp/references" || true
sed -n 's/^\${\([A-Z][A-Z0-9_]*\):\{0,1\}-\(.*\)}$/\1=\2/p' "$tmp/references" > "$tmp/parsed"
if [ "$(wc -l < "$tmp/references")" -ne "$(wc -l < "$tmp/parsed")" ]; then
  echo "docker-compose.yml has a variable reference without a default (use \${NAME-default} or \${NAME:-default}):" >&2
  grep -v '^\${[A-Z][A-Z0-9_]*:\{0,1\}-.*}$' "$tmp/references" >&2
  exit 1
fi
sort -u "$tmp/parsed" > "$tmp/compose"

# 同じ変数を別の既定値で参照していないか。
conflicting=$(cut -d = -f 1 "$tmp/compose" | uniq -d)
if [ -n "$conflicting" ]; then
  echo "docker-compose.yml gives different defaults to:" $conflicting >&2
  exit 1
fi

sed -n 's/^\(# \)\{0,1\}\([A-Z][A-Z0-9_]*=.*\)$/\2/p' "$example" | sort > "$tmp/example"
duplicated=$(cut -d = -f 1 "$tmp/example" | uniq -d)
if [ -n "$duplicated" ]; then
  echo ".env.example has more than one line for:" $duplicated >&2
  exit 1
fi

if diff -u --label docker-compose.yml --label .env.example "$tmp/compose" "$tmp/example"; then
  echo ".env.example matches the defaults in docker-compose.yml" >&2
else
  echo ".env.example does not match the defaults in docker-compose.yml" >&2
  exit 1
fi
