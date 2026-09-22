#!/bin/sh
# setup-env.sh の POSTGRES_PASSWORD の扱いを確かめる。すべて通れば終了コード 0、
# 食い違いがあれば理由を 1 行 stderr に出して 1 で終わる。
#
# 一時ディレクトリーの .env に対して sh setup-env.sh <パス> を実行して確かめる:
#   - .env を新しく作るとき: コメントでない POSTGRES_PASSWORD=<値> の行が 1 行だけ
#     入り、値は 64 文字の 16 進で nostr ではない。「# POSTGRES_PASSWORD=」の行は
#     残らず、生成した値は標準出力に出ない
#   - 既存の .env のとき: POSTGRES_PASSWORD の行は変わらない。「# POSTGRES_PASSWORD=nostr」
#     の行を持つものと「POSTGRES_PASSWORD=secretvalue」の行を持つものはそのままで、
#     行を持たないものには .env.example の「# POSTGRES_PASSWORD=nostr」の行が足される
#
# 使い方: sh dev/check_setup_env.sh

set -eu
export LC_ALL=C

root="$(cd "$(dirname "$0")/.." && pwd)"
setup="$root/setup-env.sh"
example="$root/.env.example"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# .env を新しく作るときは、写した「# POSTGRES_PASSWORD=nostr」の行が生成した
# 値の行に置き換わる。
mkdir "$tmp/new"
env_file="$tmp/new/.env"
out=$(sh "$setup" "$env_file")

if [ "$(grep -c '^POSTGRES_PASSWORD=' "$env_file" || true)" != 1 ]; then
  echo "new .env does not have exactly one uncommented POSTGRES_PASSWORD= line" >&2
  exit 1
fi
value=$(sed -n 's/^POSTGRES_PASSWORD=\(.*\)$/\1/p' "$env_file")
if ! printf '%s\n' "$value" | grep -qx '[0-9a-f]\{64\}'; then
  echo "new .env POSTGRES_PASSWORD is not a 64-character hex value" >&2
  exit 1
fi
if [ "$value" = nostr ]; then
  echo "new .env POSTGRES_PASSWORD is the default nostr" >&2
  exit 1
fi
if grep -q '^# POSTGRES_PASSWORD=' "$env_file"; then
  echo "new .env still has a commented-out POSTGRES_PASSWORD= line" >&2
  exit 1
fi
if printf '%s\n' "$out" | grep -qF "$value"; then
  echo "setup-env.sh printed the generated POSTGRES_PASSWORD" >&2
  exit 1
fi

# 既存の .env では POSTGRES_PASSWORD の行を変えない。
mkdir "$tmp/commented"
printf 'ACCOUNT_MASTER_KEY=x\nADMIN_PASSWORD=y\n# POSTGRES_PASSWORD=nostr\n' > "$tmp/commented/.env"
sh "$setup" "$tmp/commented/.env" > /dev/null
if [ "$(grep 'POSTGRES_PASSWORD' "$tmp/commented/.env")" != '# POSTGRES_PASSWORD=nostr' ]; then
  echo "existing .env with '# POSTGRES_PASSWORD=nostr' had its POSTGRES_PASSWORD lines changed" >&2
  exit 1
fi

mkdir "$tmp/filled"
printf 'ACCOUNT_MASTER_KEY=x\nADMIN_PASSWORD=y\nPOSTGRES_PASSWORD=secretvalue\n' > "$tmp/filled/.env"
sh "$setup" "$tmp/filled/.env" > /dev/null
if [ "$(grep 'POSTGRES_PASSWORD' "$tmp/filled/.env")" != 'POSTGRES_PASSWORD=secretvalue' ]; then
  echo "existing .env with 'POSTGRES_PASSWORD=secretvalue' had its POSTGRES_PASSWORD lines changed" >&2
  exit 1
fi

# POSTGRES_PASSWORD の行を持たない既存の .env には、.env.example の行が足される。
example_line=$(grep -m 1 '^# POSTGRES_PASSWORD=' "$example")
mkdir "$tmp/missing"
printf 'ACCOUNT_MASTER_KEY=x\nADMIN_PASSWORD=y\n' > "$tmp/missing/.env"
sh "$setup" "$tmp/missing/.env" > /dev/null
if [ "$(grep 'POSTGRES_PASSWORD' "$tmp/missing/.env")" != "$example_line" ]; then
  echo "existing .env without POSTGRES_PASSWORD did not get the .env.example line appended" >&2
  exit 1
fi

echo "setup-env.sh: ok"
