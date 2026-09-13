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

CI の主な検査は次のとおりである（Gleam 1.17.0 / OTP 29）。全体は `.github/workflows/test.yml` にあり、食い違ったら `test.yml` が正である。

```sh
gleam build --warnings-as-errors
TEST_DATABASE_URL=postgres://… gleam test   # 統合テストに Postgres が要る。起動は docs/development.md の「実行とテスト」「event_logger プラグインのテスト」
gleam format --check src test dev
npm ci && npm run build:css && git diff --exit-code -- priv/static/admin.css
sh dev/check_vendor_stratus.sh
sh dev/check_shared_versions.sh
sh dev/check_env_example.sh
cd plugins-src/event_logger && gleam build --warnings-as-errors && TEST_DATABASE_URL=postgres://… gleam test && gleam format --check src test
```

- 描画のモジュール（`src/nostr_no_su/admin/` の `.gleam`。`admin/i18n.gleam` を除く）か `assets/admin.css` を変えたら、`npm run build:css` をやり直して `priv/static/admin.css` を一緒にコミットする。クラスを変えなくても CSS が変わることがある。
- `plugins-src/event_logger` の `manifest.toml` の共有パッケージ（`gleam_stdlib`、`pog` など）の版は本体と同時に上げる。ずれると CI の版の検査で落ちる。
- `plugins/` に置く成果物はホストでビルドしない。ホストに elixir があると Elixir 一式が混ざるので、`plugins-src/event_logger/README.md` の「ビルド」の docker の手順で作る。
