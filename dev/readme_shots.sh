#!/bin/sh
# README に載せる管理 UI のスクリーンショットと、docs/usage.md に載せる要素の
# 切り出し画像（ともに docs/images/usage/）を撮り直す。撮影用のサーバー
# （dev/admin_preview.gleam）を起動し、dev/screenshots.mjs の --readme モードで
# 英語と日本語のダッシュボード 1 枚ずつを、--usage モードで日本語の切り出し 18 枚を
# 出力先（既定は docs/images/usage）に上書きしてから止める。chromium は
# npx playwright-core install chromium で先に入れておく（docs/development.md の
# 「管理 UI の CSS と画面の撮影」）。
#
# 使い方: sh dev/readme_shots.sh [出力先]
set -eu

out=${1:-docs/images/usage}
port=${PREVIEW_PORT:-18461}
mkdir -p build
gleam run -m admin_preview >build/readme_shots.log 2>&1 &
pid=$!
trap 'pkill -P "$pid" 2>/dev/null || true; kill "$pid" 2>/dev/null || true' EXIT INT TERM
for _ in $(seq 60); do
  curl -s -o /dev/null -u admin:preview-password "http://127.0.0.1:$((port + 3))/" && break
  sleep 1
done
curl -s -o /dev/null -u admin:preview-password "http://127.0.0.1:$((port + 3))/" || {
  cat build/readme_shots.log
  echo "admin_preview did not start" >&2
  exit 1
}
node dev/screenshots.mjs --readme "$out"
node dev/screenshots.mjs --readme "$out" ja-JP
node dev/screenshots.mjs --usage "$out" ja-JP
