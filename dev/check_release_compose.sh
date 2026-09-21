#!/bin/sh
# docker-compose.release.yml が docker-compose.yml の写しで、違いがイメージの
# 取り方の 1 行だけ（build: . と image: の行）であることを確かめる。
# 一致すれば終了コード 0、しなければ 1 で終わる。
#
# docker-compose.yml を変えるときは docker-compose.release.yml にも同じ変更を
# 写し（逆も同じ）、このスクリプトを通すこと。2 つのファイルの間で違ってよいのは
# イメージの取り方の 1 行だけで、コメントを含むほかの行は 1 文字も違えない。
#
# 使い方: sh dev/check_release_compose.sh

set -eu
export LC_ALL=C

root="$(cd "$(dirname "$0")/.." && pwd)"
compose="$root/docker-compose.yml"
release="$root/docker-compose.release.yml"

build_line='    build: .'
image_line='    image: ghcr.io/neverclear86/nostr-no-su:${NOSTR_NO_SU_VERSION:-latest}'

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

failed=0

# grep -c は 0 件で終了コード 1 を返すので || true で件数だけを取る。
if [ "$(grep -c -F -x "$build_line" "$compose" || true)" != 1 ]; then
  echo 'docker-compose.yml does not have exactly one "    build: ." line' >&2
  failed=1
fi
if [ "$(grep -c -F -x "$image_line" "$release" || true)" != 1 ]; then
  echo "docker-compose.release.yml does not have exactly one \"$image_line\" line" >&2
  failed=1
fi
if [ "$(grep -c -F -x "$build_line" "$release" || true)" != 0 ]; then
  echo "docker-compose.release.yml builds from source" >&2
  failed=1
fi
[ "$failed" -eq 0 ] || exit 1

# イメージの取り方の 1 行を除いた残りが一致することを確かめる。
grep -v -F -x "$build_line" "$compose" > "$tmp/compose"
grep -v -F -x "$image_line" "$release" > "$tmp/release"

if diff -u --label docker-compose.yml --label docker-compose.release.yml "$tmp/compose" "$tmp/release"; then
  echo "docker-compose.release.yml matches docker-compose.yml" >&2
else
  echo "docker-compose.release.yml differs from docker-compose.yml outside the image line" >&2
  exit 1
fi
