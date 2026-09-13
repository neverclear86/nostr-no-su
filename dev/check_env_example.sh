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
# ${DATABASE_URL-postgres://${POSTGRES_USER:-nostr}:...} のような入れ子の
# 参照は、内側から外側へ 1 段ずつ既定値に展開して読む。内側の変数
# （POSTGRES_USER など）も、外側の変数（DATABASE_URL）とは別に 1 行として
# 数える。
#
# 使い方: sh dev/check_env_example.sh

set -eu
export LC_ALL=C

root="$(cd "$(dirname "$0")/.." && pwd)"
compose="$root/docker-compose.yml"
example="$root/.env.example"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# compose の注釈の行を除いた ${...} を、入れ子の無いもの（波括弧を含まない
# もの）から順に取り出して references に足し、既定値に置き換える。置き換える
# ものが無くなるまで繰り返すと、入れ子は内側から展開される。
grep -v '^[[:space:]]*#' "$compose" > "$tmp/text"
: > "$tmp/references"
while :; do
  grep -o '\${[^${}]*}' "$tmp/text" >> "$tmp/references" || true
  sed 's/\${[A-Z][A-Z0-9_]*:\{0,1\}-\([^${}]*\)}/\1/g' "$tmp/text" > "$tmp/next"
  cmp -s "$tmp/text" "$tmp/next" && break
  mv "$tmp/next" "$tmp/text"
done

# ここまでの繰り返しですべて展開できていれば ${ は残らない。既定値の無い
# 参照、小文字の名前、既定値に $ を含む参照（${X-a$$b}）は置き換わらずに
# 残るので、ここで拾う。
if grep -q '\${' "$tmp/text"; then
  echo "docker-compose.yml has a variable reference that is not \${NAME-default} or \${NAME:-default}:" >&2
  grep '\${' "$tmp/text" >&2
  exit 1
fi

sed 's/^\${\([A-Z][A-Z0-9_]*\):\{0,1\}-\(.*\)}$/\1=\2/' "$tmp/references" | sort -u > "$tmp/compose"

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
