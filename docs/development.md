# 開発

この文書は、本体とプラグインをローカルで実行、テストする手順と、管理 UI の CSS のビルドと画面の撮影の手順をまとめる。

## 実行とテスト

```sh
gleam run   # 実行
gleam test  # テスト（BIP-340 / NIP-44 / NIP-19 公式ベクター + バンカーのループバック）
```

CI と Docker イメージはどちらも Gleam 1.17.0 / OTP 29 で、検証しているのはこの組み合わせだけ。より古い OTP でも動く可能性はあるが確認していない。

本体のアカウントストアの統合テストも `TEST_DATABASE_URL` が設定されているときだけ走る（未設定ならスキップして 1 行ログを出す。`CI` が設定されているときは失敗する）:

```sh
docker run -d --name nns-pg-test -p 127.0.0.1:5433:5432 \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=nostr_no_su_test postgres:17-alpine
TEST_DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5433/nostr_no_su_test gleam test
docker rm -f nns-pg-test
```

本体も `pog` 経由で `opentelemetry_api`（`build_tools = ["rebar3", "mix"]`）に依存するため、ホストに elixir があると、ホストで作った erlang-shipment には Elixir 一式が混ざる。配布する成果物は Dockerfile の中で作ること。

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
PREVIEW_PORT=18461 node dev/screenshots.mjs build/screenshots          # 26 画面を 1280px と 375px、ライトとダークで撮る
PREVIEW_PORT=18461 node dev/screenshots.mjs build/screenshots-ja ja-JP # 日本語の画面を撮る
```

## event_logger プラグインのテスト

`event_logger` プラグインは独立した Gleam プロジェクトなので、テストもそちらで実行する。統合テストは `TEST_DATABASE_URL` が設定されているときだけ走る（未設定ならスキップして 1 行ログを出す。`CI` が設定されているときは失敗する）:

```sh
docker run -d --name nns-pg-test -p 127.0.0.1:5433:5432 \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=nostr_no_su_test postgres:17-alpine
cd plugins-src/event_logger
TEST_DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5433/nostr_no_su_test gleam test
docker rm -f nns-pg-test
```
