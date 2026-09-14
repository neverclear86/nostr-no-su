#!/bin/sh
# プランの「検証の手順」のような Markdown の番号付きの手順を読み、「手順は 1 つずつ別の
# Bash で実行される（cwd、変数、関数、fd は次の手順に残らない。cwd はユーザーの作業
# ツリーに戻る）」という前提で壊れる箇所を静的に検出する。実行はしない。
#
# 見出しごとに番号を振り直した番号付きの項目を 1 手順とし、その中の ```sh（bash、yaml も）の
# フェンスの行とインラインの `...` をコマンドとして読む（タグの無いフェンスは期待する出力と
# みなして読まない）。<名前> の形の置き換えは相対パスとしない。検出するのは次のとおり。
#   変数   その手順で代入していない $VAR の参照、export（次の手順に残らない）
#   関数   前の手順で定義した関数の使用
#   cd     cd（次の手順に残らない）
#   相対   相対パスへのリダイレクト、tee、mkdir、mkfifo、touch、cp、mv、-o の宛先、
#          相対パスからの読み込み、docker build の相対のコンテキスト
#   fd     3 以上の fd のリダイレクト（手順をまたいで開いた fd は残らない）
#   否定   `!` の検査、終了コードの検査、「出力なし」を期待する検査（土台で陽性になる
#          ことを確かめる。コマンドが実行できない状態でも通ってしまう）
#   環境   プロジェクト名 nostr-no-su、127.0.0.1:8080、ホストの 5432、作業ツリーの .env、
#          ユーザーの作業ツリー、-f の無い docker compose（cwd の compose と .env を読む）
# 指摘があれば表にして 1 で、無ければ「指摘なし」を出して 0 で終わる。作業ツリーは
# 作業ツリーの絶対パスを直し方の案に使うだけで、読み書きしない。
#
# 使い方: sh dev/check_procedure.sh <手順ファイル> <作業ツリー>
set -eu

[ $# -eq 2 ] || { echo "usage: sh dev/check_procedure.sh <procedure.md> <worktree>" >&2; exit 1; }
file="$1"
tree="$2"
[ -f "$file" ] || { echo "$file does not exist" >&2; exit 1; }

# バイト単位で扱う（切り詰めをしないので UTF-8 を壊さない）。
LC_ALL=C awk -v tree="$tree" '
# 同じ手順の同じ指摘は 1 回だけ出す。
function report(kind, what, fix) {
  if (reported[step, kind, what]++) return
  n++
  printf "| %s / 手順 %d | %s | %d | %s | %s |\n", section, step, kind, NR, what, fix
}
function code(what) { gsub(/\|/, "\\|", what); gsub(/`/, "\047", what); return "`" what "`" }
# 先頭の引用符を外した上で、相対パスかを判定する。& と - と $ と / と ~ で始まるものと
# <名前> の置き換え、非 ASCII で始まる置き換えは相対パスとしない。
function relative(p) {
  sub(/^["\047]/, "", p)
  return p != "" && p !~ /^[&$\/~.-]/ && p !~ /^[^ -~]/ && p !~ />$/ && p !~ /^\.\.?\//
}
# match は RSTART を書き換えるので、呼ぶ側はその前に位置を使い終えること。
function sep_end(s,  i) { i = match(s, /[;&|]/); return i ? substr(s, 1, i - 1) : s }
function check(c,  t, i, name, args, k, last) {
  sub(/^[ \t]+/, "", c)
  t = c; gsub(/\047[^\047]*\047/, "", t)
  # 変数と関数の定義。
  while (match(t, /(^|[;&|( \t])(export[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=/)) {
    name = substr(t, RSTART, RLENGTH); sub(/^[;&|( \t]+/, "", name)
    if (name ~ /^export/) report("変数", code(name "..."), "export した環境変数は次の手順に残らない。使う手順ごとに書くか、1 本のスクリプトにまとめる")
    sub(/^export[ \t]+/, "", name); sub(/=$/, "", name)
    assigned[name] = 1; defined[name] = section " / 手順 " step
    t = substr(t, RSTART + RLENGTH)
  }
  t = c; gsub(/\047[^\047]*\047/, "", t)
  while (match(t, /for[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+in/)) {
    name = substr(t, RSTART, RLENGTH); sub(/^for[ \t]+/, "", name); sub(/[ \t]+in$/, "", name)
    assigned[name] = 1; t = substr(t, RSTART + RLENGTH)
  }
  t = c
  while (match(t, /[A-Za-z_][A-Za-z0-9_]*\(\)[ \t]*\{/)) {
    name = substr(t, RSTART, RLENGTH); sub(/\(.*/, "", name)
    assigned[name] = 1; defined[name] = section " / 手順 " step; fn[name] = 1
    t = substr(t, RSTART + RLENGTH)
  }
  # 変数の参照と関数の使用。
  t = c; gsub(/\047[^\047]*\047/, "", t)
  while (match(t, /\$\{?[A-Za-z_][A-Za-z0-9_]*/)) {
    name = substr(t, RSTART, RLENGTH); sub(/^\$\{?/, "", name)
    t = substr(t, RSTART + RLENGTH)
    if (assigned[name] || name ~ /^(HOME|PATH|PWD|USER|SHELL|TMPDIR|CI|GITHUB_[A-Z_]+)$/ || seen[step, name]++) continue
    report("変数", code("$" name), (name in defined ? defined[name] " で代入した変数" : "どの手順でも代入していない変数") "。この手順の先頭で代入するか、1 本のスクリプトで実行すると明記する")
  }
  for (name in fn) if (!assigned[name] && !seen[step, name] && c ~ ("(^|[;&|( \t])" name "([ \t]|$)")) {
    seen[step, name] = 1
    report("関数", code(name), defined[name] " で定義した関数。この手順でも定義するか、1 本のスクリプトで実行すると明記する")
  }
  if (c ~ /(^|[;&|( \t])cd[ \t]/ && !seen[step, "cd"]++)
    report("cd", code("cd ..."), "cd は次の手順に残らない。後の手順の相対パスはユーザーの作業ツリーを指すので、絶対パスで書く")
  # リダイレクトと、宛先を取るコマンド。
  t = c; gsub(/\047[^\047]*\047/, "", t); gsub(/<[^ <>;|&][^<>;|&]*>/, "PLACEHOLDER", t)
  while (match(t, /(^|[^<>=-])[<>][<>]?[ \t]*(&[0-9]+|[^ \t;&|<>]+)/)) {
    name = substr(t, RSTART, RLENGTH); t = substr(t, RSTART + RLENGTH)
    sub(/^[^<>]/, "", name)
    if (name ~ /PLACEHOLDER/) continue
    if (name ~ /^<<-?/) continue
    if (name ~ /^[<>][<>]?[ \t]*&[3-9]/) { report("fd", code(name), "手順をまたいで開いた fd は残らない。開く手順と使う手順を 1 本のスクリプトにまとめる"); continue }
    if (name ~ /^[<>][<>]?[ \t]*[&\/]/) continue
    args = name; sub(/^[<>][<>]?[ \t]*/, "", args)
    if (relative(args)) report("相対", code(name), "相対パスは cwd（ユーザーの作業ツリー）を指す。" tree " かスクラッチパッドの絶対パスにする")
  }
  if (c ~ /exec[ \t]+[0-9]+<>/) report("fd", code("exec N<>"), "手順をまたいで開いた fd は残らない。開く手順と使う手順を 1 本のスクリプトにまとめる")
  t = c; gsub(/\047[^\047]*\047/, "", t)
  while (match(t, /(^|[;&|( \t])(tee|mkdir|mkfifo|touch|cp|mv)[ \t]+[^;&|]*/)) {
    args = substr(t, RSTART, RLENGTH); t = substr(t, RSTART + RLENGTH); args = sep_end(args)
    sub(/^[;&|( \t]+/, "", args); k = split(args, parts, /[ \t]+/); last = parts[k]
    for (i = 2; i <= k; i++) if (parts[i] !~ /^-/ && (parts[1] !~ /^(cp|mv)$/ || i == k) && relative(parts[i]))
      report("相対", code(args), "書き込みの宛先が相対パス。" tree " かスクラッチパッドの絶対パスにする")
  }
  t = c; gsub(/\047[^\047]*\047/, "", t)
  if (match(t, /(curl|wget)[^;&|]*-o[ \t]+[^ \t;&|]+/)) { args = substr(t, RSTART, RLENGTH); sub(/.*-o[ \t]+/, "", args)
    if (relative(args)) report("相対", code("-o " args), "出力先が相対パス。絶対パスにする") }
  if (match(c, /docker[ \t]+(buildx[ \t]+)?build[ \t]+[^;&|]*/)) { args = sep_end(substr(c, RSTART, RLENGTH))
    k = split(args, parts, /[ \t]+/); if (parts[k] == "." || relative(parts[k]))
      report("相対", code(args), "ビルドコンテキストが相対パス。cwd はユーザーの作業ツリーなので main の木からイメージを作る。" tree " を指定する") }
  # 否定の検査。
  if (c ~ /(^|[;&|(][ \t]*)!([ \t]|$)/) report("否定", code(c), "`!` の検査は set -e でも止まらず、コマンドが実行できない状態でも通る。`if ...; then exit 1; fi` の形にし、土台で陽性になることを確かめる")
  if (c ~ /\$\?/) report("否定", code(c), "終了コードの検査。失敗を期待する側は、コマンドが実行できない状態（コンテナーが無い等）でも同じ値になる。土台で陽性になることを確かめ、実行できたことの肯定の判定を添える")
  # ユーザーの環境。
  if (c ~ /(-p|--project-name|--name|project)[= ]nostr-no-su([^-A-Za-z0-9_]|$)/) report("環境", code(c), "ユーザーの compose のプロジェクト名。固有の名前（nns-issue<N>）にする")
  if (c ~ /\/home\/lina\/workspace\/projects\/nostr-no-su/) report("環境", code(c), "ユーザーの作業ツリー。読むだけでも " tree " にする")
  if (c ~ /[^0-9]8080([^0-9]|$)/) report("環境", code(c), "ユーザーの管理 UI のポート。割り当てられたポートにする")
  if (c ~ /(localhost|127\.0\.0\.1):5432([^0-9]|$)/ || c ~ /[ =]5432:[0-9]/) report("環境", code(c), "ホストの 5432 はユーザーの Postgres。割り当てられたポートにする")
  if (c ~ /(^|[^A-Za-z0-9_.\/-])\.env([^A-Za-z0-9_.-]|$)/ || c ~ /\/\.env([^A-Za-z0-9_.-]|$)/) report("環境", code(c), "作業ツリーの .env。--env-file でスクラッチパッドのファイルを渡す")
  if (c ~ /docker([ \t]+|-)compose[ \t]/ && c !~ /docker([ \t]+|-)compose[ \t]+(ls|version)/ && c !~ /[ \t]-f[ \t]/ && c !~ /--file[ \t=]/) report("環境", code(c), "-f が無い docker compose は cwd（ユーザーの作業ツリー）の docker-compose.yml と .env を読む。-f と --env-file を絶対パスで付ける")
}
BEGIN { section = "(見出し無し)"; step = 0; n = 0
  print "| 手順 | 種別 | 行 | 内容 | 直し方の案 |"; print "|--|--|--|--|--|" }
/^[ \t]*```/ { fence = fence ? 0 : ($0 ~ /^[ \t]*```(sh|bash|shell|zsh|yaml|yml)[ \t]*$/) ? 1 : -1; next }
fence < 0 { next }
!fence && /^#+[ \t]/ { section = $0; sub(/^#+[ \t]+/, "", section); step = 0; next }
# 空行の後の字下げの無い行で番号付きの一覧は終わる。
!fence && step && blank && /^[^ \t0-9]/ { step = 0 }
{ blank = ($0 ~ /^[ \t]*$/) }
!fence && /^[ \t]*[0-9]+\.[ \t]/ {
  step = $0 + 0; delete assigned; sub(/^[ \t]*[0-9]+\.[ \t]+/, "")
}
!step { next }
fence { check($0); next }
{
  if ($0 ~ /出力(なし|無し|は無い|が無い|が空)/ && $0 ~ /grep|awk|find|ls |ss |docker/) report("否定", "「出力なし」の期待", "コマンドが実行できない状態でも出力は無い。土台で陽性になる（出力が出る）ことを確かめ、実行できたことの肯定の判定を添える")
  t = $0
  while (match(t, /`[^`]+`/)) { c = substr(t, RSTART + 1, RLENGTH - 2); t = substr(t, RSTART + RLENGTH); check(c) }
}
END { if (n == 0) print "指摘なし"; else printf "\n%d 件\n", n; exit n > 0 }
' "$file"
