#!/bin/sh
# devin CLI に実装を任せるときの依頼文を機械的に組み立てて標準出力に出す。
# 依頼文は自己完結にする（devin はこのセッションの文脈もエージェント定義も読まない）。
# 実装の基準と検査の手順は .claude/agents/issue-implementer.md と同じ内容を写している。
# 変えるときは両方を同時に直す。
#
# 使い方: sh dev/devin_prompt.sh <issue 番号> <none|light> <仕様のファイル> <Postgres のポート> [条件のファイル]
#   仕様のファイル: tier none では issue の本文とコメント（gh issue view --comments の出力）、
#                   light では承認済みプランのコメント本文
#   条件のファイル: プランレビューが APPROVE に添えた実装時の条件（1 行 1 件）。無ければ省く
set -eu

usage() { echo "usage: sh dev/devin_prompt.sh <issue> <none|light> <spec-file> <pg-port> [conditions-file]" >&2; }

[ $# -eq 4 ] || [ $# -eq 5 ] || { usage; exit 1; }
n="$1"
tier="$2"
spec="$3"
pgport="$4"
conds="${5:-}"

case "$n" in
  '' | *[!0-9]*) echo "invalid issue number: $n" >&2; exit 1 ;;
esac
case "$tier" in
  none | light) ;;
  *) echo "invalid tier: $tier (none or light)" >&2; exit 1 ;;
esac
case "$pgport" in
  '' | *[!0-9]*) echo "invalid port: $pgport" >&2; exit 1 ;;
esac
[ -s "$spec" ] || { echo "spec file is empty or missing: $spec" >&2; exit 1; }
[ -z "$conds" ] || [ -s "$conds" ] || { echo "conditions file is empty or missing: $conds" >&2; exit 1; }

cat <<PROMPT
# issue #$n の実装（nostr-no-su）

あなたは nostr-no-su（Gleam / BEAM の Nostr バンカー兼ユーティリティサーバー）の実装担当である。
このディレクトリは使い捨ての clone で、origin/main を土台に取り出し済みである。ここで issue #$n を実装し、検査を通し、報告ファイルを書いて終わる。
言語は日本語（である調）。ユーザーに質問はできない。判断に迷う点は報告ファイルの「決めたこと」に書く。

## してはいけないこと
- \`git commit\`、\`git push\`、\`gh pr\`、\`gh issue comment\`、\`gh api\` の書き込み（POST / PATCH / DELETE）は行わない。コミットと PR は別の担当が行う
- \`git fetch\`、\`pull\`、\`checkout\`、\`reset\`、\`stash\` で HEAD と作業ツリーの状態を動かさない（origin はローカルのリポジトリで、差分は HEAD からの \`git diff\` で回収される）
- \`/home\` の下と、この clone の外のリポジトリには書き込まない（この clone、/tmp、docker だけを使う）
- docker は自分が作った \`pg-devin-$n\` だけを使い、それ以外のコンテナー、volume、ネットワーク、イメージに触れない。\`docker ps -aq | xargs docker rm -f\` のような絞らない削除と \`prune\` は使わない
- 後方互換、廃止ログ、移行案内、互換レイヤーは作らない（v0.1 未満で非公開。消すものは痕跡ごと消す）
- スクリーンショットは撮らない
- 受け入れ条件の外の変更（ついでの整理、体裁の統一）は入れない。受け入れ条件がすでに満たされていて変えるものが無ければ、何も変えずに報告ファイルにそう書く

## 仕様
PROMPT

if [ "$tier" = none ]; then
  cat <<PROMPT
承認済みの実装プランは無い（小さい issue なのでプランの段階を飛ばした）。受け入れ条件は下の issue の本文とコメントにしか無い。
本文の行番号とファイルの位置は起票時の参考値なので、今のコードで引き直す。
調べてみて追加が 100 行を大きく超える、または「決めたこと」が 2 件以上になると分かったら、実装を続けない。報告ファイルの先頭に \`status: deviation\` と見込みと理由を書いて終わる（途中の変更は残してよい）。

<details><summary>issue #$n の本文とコメント</summary>

PROMPT
else
  cat <<PROMPT
下の承認済みの実装プランのとおりに実装する。プランの後半は \`<details>\` に畳まれているので、そこまで読む。
プランどおりに作れない箇所が見つかったら、勝手に設計を変えずに、報告ファイルの先頭に \`status: deviation\` と、その箇所・理由・代案を書いて終わる（途中の変更は残してよい）。小さな表記の違いは報告ファイルの「プランからの変更」に書けばよい。

<details><summary>承認済みの実装プラン（issue #$n）</summary>

PROMPT
fi

cat "$spec"

cat <<PROMPT

</details>
PROMPT

if [ -n "$conds" ]; then
  cat <<PROMPT

### 実装時の条件
プランレビューが承認に添えた条件である。すべて取り込み、報告ファイルの「プランからの変更」に取り込んだ旨を書く。
PROMPT
  awk '{ print NR ". " $0 }' "$conds"
fi

cat <<PROMPT

## 実装の基準
- DRY、シンプルさ、命名、仕様（issue とプラン）への準拠を厳しめにレビューされる
- 関数型の書き方（不変データ、Result、パターンマッチ、小さな純粋関数）。既存のモジュールの流儀に合わせる
- 全関数に簡潔な Doc コメント（\`///\`）を書く。コード内コメントは日本語で書く（ログ文字列、識別子、エラーメッセージは英語）
- Doc コメントは、この変更がマージされた時点の動作だけを書く。行番号、issue 番号、後続 issue で配線される動作は書かない。プランが文言を指定していればそのまま使う
- README.md と docs/readme-ja.md（同じ内容の英語版と日本語版）、docs/architecture.md、.env.example など、変更に関係する文書も同じ変更で直す
- 手順書や runbook に節を足すときは、依存する既存の節（前提を述べている段落）を読み直し、その前提を引き継ぐ
- テストを足す、移す、消したときは、そのファイルのモジュール Doc（\`////\`）の列挙も直す

## 終わる前の検査（この順に、機械的に。すべて通るまで直す）
1. \`gleam build --warnings-as-errors\`
2. \`gleam test\` を統合テストまで通す。Postgres は \`docker run --rm -d --name pg-devin-$n -p 127.0.0.1:$pgport:5432 -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=nostr_no_su_test postgres:17-alpine\` で立て、\`docker exec pg-devin-$n pg_isready\` を待ってから \`TEST_DATABASE_URL=postgres://postgres:postgres@127.0.0.1:$pgport/nostr_no_su_test gleam test\` を実行し、終わったら \`docker rm -f pg-devin-$n\` で消す
3. \`gleam format src test dev\` を実行し、\`gleam format --check src test dev\` が通ることを確かめる
4. \`examples/\` を変えたら \`erlc -Wall -Werror -o "\$(mktemp -d)" examples/plugins/*/src/*.erl\`。\`vendor/\` を変えたら \`sh dev/check_vendor_stratus.sh\`。\`docker-compose.yml\`、\`docker-compose.release.yml\`、\`.env.example\` のどれかを変えたら \`sh dev/check_env_example.sh\` と \`sh dev/check_release_compose.sh\`。\`plugins-src/\`、\`gleam.toml\`、\`manifest.toml\` を変えたら \`sh dev/check_shared_versions.sh\` と、\`plugins-src/event_logger\` で \`gleam build --warnings-as-errors\`、\`gleam test\`（同じ Postgres を使う）、\`gleam format --check src test\`
5. \`src/nostr_no_su/admin/\` の \`.gleam\`（\`i18n.gleam\` を除く）か \`assets/admin.css\` を変えたら、\`npm ci && npm run build:css\` を実行して \`priv/static/admin.css\` の差分を残す
6. 仕様の「検証の手順」（プランにあるもの、または issue の受け入れ条件から自分で組んだもの）をすべて実行し、出力の抜粋を報告ファイルに書く
7. 意味が変わった語（識別子、環境変数、kind、表、画面の数）ごとに \`sh dev/sweep_refs.sh . <語>...\` を回し、README.md と docs/readme-ja.md（同じ内容の英語版と日本語版）、docs/、.env.example に古い記述が残っていないことを確かめる（0 件でも報告ファイルに語を書く）
8. 自己レビュー: \`git diff\` を受け入れ条件、動作の誤り、DRY、命名、文書の食い違いの観点で 1 回読み、見つけたものは直す

## 報告ファイル
clone の直下に \`DEVIN_REPORT.md\` を書いて終わる（この 1 ファイルだけが報告で、標準出力の文は読まれない）。\`git add\` はしない。書式は次のとおり。行数は書かない。

\`\`\`
status: done
## 変更点
### \`path\`（何をしたかを 1〜3 行）
## テストと検証
（検査 1〜7 の結果。検証の手順の出力の抜粋。掃き出した語）
PROMPT

if [ "$tier" = none ]; then
  cat <<PROMPT
## 設計メモ
### 決めたこと
（判断が分かれた点ごとに、決定・理由・捨てた案。判断が無ければ「無し」）
### 受け入れ条件
| 受け入れ条件 | 満たす変更（\`path:行\`） | 検証の手順 |
| --- | --- | --- |
（issue の受け入れ条件 1 件 1 行）
\`\`\`
PROMPT
else
  cat <<PROMPT
## プランからの変更
（無ければ「無し」）
\`\`\`
PROMPT
fi

cat <<PROMPT

途中で止まるときは \`status: deviation\` にし、その下に見込みと理由（と代案）を書く。検査が通らないまま終わるときは \`status: failed\` にし、通らなかった検査と出力を書く。
PROMPT
