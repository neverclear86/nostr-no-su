# vendor/stratus が、hex の上流の tar から Gleam の生成物を除き、vendor/stratus/patches/ の
# パッチをファイル名の順に当てたものと一致するかを検査する。上流の版と tar の SHA-256 は
# vendor/stratus/PATCH.md の「上流」の表から読む。
# 一致すれば 0 で終わる。一致しなければ残った差分を標準出力に出して 1 で終わる。
# 差分は patch -p1 で当たる形なので、パッチを足すときはこの出力をパッチのファイルにする
# （手順は PATCH.md）。vendor/stratus の中を git の追跡に関係なく比べるので、追跡していない
# ファイルも差分に出る。
# 使い方: sh dev/check_vendor_stratus.sh（curl、sha256sum、tar、patch、git を使う）
set -eu

vendor="$(cd "$(dirname "$0")/.." && pwd)/vendor/stratus"

# PATCH.md の表の行（| 項目 | `値` |）から、項目名 $1 の値をバッククォートの中から取り出す。
upstream_field() {
  sed -n "s/^| $1 | \`\([^\`]*\)\` |\$/\1/p" "$vendor/PATCH.md"
}

version=$(upstream_field '版')
sha256=$(upstream_field 'tar の SHA-256')
if [ -z "$version" ] || [ -z "$sha256" ]; then
  echo "vendor/stratus/PATCH.md has no upstream version or tar SHA-256" >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

curl -fsSL -o "$tmp/upstream.tar" "https://repo.hex.pm/tarballs/stratus-$version.tar"
actual=$(sha256sum "$tmp/upstream.tar" | cut -d ' ' -f 1)
if [ "$actual" != "$sha256" ]; then
  echo "stratus-$version.tar has SHA-256 $actual, expected $sha256" >&2
  exit 1
fi

# パッケージの中身は、hex の tar の中の contents.tar.gz にある。
mkdir "$tmp/a"
tar -xf "$tmp/upstream.tar" -C "$tmp" contents.tar.gz
tar -xzf "$tmp/contents.tar.gz" -C "$tmp/a"
# hex への公開のときに Gleam が生成したファイルを除く（理由は PATCH.md）。
(cd "$tmp/a" && rm -r include src/stratus.app.src src/stratus.erl src/stratus@*.erl)

for patch_file in "$vendor"/patches/*.patch; do
  # 行の位置がずれて当たったときに .orig のバックアップを作らせない（作ると差分に出る）。
  patch --quiet --strip=1 --fuzz=0 --no-backup-if-mismatch --directory="$tmp/a" --input="$patch_file"
done

cp -R "$vendor" "$tmp/b"
rm -r "$tmp/b/PATCH.md" "$tmp/b/patches"

cd "$tmp"
if git --no-pager diff --no-index --no-color --no-ext-diff --no-textconv --no-prefix a b; then
  echo "vendor/stratus matches stratus $version with the recorded patches" >&2
else
  echo "vendor/stratus differs from stratus $version with the recorded patches" >&2
  exit 1
fi
