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

PR の CI（`.github/workflows/test.yml`。食い違ったら `test.yml` が正）は、PR でだけ走る 1 ジョブで次を検査する（Gleam 1.17.0 / OTP 29）。docs、`.claude/`、`*.md`、LICENSE だけの PR では何も検査しない。

```sh
gleam build --warnings-as-errors
gleam test                                  # TEST_DATABASE_URL を渡さないので統合テストはスキップされる
gleam format --check src test dev
erlc -Wall -Werror -o "$(mktemp -d)" examples/plugins/*/src/*.erl
sh dev/check_vendor_stratus.sh
sh dev/check_env_example.sh
sh dev/check_shared_versions.sh             # 以下 2 行は plugins-src/、gleam.toml、manifest.toml を変えた PR だけ
cd plugins-src/event_logger && gleam build --warnings-as-errors && gleam test && gleam format --check src test
npm ci && npm run build:css && git diff --exit-code -- priv/static/admin.css   # 管理 UI の .gleam、assets/、package*.json を変えた PR だけ
```

Postgres を使う統合テスト、strfry を使う NIP-46 の E2E、shipment、docker イメージ、プラグインの README のビルド手順は PR の CI では検査しない。`.github/workflows/manual.yml` を手で起動して main で確かめる（docs/development.md の「手動の検査」）。push の前に手元で統合テストまで通すこと（起動は docs/development.md の「実行とテスト」「event_logger プラグインのテスト」）。

- 描画のモジュール（`src/nostr_no_su/admin/` の `.gleam`。`admin/i18n.gleam` を除く）か `assets/admin.css` を変えたら、`npm run build:css` をやり直して `priv/static/admin.css` を一緒にコミットする。クラスを変えなくても CSS が変わることがある。
- `plugins-src/event_logger` の `manifest.toml` の共有パッケージ（`gleam_stdlib`、`pog` など）の版は本体と同時に上げる。ずれると CI の版の検査で落ちる。
- `plugins/` に置く成果物はホストでビルドしない。ホストに elixir があると Elixir 一式が混ざるので、`plugins-src/event_logger/README.md` の「ビルド」の docker の手順で作る。
