#!/bin/sh
# 公開イメージ（ghcr.io/neverclear86/nostr-no-su）で動かすディレクトリーを作る。
# README の「インストール」の、手で行う手順と同じことを行う。
#
# 1. 作るディレクトリーを決める。空でない引数があればそれを使い、無ければ端末で名前を聞く
#    （空のまま Enter で nostr-no-su）。端末が無ければ聞かずに nostr-no-su を使う。
#    そのパスが既にあれば何もせずに終わる（既存の構成の更新は docs/operations.md の「更新」）。
# 2. GitHub Releases の最新の版 X.Y.Z を、releases/latest の転送先のタグ vX.Y.Z から調べる。
# 3. タグ vX.Y.Z から docker-compose.release.yml、.env.example、setup-env.sh を取り、
#    plugins/ を作って、setup-env.sh で .env を作る。
# 4. .env の末尾に COMPOSE_FILE=docker-compose.release.yml と NOSTR_NO_SU_VERSION=X.Y.Z を足す。
#
# docker compose は実行しない。最後に、次に実行する cd と docker compose up -d を出す。
# このファイルは main から配るが、取るファイルとイメージの版は Release のタグに揃える。
#
# 使い方: curl -fsSL https://raw.githubusercontent.com/neverclear86/nostr-no-su/main/install.sh | bash
#   名前を聞かずに進めるなら、末尾を | bash -s -- <ディレクトリー> にする。
set -eu

repo=neverclear86/nostr-no-su
default_dir=nostr-no-su

# install.sh: <文> を stderr に出して 1 で終わる。
fail() {
  echo "install.sh: $1" >&2
  exit 1
}

# Releases の最新の版（X.Y.Z）を、releases/latest の転送先の URL から取り出して出す。
latest_version() {
  url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$repo/releases/latest") \
    || fail "could not reach GitHub to find the latest release"
  version=${url##*/tag/v}
  printf '%s\n' "$version" | grep -qx '[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*' \
    || fail "could not find the latest release version in $url"
  printf '%s\n' "$version"
}

# 作るディレクトリーのパスを出す。空でない引数が無ければ端末で聞き、端末が無ければ既定の名前にする。
ask_dir() {
  if [ -n "${1-}" ]; then printf '%s\n' "$1"; return; fi
  if (: < /dev/tty) 2> /dev/null; then
    printf 'Directory to create [%s]: ' "$default_dir" > /dev/tty
    read -r answer < /dev/tty || answer=""
    printf '%s\n' "${answer:-$default_dir}"
  else
    printf '%s\n' "$default_dir"
  fi
}

# ディレクトリーを作り、最新の版のファイルを取って .env を用意し、次に実行するコマンドを出す。
main() {
  dir=$(ask_dir "$@")
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    fail "$dir already exists; choose another directory (to upgrade an existing one, see docs/operations.md)"
  fi
  version=$(latest_version)
  mkdir -p "$dir/plugins"
  base="https://raw.githubusercontent.com/$repo/v$version"
  for file in docker-compose.release.yml .env.example setup-env.sh; do
    curl -fsSL -o "$dir/$file" "$base/$file" \
      || fail "could not download $base/$file; remove $dir and run again"
  done
  out=$(sh "$dir/setup-env.sh") || fail "setup-env.sh failed; remove $dir and run again"
  printf '%s\n' "$out" | sed '/^next: /d'
  printf 'COMPOSE_FILE=docker-compose.release.yml\nNOSTR_NO_SU_VERSION=%s\n' "$version" >> "$dir/.env"
  abs=$(cd "$dir" && pwd)
  printf 'installed Nostr-no-Su %s in %s\n' "$version" "$abs"
  printf 'next: cd %s && docker compose up -d\n' "$abs"
}

# 取得が途中で切れたときに一部だけが実行されないよう、全体を main に包んで最後に呼ぶ。
main "$@"
