# event_logger

監視で受信したイベントを Postgres の `events` テーブルへ保存する外部プラグイン。NIP-01 の全フィールド（`tags` は jsonb）と取り込み時刻を 1 行として残し、同じイベントを複数のリレーから受け取っても 1 行だけ保存する。

`examples/plugins/` の 2 つが仕様の例示なのに対し、こちらは**第一級の同梱プラグイン**である。状態（保存アクター）を持ち、独自の依存（pog / pgo）を同梱し、独自の設定（`PLUGIN_EVENT_LOGGER_DATABASE_URL`）を受け取る。プラグイン API v1 が実用的なプラグインに足りることの実証でもある。

仕様の全文は [プラグイン API v1](../../docs/plugin-api.md) を参照すること。

## ビルド

**本体と同じイメージでビルドすること。** 理由は 2 つある。

- **OTP が違う BEAM はローダーが `badfile` で拒否する。**
- **ホスト環境でビルドすると同梱物が別物になる。** `opentelemetry_api` が `build_tools = ["rebar3", "mix"]` を持つため、ホストに elixir があると Gleam が `elixir` / `mix` / `logger` / `eex` を丸ごと vendor する（実測で計 514 モジュール。docker ビルドは 124）。混入した Elixir 一式はコードパスに載るだけで誰も使わず、起動ログの影の行を無意味に膨らませる。

```sh
mkdir -p plugins/event_logger
docker run --rm \
  -v "$PWD/plugins-src/event_logger:/src:ro" \
  -v "$PWD/plugins/event_logger:/out" \
  ghcr.io/gleam-lang/gleam:v1.17.0-erlang-alpine \
  sh -c 'cp -r /src /work && cd /work && gleam deps download \
         && gleam export erlang-shipment && cp -r build/erlang-shipment/. /out/'
chmod -R a+rX plugins
```

`/src` は読み取り専用でマウントするので、一度 `/work` へ複写してからビルドする。ローカルの `gleam export erlang-shipment` はスモークテストであって、その出力を `plugins/` に置いてはならない。

## 置き方

`gleam export erlang-shipment` の出力を**そのまま**置く。ローダーは `<name>/<app>/ebin` のレイアウトを受け付けるので、flatten してはならない。

```
plugins/event_logger/event_logger/ebin/event_logger.beam   -- エントリー
plugins/event_logger/pog/ebin/…  pgo/ebin/…  pg_types/ebin/…
plugins/event_logger/entrypoint.sh                          -- ローダーは黙って無視する
```

エントリーモジュール名はディレクトリー名と一致させる（`plugins/event_logger` → モジュール `event_logger`）。同梱の `docker-compose.yml` は `./plugins` を `/plugins` に読み取り専用でマウントし、`PLUGIN_DIR=/plugins` を渡す。コンテナーは非 root（uid 1000）で動くため、ホスト側は誰でも読める権限にしておくこと。

## 設定

| 環境変数 | 必須 | 意味 |
| --- | --- | --- |
| `PLUGIN_EVENT_LOGGER_DATABASE_URL` | はい | 保存先の Postgres（`postgres://user:pass@host:5432/db`） |

設定が無い、あるいは URL として解釈できないときは `plugin_children/1` が `{error, Reason}` を返し、**このプラグインだけが読み込まれない**（本体の起動は止まらない）。起動ログに出るのは次の 1 行である。

```
[plugin_loader] event_logger: plugin_children/1 rejected the configuration (PLUGIN_EVENT_LOGGER_DATABASE_URL is required); 設定は PLUGIN_EVENT_LOGGER_* で渡す
```

## `DATABASE_URL` からの移行

イベント保存はかつて本体に内蔵され、`DATABASE_URL` で設定していた。

| 旧 | 新 |
| --- | --- |
| `DATABASE_URL=postgres://…` | `PLUGIN_EVENT_LOGGER_DATABASE_URL=postgres://…` |
| `DATABASE_URL=`（空）で保存を無効化 | **プラグインを置かないことが無効化である** |

**空文字列の意味が変わった。** 旧構成では `DATABASE_URL=` で保存を黙って無効にできたが、`PLUGIN_EVENT_LOGGER_DATABASE_URL=` は本体が空値を落とすため、プラグインには**キーごと届かない**。結果は「設定が足りない」であり、起動のたびに上の 1 行が出る。保存をやめるなら `plugins/event_logger` を置かないこと。

管理 UI の「Event storage」欄も無くなった。代わりに Plugins 欄の `event_logger` 行が、置いていなければ出ず、動いていれば `running`、子を諦めていれば `disabled: …` を示す。真偽 2 値だった旧欄より情報量は増えている。

## `pgo` のアプリケーションを自分で起動していること

本体のローダーは**コードパスを足すだけでアプリケーションを起動しない**（[プラグイン API v1](../../docs/plugin-api.md) 第 8.1 節）。したがって同梱したアプリケーションの起動はプラグインの責任である。このプラグインは接続プールの起動シム `event_logger:start_pool/1` の先頭で `application:ensure_all_started(pgo)` を呼ぶ（冪等なので子の再起動のたびに呼ばれても害はない）。

呼ばないと次のように壊れる。`pg_types` のアプリが起動していないと `pg_types:update_map/3` の `application:get_key(pg_types, modules)` が `undefined` を返し、`pgo_type_server` が `badmatch` で即死する。型サーバーが再起動を繰り返して `pgo_pool_sup` が許容回数を使い切り、`pgo_pool` も巻き添えで落ちる。症状はプラグインの子の起動失敗（`[plugin event_logger] child "pool" failed to start …`）から、子を諦めた状態（`disabled after 5 consecutive failures …`）まで連なる。

**この不具合はこのプロジェクトの `gleam test` では検出できない。** テストはプラグイン自身のアプリケーションを起動するので `pgo` も一緒に立ち上がるためである。

## 開発

```sh
cd plugins-src/event_logger
gleam deps download
gleam build --warnings-as-errors
gleam test          # TEST_DATABASE_URL があれば統合テストも走る
gleam format --check src test
```

統合テストは使い捨ての Postgres に対して実行する。

```sh
docker run --rm -d -p 127.0.0.1:5433:5432 \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=nostr_no_su_test \
  --name nns-pg postgres:17-alpine
TEST_DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5433/nostr_no_su_test gleam test
docker rm -f nns-pg
```

**`manifest.toml` はコミットする。** 本体と共有するパッケージ（`gleam_stdlib` / `gleam_erlang` / `gleam_otp` / `gleam_json` / `exception`）は、影に入る側なので**本体の版で実行される**。版がずれても読み込み時には何も起きず、実行時に `undef` で壊れる。`gleam.toml` の制約を揃えるだけでは一致しない（`gleam deps download` は本体と独立に解決する）ため、一致は CI が必須チェックとして検査する。**版を上げるときは本体と同時に上げること。**

## 確認

```sh
docker compose logs nostr-no-su | grep plugin_loader
```

```
[plugin_loader] event_logger: 40 module(s) already provided by the host or another plugin are ignored (exception, gleam@bit_array, ...)
[plugin_loader] loaded 1 plugin(s) from /plugins: event_logger
```

影の件数が数百なら Elixir が混入している（ローカルでビルドしている）。上のビルド手順で作り直すこと。

```sh
docker compose logs nostr-no-su | grep -e '\[event_logger\]' -e '\[plugin event_logger\]'
```

```
[event_logger] schema ready
```

保存された行は Postgres から直接確認できる。

```sh
docker compose exec postgres psql -U nostr -d nostr_no_su \
  -c "select id, kind, tags->0->>0 from events order by received_at desc limit 3"
```

DB を止めると保存だけが止まり、監視は続く。復帰すると捨てた件数がまとめて報告される。

```
[event_logger] database unavailable: ConnectionUnavailable; retrying every 5000ms
[event_logger] database is back; dropped 12 events while it was unavailable
```
