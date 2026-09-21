# 開発

この文書は、本体とプラグインをローカルで実行、テストする手順、テストの流儀、管理 UI の CSS のビルドと画面の撮影の手順をまとめる。

## 実行とテスト

```sh
gleam run   # 実行
gleam test  # テスト（BIP-340 / NIP-44 / NIP-19 公式ベクター + バンカーのループバック）
```

CI と Docker イメージはどちらも Gleam 1.17.0 / OTP 29 で、検証しているのはこの組み合わせだけ。より古い OTP でも動く可能性はあるが確認していない。

`gleam test` は test/ 配下のモジュールを 8 本のレーンで同時に走らせる（`test/nostr_no_su_test.gleam` の `lanes`。空いたレーンが次のモジュールを取る。実行器は `test/support/eunit_runner.erl`）。同じモジュールの中のテストは順に走り、同じ DB の advisory lock を取り合う `account_store_test` と `account_reconcile_test` だけは 1 本のレーンでこの順に走る（同じファイルの `ordered_modules`）。gleeunit の main は使っていないが、報告（進捗の点と失敗の一覧）は gleeunit のものをそのまま使う。出力のログの行は別のモジュールのテストのものと入り混じる。壁時間は Postgres と strfry つきで 20 秒ほどで、いちばん長いモジュール（`account_reconcile_test` と `app_accounts_test`）で決まる。

本体のアカウントストアの統合テストも `TEST_DATABASE_URL` が設定されているときだけ走る（未設定ならスキップして 1 行ログを出す）。CI の `test` ジョブは Postgres を立てて渡す。CI の失敗で push をやり直さないよう、push の前に手元でも通す:

```sh
docker run -d --name nns-pg-test -p 127.0.0.1:5433:5432 \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=nostr_no_su_test postgres:17-alpine
TEST_DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5433/nostr_no_su_test gleam test
docker rm -f nns-pg-test
```

本体も `pog` 経由で `opentelemetry_api`（`build_tools = ["rebar3", "mix"]`）に依存するため、ホストに elixir があると、ホストで作った erlang-shipment には Elixir 一式が混ざる。配布する成果物は Dockerfile の中で作ること。

## テストの流儀

表駆動のテストでは行に名前（`name` のようなラベル）を付け、比較の両辺に名前を含めて、どの行が落ちたかが出力で分かるようにする。同じ status を返す case が複数あるときは、status ではなく鍵（対象を一意に決める値）を期待値にする。

到達しない分岐を消すときは、`case` の潰しではなく不可反駁な `let` に置き換える。残す `Error` の分岐は、`grep` の件数を検証の手順に載せて、レビューと最終確認が同じ根拠を辿れるようにする。

テストのモジュールは並列に走るので、モジュールをまたいで共有する状態を使わない。プロセスの名前は `process.new_name`、DB はテストごとのスキーマか database、BEAM のモジュール名と一時ディレクトリーは `support/beam_fixture` で一意にする。環境変数（`config_test` だけが使う）や同じ DB の advisory lock のように共有せざるを得ない状態を新しいモジュールで使うなら、そのモジュールを `test/nostr_no_su_test.gleam` の `ordered_modules` に足して、干渉する相手と同じレーンで走らせる。

時間に関わる検査は、待ち時間で順序を作らず、テストが開ける門（アクターのプロセスで作った subject を受信で止め、テストが送って進める。`app_accounts_test` の `hold_until_released`）か、締め切りの注入で作る。「N ms の間に何も届かない」ことを確かめる待ちはモジュールの慣習（100〜300ms）に合わせ、「N ms 以内に応答する」の上限は、他のレーンと CPU を取り合っても収まるよう締め切りの数倍を取る。眠る仕事で締め切りの検証をするときは、仕事の眠りではなく締め切りがテストの時間になるので、締め切りを短くする。

## 管理 UI の CSS と画面の撮影

管理 UI の CSS（`priv/static/admin.css`）は、ビルドした生成物をリポジトリに含めているので、`gleam run` と `docker compose up --build` に Node.js は要らない。描画のモジュール（`src/nostr_no_su/admin/` の `.gleam`。文言の `admin/i18n.gleam` を除く）か `assets/admin.css` を変えたときは、ビルドし直して一緒にコミットする（CI が差分を検査する）。Tailwind はクラスに限らず、文字列、識別子、コメントの語もクラスの候補として拾うので、クラスを変えなくても CSS が変わることがある。画面の文言は走査の外の `admin/i18n.gleam` にあるので、文言だけの変更では CSS は変わらない。Node.js 24 で検証している:

```sh
npm ci             # Tailwind CSS、daisyUI、playwright-core を package-lock.json の版で入れる
npm run build:css  # assets/admin.css から priv/static/admin.css を作る
```

管理 UI の全ページを固定の状態で確かめるときは、撮影用のサーバーを起動して撮る。サーバーは `PREVIEW_PORT` から続く 3 つのポートで、通常の状態、アカウントの一覧を得られない状態、すべての一覧が空の状態を出す（ユーザー名は `admin`、パスワードは `preview-password`）。鍵は公開のテストベクター、secret はダミーの値である。サーバーは終了しないので、1 つの端末で起動したまま別の端末で撮る。初回は `npx playwright-core install chromium` で、`playwright-core` の版が使う chromium を入れる（ブラウザーが無いときのエラーが勧める `npx playwright install` は、別のパッケージとその版のブラウザーを入れるので、必要な版が入るとは限らない）:

```sh
PREVIEW_PORT=18461 gleam run -m admin_preview                          # 端末 1（終了しない）
npx playwright-core install chromium                                   # 端末 2。初回だけ
PREVIEW_PORT=18461 node dev/screenshots.mjs build/screenshots          # shots の全画面を 1280px と 375px、ライトとダークで撮る
PREVIEW_PORT=18461 node dev/screenshots.mjs build/screenshots-ja ja-JP # 日本語の画面を撮る
```

## NIP-46 の E2E（strfry）

実際のリレー（strfry）と Postgres の上で、本番の仕様のツリーに NIP-46 の connect → get_public_key → sign_event を往復させる E2E は、`TEST_RELAY_URL` と `TEST_DATABASE_URL` の両方が設定されているときだけ走る（どちらかが未設定ならスキップして 1 行ログを出す。CI の `test` ジョブは strfry と Postgres を立てて両方渡す）。テストごとに専用の database を作って消す:

```sh
docker run -d --name nns-pg-test -p 127.0.0.1:5433:5432 \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=nostr_no_su_test postgres:17-alpine
docker run -d --name nns-strfry-test -p 127.0.0.1:7777:7777 \
  ghcr.io/hoytech/strfry@sha256:36f1886d185a88ca57c66ebe52e6e9e8428dac2486eea0a5d50ff934f18b60c3 \
  --set relay.bind=0.0.0.0 --set relay.nofiles=0 --set relay.numThreads.ingester=1 --set relay.numThreads.reqWorker=1 --set relay.numThreads.reqMonitor=1 --set relay.numThreads.negentropy=1 relay
TEST_DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5433/nostr_no_su_test \
  TEST_RELAY_URL=ws://127.0.0.1:7777 gleam test
docker rm -f nns-pg-test nns-strfry-test
```

## event_logger プラグインのテスト

`event_logger` プラグインは独立した Gleam プロジェクトなので、テストもそちらで実行する。統合テストは `TEST_DATABASE_URL` が設定されているときだけ走る（未設定ならスキップして 1 行ログを出す。CI の `event-logger` ジョブは Postgres を立てて渡す）:

```sh
docker run -d --name nns-pg-test -p 127.0.0.1:5433:5432 \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=nostr_no_su_test postgres:17-alpine
cd plugins-src/event_logger
TEST_DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5433/nostr_no_su_test gleam test
docker rm -f nns-pg-test
```

## CI

`.github/workflows/ci.yml` が PR と main への push で走る（Actions の `ci` を選んで「Run workflow」で手動でも起動できる）。PR では変えたファイルの種類に応じてジョブを省略し、docs、`.claude/`、`*.md`、LICENSE だけの PR では何も検査しない（ジョブは skipped で終わり、`gh pr checks` は pass を報告する）。main への push では全部のジョブが走るので、リリースの前に手で起動する検査は無い（CONTRIBUTING.md の「リリース」）。ジョブは次のとおり:

| ジョブ | 検査 | PR で走る条件 |
|--|--|--|
| `test` | build、Postgres と strfry つきの `gleam test`（単体、統合、E2E。strfry のログでイベントの保存を確かめる）、format、例のプラグインのコンパイル、`vendor/stratus` と `.env.example` の検査、shipment | docs 以外を変えた |
| `event-logger` | 共有パッケージの版の検査、event_logger の build、Postgres つきの `gleam test`、format、shipment | `plugins-src/`、`gleam.toml`、`manifest.toml` を変えた |
| `css` | `npm run build:css` の結果が `priv/static/admin.css` と一致すること | 管理 UI の `.gleam`、`assets/`、`package*.json` を変えた |
| `plugin-readme-build` | プラグインの README の「ビルド」の手順をそのまま実行し、同梱アプリを `manifest.toml` と突き合わせる | `plugins-src/`、`examples/` を変えた |
| `docker-image` | 同じコミットから 2 回ビルドして同じイメージになること、実行イメージの中身、healthcheck、remsh の口 | `Dockerfile`、`docker/`、`docker-compose.yml`、`vendor/`、`gleam.toml`、`manifest.toml` を変えた |

`.github/` を変えた PR では全部のジョブが走る。壁時間は `test` ジョブの `gleam test`（Postgres と strfry つきで約 30 秒。手元では 20 秒ほど）とその前のビルドで決まり、PR 全体で 1 分半ほどかかる。手元で同じことを確かめる手順は、この文書の各節と `plugins-src/event_logger/README.md` の「ビルド」にある。

## レビューの前の機械的な検査

プランと PR のレビューで「網羅」の指摘（追随先の漏れ、数値の転記、手順の再現性）を減らすために、`dev/` に読み取りの検査と、コメントの投稿を機械化するスクリプトを置いている。CI では実行しない。検査はエージェント（プラン、実装、レビュー）が手元で回して出力をプランや PR 本文に貼り、`post_comment.sh` だけが GitHub にコメントを投稿する:

```sh
sh dev/sweep_refs.sh <作業ツリー> <語>...       # 語ごとの参照（code / doc-comment / test / docs / config）を表にする。0 件も出す
sh dev/pr_facts.sh <PR 番号>                     # head と base の SHA、差分の行数、閉じる issue、CI のジョブを 1 枚の表にする
sh dev/check_procedure.sh <手順ファイル> <作業ツリー>  # 番号付きの手順を「1 つずつ別の Bash で実行される」前提で静的に検査する
sh dev/check_plan_tests.sh <プランのファイル> <作業ツリー>  # プランの「テスト」の表の 1 列目のテスト名と実装の `pub fn ..._test()` を突き合わせ、無いものを表にして 1 で終わる（実装エージェントが使う）
sh dev/post_comment.sh <issue|pr> <番号> <kind> <round> <verdict> <head> <本文ファイル>  # マーカー行を付けて issue/PR にコメントを投稿する
sh dev/devin_prompt.sh <issue> <none|light> <仕様のファイル> <Postgres のポート> [条件のファイル]  # 実装を devin CLI に任せるときの自己完結な依頼文を組む（実装エージェントが使う）
sh dev/devin_wait.sh <clone> [最大秒数]                                              # devin CLI の完了を前景で待ち、終了コード 0（報告あり）/ 1（報告なしで終了）/ 2（まだ実行中。呼び直す）で返す（実装エージェントが使う）
python3 dev/wfstats.py [--base <dir>] [--runs <run id>,...] [--brief]              # Workflow の実行ログから費用・速度・品質の実測を出す。--brief の要約を retrospective が issue に貼る
```

実装エージェントの定義（`.claude/agents/issue-implementer.md`）の frontmatter の `hooks` は、定義の「PR を作る前の検査」の一部（format と PR 本文の書式）を機械的に行う。エージェントが直接呼ぶものではなく、stdin に hook の JSON を受け取る:

```sh
sh dev/hook_gleam_format.sh       # PostToolUse（Edit|Write）: 編集した .gleam をその作業ツリーで gleam format する
sh dev/hook_pr_body_gate.sh       # PreToolUse（Bash）: gh pr create の --body-file に必須の節（概要、変更点、テストと検証、掃き出した語、Closes #、設計メモの表）が無ければ deny する
sh dev/hook_push_format_check.sh  # PreToolUse（Bash）: git -C <作業ツリー> push の前に gleam format --check src test dev を回し、通らなければ deny する
```
