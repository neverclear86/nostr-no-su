#!/bin/sh
# install.sh の動きを、偽の curl と docker を PATH の先頭に置いて確かめる（ネットワークに
# 出ない）。すべて通れば終了コード 0、食い違いがあれば理由を 1 行 stderr に出して 1 で終わる。
#
# 偽の curl は、releases/latest の転送先として版 9.8.7 のタグの URL を返し、ファイルの取得では
# URL の最後の要素と同じ名前のファイルをリポジトリのルートから写す。確かめること:
#   - 引数の名前でディレクトリーを作り、3 つのファイル、plugins/、600 の .env を置き、.env に
#     COMPOSE_FILE と NOSTR_NO_SU_VERSION=9.8.7 を 1 行ずつ足す。ファイルはタグ v9.8.7 から取る
#   - docker を実行せず、最後に cd と docker compose up -d の行を出す
#   - 既にあるパスと、版の無い転送先では 0 以外で終わり、ファイルを取らない
#   - 端末で入力した名前を使い、端末も引数も無ければ nostr-no-su を使って stderr に何も出さない
#
# script、setsid（util-linux）と env -C（coreutils）を使う。
#
# 使い方: sh dev/check_install.sh

set -eu
export LC_ALL=C

root="$(cd "$(dirname "$0")/.." && pwd)"
install="$root/install.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

bin="$tmp/bin"
work="$tmp/work"
mkdir -p "$bin" "$work"

# 偽の curl。呼ばれた引数を 1 行ずつ CURL_LOG に記録する。-w を渡されたら
# releases/latest の転送先として版 $FAKE_VERSION のタグの URL を出し、それ以外は
# URL の最後の要素と同じ名前のファイルをリポジトリのルートから -o の宛先へ写す。
cat > "$bin/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >> "$CURL_LOG"
redirect=""
dest=""
take_dest=""
for arg in "$@"; do
  if [ -n "$take_dest" ]; then dest=$arg; take_dest=""; continue; fi
  case $arg in
    -w*) redirect=1 ;;
    -o) take_dest=1 ;;
  esac
done
if [ -n "$redirect" ]; then
  printf '%s\n' "https://github.com/neverclear86/nostr-no-su/releases/tag/v$FAKE_VERSION"
else
  url=""
  for arg in "$@"; do url=$arg; done
  cp "$INSTALL_CHECK_ROOT/${url##*/}" "$dest"
fi
EOF

# 偽の docker。呼ばれたことを DOCKER_LOG に記録するだけで、何も実行しない。
cat > "$bin/docker" <<'EOF'
#!/bin/sh
printf 'docker %s\n' "$*" >> "$DOCKER_LOG"
EOF
chmod +x "$bin/curl" "$bin/docker"

export PATH="$bin:$PATH"
export CURL_LOG="$tmp/curl.log" DOCKER_LOG="$tmp/docker.log" INSTALL_CHECK_ROOT="$root"
export FAKE_VERSION=9.8.7
: > "$CURL_LOG"
: > "$DOCKER_LOG"

# 場合 1: 引数の名前で作る（標準入力がスクリプト自身の、curl | bash の形）。
mkdir "$work/one"
out=$(env -C "$work/one" bash -s -- mine < "$install")
mine="$work/one/mine"
for f in docker-compose.release.yml .env.example setup-env.sh; do
  cmp -s "$mine/$f" "$root/$f" || { echo "case 1: $f differs from the file at the repository root" >&2; exit 1; }
done
[ -d "$mine/plugins" ] || { echo "case 1: plugins/ was not created" >&2; exit 1; }
[ "$(stat -c %a "$mine/.env")" = 600 ] || { echo "case 1: .env is not mode 600" >&2; exit 1; }
[ "$(grep -cx 'COMPOSE_FILE=docker-compose.release.yml' "$mine/.env")" = 1 ] \
  || { echo "case 1: .env does not have exactly one COMPOSE_FILE=docker-compose.release.yml line" >&2; exit 1; }
[ "$(grep -cx 'NOSTR_NO_SU_VERSION=9.8.7' "$mine/.env")" = 1 ] \
  || { echo "case 1: .env does not have exactly one NOSTR_NO_SU_VERSION=9.8.7 line" >&2; exit 1; }
[ "$(grep -c 'raw\.githubusercontent\.com/neverclear86/nostr-no-su/v9\.8\.7/' "$CURL_LOG")" = 3 ] \
  || { echo "case 1: the three files were not fetched from tag v9.8.7" >&2; exit 1; }
[ ! -s "$DOCKER_LOG" ] || { echo "case 1: docker was executed" >&2; exit 1; }
abs_mine=$(cd "$mine" && pwd)
printf '%s\n' "$out" | grep -qF "next: cd $abs_mine && docker compose up -d" \
  || { echo "case 1: the output lacks the 'next: cd <dir> && docker compose up -d' line" >&2; exit 1; }

# 場合 2: 既にあるパスには何も取らずに 0 以外で終わる。
lines_before=$(wc -l < "$CURL_LOG")
if env -C "$work/one" bash -s -- mine < "$install" > /dev/null 2>&1; then
  echo "case 2: install.sh succeeded on an existing directory" >&2
  exit 1
fi
[ "$(wc -l < "$CURL_LOG")" = "$lines_before" ] \
  || { echo "case 2: install.sh fetched files for an existing directory" >&2; exit 1; }

# 場合 3: 転送先に版が無ければ 0 以外で終わり、ディレクトリーを作らない。
mkdir "$work/three"
if env -C "$work/three" FAKE_VERSION= bash -s -- nover < "$install" > /dev/null 2>&1; then
  echo "case 3: install.sh succeeded without a release version" >&2
  exit 1
fi
[ ! -e "$work/three/nover" ] || { echo "case 3: the directory was created" >&2; exit 1; }

# 場合 4: 端末で入力した名前を使う（script が割り当てた pty が install.sh の /dev/tty になる）。
mkdir "$work/four"
printf 'typed\n' | env -C "$work/four" script -qec "bash $install" /dev/null > /dev/null 2>&1 \
  || { echo "case 4: install.sh failed at the terminal" >&2; exit 1; }
[ -f "$work/four/typed/.env" ] || { echo "case 4: the directory named at the terminal was not created" >&2; exit 1; }

# 場合 5: 端末も引数も無ければ既定の名前を使い、stderr に何も出さない。
mkdir "$work/five"
errfile="$tmp/case5.stderr"
env -C "$work/five" setsid -w bash "$install" < /dev/null > /dev/null 2> "$errfile" \
  || { echo "case 5: install.sh failed without a terminal" >&2; exit 1; }
[ -f "$work/five/nostr-no-su/.env" ] || { echo "case 5: the default directory was not created" >&2; exit 1; }
[ ! -s "$errfile" ] || { echo "case 5: stderr was not empty:" >&2; cat "$errfile" >&2; exit 1; }

echo "install.sh: ok"
