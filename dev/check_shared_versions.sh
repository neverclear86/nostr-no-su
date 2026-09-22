# 本体と plugins-src/ の各プラグインの manifest.toml の packages に共通する名前の版が、
# すべて一致するかを検査する。
# 影に入る側は本体の版で実行されるため、版がずれると読み込み時には何も起きず、実行時に
# undef で壊れる。CI の唯一の自動検出点である。
# プラグインにだけあるパッケージは検査しない。開発用の依存も共通なら検査する。
# 一致すればプラグインごとに件数を 1 行出して 0 で、ずれていればずれたパッケージと両方の版を出して 1 で終わる。
# gleam_stdlib が読み取れなければ 1 で終わる。メッセージは標準エラーに出す。
# 使い方: sh dev/check_shared_versions.sh（awk を使う）
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
status=0

for manifest in "$root"/plugins-src/*/manifest.toml; do
  # manifest.toml の packages の行（  { name = "…", version = "…", …）だけを読む。
  # 1 つめのファイル（本体）で版を覚え、2 つめ（プラグイン）で共通する名前の版を比べる。
  awk -F '"' -v name="$(basename "$(dirname "$manifest")")" '
    !/^  \{ name = "[^"]*", version = "/ { next }
    FNR == NR { host[$2] = $4; next }
    $2 in host {
      shared++
      if ($2 == "gleam_stdlib") stdlib = 1
      if (host[$2] != $4) { print "version mismatch: " $2 " (host " host[$2] ", " name " " $4 ")"; bad = 1 }
    }
    END {
      if (!stdlib) { print "gleam_stdlib is not found in both manifest.toml files"; exit 1 }
      if (bad) exit 1
      print name ": the " shared " shared packages match the host versions"
    }' "$root/manifest.toml" "$manifest" >&2 || status=1
done

exit "$status"
