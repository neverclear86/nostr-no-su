#!/bin/sh
# devin CLI の完了を前景で待ち、判定を 1 行の出力と終了コードで返す。
# .claude/agents/issue-implementer.md の「devin に実装を任せるとき」が、Bash ツールの
# 既定の timeout（120 秒）に収まる長さで区切って繰り返し呼ぶ。判定はこの issue の
# ファイルだけで行うので、並列に走る他の issue の devin を待ち続けることはない。
#
# <clone> から次のファイルを導く（末尾の / は取り除く）:
#   報告        : <clone>/DEVIN_REPORT.md
#   依頼文      : <clone>.txt
#   終了マーカー: <clone>.exit（起動側が devin-box.sh の終了コードを書く）
#
# 5 秒間隔で確かめ、判定が出たら 1 行を標準出力に出して終わる:
#   0  done: report=<報告> exit=<マーカーの中身|none> elapsed=<秒>   … マーカーと報告がそろった
#   1  ended without report: exit=<マーカーの中身|none> elapsed=<秒> … 報告が無いまま devin が終わった
#   2  running: report=<yes|no> elapsed=<秒>                          … この呼び出しの最大秒数の間に判定が出なかった
#   64 引数の誤り
# 報告だけ先にあってもマーカーが無ければ待ち続ける（報告を書いた後も devin が
# 作業ツリーを触りうるため）。最大秒数はこの呼び出しの開始から数える（elapsed は
# 依頼文の mtime からの経過で、呼び出し側が全体の上限を判断するための値）。
#
# 予備の判定（起動側の subshell が殺されるなどしてマーカーが書かれない場合の保険）:
# マーカーが無く、devin のプロセス（pgrep -f "^devin .*--prompt-file <clone>.txt"）に
# 1 つも一致しない状態が 2 回連続で続いたら devin は終わったものとみなし、報告の有無で
# 0 か 1 を返す（出力の exit= は none）。パターンは ^devin で始める（このスクリプト自身と
# bwrap の引数にも依頼文のパスが含まれるので、無印の -f では自分に一致する）。
#
# 使い方: sh dev/devin_wait.sh <clone> [最大秒数]
set -eu

usage() { echo "usage: sh dev/devin_wait.sh <clone> [最大秒数]" >&2; }

[ $# -eq 1 ] || [ $# -eq 2 ] || { usage; exit 64; }
clone=${1%"${1##*[!/]}"}
max="${2:-100}"

case "$max" in
  '' | *[!0-9]*) usage; exit 64 ;;
esac
[ -d "$clone" ] || { echo "clone directory does not exist: $clone" >&2; exit 64; }
prompt="$clone.txt"
[ -f "$prompt" ] || { echo "prompt file does not exist: $prompt" >&2; exit 64; }

report="$clone/DEVIN_REPORT.md"
exitf="$clone.exit"
mtime=$(stat -c %Y "$prompt")
deadline=$(( $(date +%s) + max ))
gone=0

while :; do
  now=$(date +%s)
  elapsed=$(( now - mtime ))
  if [ -f "$exitf" ]; then
    code=$(cat "$exitf")
    if [ -f "$report" ]; then
      echo "done: report=$report exit=$code elapsed=$elapsed"
      exit 0
    fi
    echo "ended without report: exit=$code elapsed=$elapsed"
    exit 1
  fi
  if pgrep -f "^devin .*--prompt-file $prompt" > /dev/null 2>&1; then
    gone=0
  else
    gone=$((gone + 1))
    if [ "$gone" -ge 2 ]; then
      if [ -f "$report" ]; then
        echo "done: report=$report exit=none elapsed=$elapsed"
        exit 0
      fi
      echo "ended without report: exit=none elapsed=$elapsed"
      exit 1
    fi
  fi
  if [ "$now" -ge "$deadline" ]; then
    if [ -f "$report" ]; then r=yes; else r=no; fi
    echo "running: report=$r elapsed=$elapsed"
    exit 2
  fi
  sleep 5
done
