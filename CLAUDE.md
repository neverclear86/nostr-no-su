# Nostr-no-Su

Nostrのバンカー兼ユーティリティサーバー
NIP-46で鍵を管理するバンカーであり、自分のアカウントのイベントを監視してプラグイン形式で様々な処理をするユーティリティサーバー。
dockerで簡単に立ち上げられることを最初の目標にしている。
BEAMの並列処理や安定性を活かして効率的にNostrのイベントを処理することを目指す。

- 複数アカウントの鍵を管理可能
- プラグインにより自アカウントのイベントを監視して処理
  - 例えば、全てのイベントをDBに保存するロガープラグイン
- 管理UIもGleamで実装
- DBはPostgresを使用

## 開発

仕様と設計の文書は [README](README.md) の「文書」節から辿る。

CI（`.github/workflows/ci.yml`。食い違ったら `ci.yml` が正）は、PR と main への push で次を検査する（Gleam 1.17.0 / OTP 29）。PR では変えたファイルに応じてジョブを省略し、docs、`.claude/`、`*.md`、LICENSE だけの PR では何も検査しない。main への push では全部のジョブが走る。

```sh
gleam build --warnings-as-errors
TEST_DATABASE_URL=... TEST_RELAY_URL=... gleam test   # Postgres の統合テストと strfry の E2E も走る（起動は docs/development.md）
gleam format --check src test dev
erlc -Wall -Werror -o "$(mktemp -d)" examples/plugins/*/src/*.erl
sh dev/check_vendor_stratus.sh
sh dev/check_env_example.sh
gleam export erlang-shipment
sh dev/check_shared_versions.sh             # 以下 2 行は plugins-src/、gleam.toml、manifest.toml を変えた PR だけ
cd plugins-src/event_logger && gleam build --warnings-as-errors && TEST_DATABASE_URL=... gleam test && gleam format --check src test && gleam export erlang-shipment
npm ci && npm run build:css && git diff --exit-code -- priv/static/admin.css   # 管理 UI の .gleam、assets/、package*.json を変えた PR だけ
```

これに加えて、プラグインの README のビルド手順（`plugins-src/`、`examples/` を変えた PR）と docker イメージ（`Dockerfile`、`docker/`、`docker-compose.yml`、`plugins-src/`、`vendor/`、`gleam.toml`、`manifest.toml` を変えた PR）のジョブがある（docs/development.md の「CI」）。CI の失敗で push をやり直さないよう、push の前に手元で統合テストまで通すこと（起動は docs/development.md の「実行とテスト」「event_logger プラグインのテスト」）。

- 描画のモジュール（`src/nostr_no_su/admin/` の `.gleam`。`admin/i18n.gleam` を除く）か `assets/admin.css` を変えたら、`npm ci && npm run build:css` をやり直して `priv/static/admin.css` を一緒にコミットする（古い `node_modules` のままでは違う CSS ができる）。クラスを変えなくても CSS が変わることがある。
- `plugins-src/event_logger` の `manifest.toml` の共有パッケージ（`gleam_stdlib`、`pog` など）の版は本体と同時に上げる。ずれると CI の版の検査で落ちる。
- `plugins/` に置く成果物はホストでビルドしない。ホストに elixir があると Elixir 一式が混ざるので、`plugins-src/event_logger/README.md` の「ビルド」の docker の手順で作る。
