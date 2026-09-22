#!/bin/sh
# docker compose で起動するための .env を用意する。
#
# .env が無ければ .env.example を複製し、必須の 2 つ（ACCOUNT_MASTER_KEY と
# ADMIN_PASSWORD）と同梱の Postgres のパスワード（POSTGRES_PASSWORD。写した
# 「# POSTGRES_PASSWORD=nostr」の行を置き換える）を openssl で生成した値で埋める。
# ほかの変数は .env.example のとおり「# 」付きの既定値のまま写す
# （docs/configuration.md の「環境変数」の表を見て、変えるものだけ「# 」を外す）。
#
# .env があれば上書きしない（書いてあるマスターキーを失うと、保存したアカウントの
# 秘密鍵を復号できなくなる）。そのときは次の 2 つだけを行う。
#   - 必須の 2 つのうち、行が無いか値が空のものを生成した値で埋める
#   - .env.example にあって .env に無い変数を、.env.example の行のまま末尾に足す
# 値の入っている行は必須の 2 つを含めて変えない。POSTGRES_PASSWORD も変えない
# （postgres-data volume は初回の起動時のパスワードで初期化済みで、変えると
# 接続できなくなる）。
#
# どちらの場合も .env を 600 にする。生成した値は画面に出さない。
#
# 使い方: sh setup-env.sh [.env のパス]
#   パスを省くと、このスクリプトと同じディレクトリーの .env を使う。
#   .env.example は常にこのスクリプトと同じディレクトリーのものを読む。
set -eu
export LC_ALL=C

root="$(cd "$(dirname "$0")" && pwd)"
example="$root/.env.example"
env_file="${1:-$root/.env}"

[ -r "$example" ] || { echo "setup-env.sh: $example is missing" >&2; exit 1; }
command -v openssl > /dev/null 2>&1 || { echo "setup-env.sh: openssl is required" >&2; exit 1; }

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

# 変数の名前と値を 1 行にして返す。名前ごとに生成の方法が違う。
generate() {
  case "$1" in
    ACCOUNT_MASTER_KEY | POSTGRES_PASSWORD) printf '%s=%s\n' "$1" "$(openssl rand -hex 32)" ;;
    ADMIN_PASSWORD) printf 'ADMIN_PASSWORD=%s\n' "$(openssl rand -base64 24)" ;;
  esac
}

# .env の中で正規表現 $1 に合う最初の行を、行 $2 に置き換える。
replace_first() {
  awk -v re="$1" -v line="$2" '
    $0 ~ re && !done { print line; done = 1; next }
    { print }
  ' "$env_file" > "$tmp"
  cat "$tmp" > "$env_file"
}

# 「NAME=値」か「# NAME=値」の行の NAME を列挙する（dev/check_env_example.sh と同じ形）。
names() {
  sed -n 's/^\(# \)\{0,1\}\([A-Z][A-Z0-9_]*\)=.*$/\2/p' "$1"
}

if [ ! -e "$env_file" ]; then
  cp "$example" "$env_file"
  chmod 600 "$env_file"
  created=1
else
  created=0
fi
chmod 600 "$env_file"

# 必須の 2 つを埋める。値が空の行（= の後に何も無いか空白だけ）は置き換え、
# 行が無ければ末尾に足す。値のある行はそのまま残す。
filled=""
for name in ACCOUNT_MASTER_KEY ADMIN_PASSWORD; do
  line=$(generate "$name")
  if grep -q "^$name=[[:space:]]*$" "$env_file"; then
    replace_first "^$name=[[:space:]]*\$" "$line"
    filled="$filled $name"
  elif ! grep -q "^$name=" "$env_file"; then
    printf '%s\n' "$line" >> "$env_file"
    filled="$filled $name"
  fi
done

# 新しく作った .env では、写した「# POSTGRES_PASSWORD=…」の行を生成した値の行に
# 置き換える（既定の nostr のままにしない）。既存の .env の POSTGRES_PASSWORD の
# 行は変えず、行が無ければ下の処理が .env.example の行のまま末尾に足す。
if [ "$created" = 1 ] && grep -q '^# POSTGRES_PASSWORD=' "$env_file"; then
  replace_first '^# POSTGRES_PASSWORD=' "$(generate POSTGRES_PASSWORD)"
  filled="$filled POSTGRES_PASSWORD"
fi

# .env.example にあって .env に無い変数を、.env.example の行のまま足す。
added=""
names "$example" | sort > "$tmp.example"
names "$env_file" | sort > "$tmp.env"
missing=$(comm -23 "$tmp.example" "$tmp.env")
rm -f "$tmp.example" "$tmp.env"
if [ -n "$missing" ]; then
  {
    printf '\n# setup-env.sh が %s に足した、.env.example にあってこのファイルに無かった変数。\n' "$(date -u +%Y-%m-%d)"
    for name in $missing; do
      grep -m 1 "^\(# \)\{0,1\}$name=" "$example"
      added="$added $name"
    done
  } >> "$env_file"
fi

if [ "$created" = 1 ]; then
  echo "created $env_file from .env.example (mode 600)"
else
  echo "kept the existing $env_file (mode 600); values already set were not changed"
fi
[ -z "$filled" ] || echo "filled with generated values:$filled"
[ -z "$added" ] || echo "added from .env.example:$added"
echo "next: review $env_file, then run: docker compose up --build -d (from the published image: docker compose -f docker-compose.release.yml up -d)"
