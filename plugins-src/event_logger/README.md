# event_logger

監視で受信したイベントを Postgres の `event_logger_events` テーブルへ保存する外部プラグイン。NIP-01 の全フィールド（`tags` は jsonb）と取り込み時刻を 1 行として残し、同じイベントを複数のリレーから受け取っても 1 行だけ保存する。

`examples/plugins/` の 2 つが仕様の例示なのに対し、こちらは**第一級の同梱プラグイン**である。状態（保存アクター）を持ち、独自の依存（pog / pgo）を同梱し、独自の設定（`PLUGIN_EVENT_LOGGER_DATABASE_URL`）を受け取る。プラグイン API v1 が実用的なプラグインに足りることの実証でもある。

仕様の全文は [プラグイン API v1](../../docs/plugin-api.md) を参照すること。

## ビルド

このプラグインは docker イメージに同梱されており（`/app/plugins/event_logger`）、同梱版を使うだけならビルドは要らない。以下は改造版のための手順である。

<!-- この節の最初の sh ブロックは、CI（.github/workflows/ci.yml の plugin-readme-build）がリポジトリーのルートでそのまま実行する。 -->

**本体と同じイメージでビルドすること。** 理由は 2 つある。

- **OTP が違う BEAM はローダーが `badfile` で拒否する。**
- **ホスト環境でビルドすると同梱物が別物になる。** `opentelemetry_api` が `build_tools = ["rebar3", "mix"]` を持つため、ホストに elixir があると Gleam が `elixir` / `mix` / `logger` / `eex` を丸ごと vendor する（実測で計 516 モジュール。docker ビルドは 127。この数は本体の影に入る前の同梱物の総数である）。混入した Elixir 一式はコードパスに載るだけで誰も使わず、起動ログの影の行を無意味に膨らませる。

```sh
mkdir -p plugins/event_logger
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$PWD/plugins-src/event_logger:/src:ro" \
  -v "$PWD/plugins/event_logger:/out" \
  ghcr.io/gleam-lang/gleam:v1.17.0-erlang-alpine \
  sh -c 'cp -r /src /tmp/work && rm -rf /tmp/work/build && cd /tmp/work && gleam deps download \
         && gleam export erlang-shipment && cp -r build/erlang-shipment/. /out/'
chmod -R a+rX plugins
```

`/src` は読み取り専用でマウントするので、一度 `/tmp/work` へ複写してからビルドする。**複写したあとに `build/` を消すのを忘れないこと。** ローカルで一度ビルドしていると、Elixir 一式を含むホスト側の成果物がそのままコンテナーへ持ち込まれる。ローカルの `gleam export erlang-shipment` はスモークテストであって、その出力を `plugins/` に置いてはならない。

コンテナーは `--user` でホストの利用者として動かす。root で動かすと成果物が root 所有になり、非 root の利用者が続く `chmod` を実行すると EPERM で止まる。この手順は、コンテナーの uid がホストの uid と一致する構成（rootful の docker、Docker Desktop）を前提にする。この利用者はイメージの `/` に書けない（`HOME` も `/` になる）ので、複写先を誰でも書ける `/tmp` の下（`/tmp/work`）に置き、`gleam deps download` がキャッシュを置く `HOME` を `/tmp` にする。

## 置き方

`gleam export erlang-shipment` の出力を**そのまま**置く。ローダーは `<name>/<app>/ebin` のレイアウトを受け付けるので、flatten してはならない。

```
plugins/event_logger/event_logger/ebin/event_logger.beam   -- エントリー
plugins/event_logger/pog/ebin/…  pgo/ebin/…  pg_types/ebin/…
plugins/event_logger/entrypoint.sh                          -- ローダーは黙って無視する
```

エントリーモジュール名はディレクトリー名と一致させる（`plugins/event_logger` → モジュール `event_logger`）。同梱の `docker-compose.yml` は `./plugins` を `/plugins` に読み取り専用でマウントし、`PLUGIN_DIR=/app/plugins:/plugins` を渡す。同名のプラグインはイメージの `/app/plugins` の同梱版が勝つので、ここへ置いた改造版を読ませるには `PLUGIN_DIR=/plugins` を渡す。コンテナーは非 root（uid 1000）で動くため、ホスト側は誰でも読める権限にしておくこと。

## 設定

| 環境変数 | 必須 | 意味 |
| --- | --- | --- |
| `PLUGIN_EVENT_LOGGER_DATABASE_URL` | はい | 保存先の Postgres（`postgres://user:pass@host:5432/db`） |

この URL は管理 UI の `/plugins/event_logger/settings` に `postgres://<user>@<host>:<port>/<database>` の形で出る。パスワードはプラグインが取り除くので画面には出ない。接続先はこの環境変数だけで決まり、この画面から変えることはできない。保存の対象とするアカウントだけは同じ画面の `Monitored accounts`（日本語の管理 UI では「保存するアカウント」）の節から選べ、プラグイン自身の DB に保存される（初期値は全アカウント）。管理 UI にはもう 1 つ `/plugins/event_logger/timeline` があり、保存済みのイベントの直近 20 件を新しい順に出す。

設定が無い、あるいは URL として解釈できないときは `plugin_children/1` が `{error, Reason}` を返し、**このプラグインだけが読み込まれない**（本体の起動は止まらない）。起動ログに出るのは次の 1 行である。

```
[plugin_loader] event_logger: plugin_children/1 rejected the configuration (PLUGIN_EVENT_LOGGER_DATABASE_URL is required); configure it with PLUGIN_EVENT_LOGGER_*
```

## 保存が追いつかないとき

保存アクターは受け取ったイベントを 1 件ずつ Postgres へ挿入する。DB に到達できても挿入が遅いと、未処理のイベントがメールボックスに積まれていく。未処理が 1000 件を超えたら、500 件以下に減るまで届いたイベントを数えて捨て、保存を再開するときに捨てた件数を報告する。

```
[event_logger] too slow: 1001 events queued (limit 1000); dropping until it catches up
[event_logger] caught up; dropped 501 events while overloaded
```

件数を見るのはイベントを取り出すときなので、1 件の挿入の間に届いた分だけは 1000 件を超えうる。挿入は 5 秒で打ち切られ、打ち切られると DB に到達できないときと同じく保存を止める（「確認」の節の最後の 2 行）。

## 保存できないイベント

`content` かタグの値に NUL（U+0000）を含むイベントは保存されない。NIP-01 の JSON 文字列としては妥当だが、Postgres の `text` は NUL を持てず、`jsonb` は `\u0000` を受け付けない。挿入はそのイベントだけが失敗し、次の 1 行を出して保存を続ける。

```
[event_logger] insert failed for event <id>: PostgresqlError("22021", "character_not_in_repertoire", "invalid byte sequence for encoding \"UTF8\": 0x00")
```

タグの値に NUL があるときは `PostgresqlError("22P05", "untranslatable_character", "unsupported Unicode escape sequence")` になる。NUL を取り除いて保存しないのは、イベントの id と署名が元の `content` と `tags` から計算されており、書き換えた行は元のイベントとして検証できなくなるためである。

## `pgo` のアプリケーションを自分で起動していること

本体のローダーは**コードパスを足すだけでアプリケーションを起動しない**（[プラグイン API v1](../../docs/plugin-api.md) 第 8.1 節）。したがって同梱したアプリケーションの起動はプラグインの責任である。このプラグインは接続プールの起動シム `event_logger:start_pool/1` の先頭で `application:ensure_all_started(pgo)` を呼ぶ（冪等なので子の再起動のたびに呼ばれても害はない）。

呼ばないと次のように壊れる。`pg_types` のアプリが起動していないと `pg_types:update_map/3` の `application:get_key(pg_types, modules)` が `undefined` を返し、`pgo_type_server` が `badmatch` で即死する。型サーバーが再起動を繰り返して `pgo_pool_sup` が許容回数を使い切り、`pgo_pool` も巻き添えで落ちる。症状はプラグインの子の起動失敗（`[plugin event_logger] child "pool" failed to start …`）から、子を諦めた状態（`disabled after 5 consecutive failures …`）まで連なる。

**この不具合はこのプロジェクトの `gleam test` では検出できない。** テストはプラグイン自身のアプリケーションを起動するので `pgo` も一緒に立ち上がるためである。

## スキーマの版

`events` とインデックス（版 1）、監視対象の `monitored_accounts`（版 2）、タイムラインが読む `events_received_at` のインデックス（版 3）は版つきの移行で作り、版 4 でテーブルとインデックスの名前にプラグイン名の接頭辞を付けて `event_logger_events`、`event_logger_monitored_accounts`、`event_logger_events_received_at` などに改める（`docs/plugin-api.md` 第 5.3 節）。適用した版を `event_logger_schema_version` に記録する。保存アクターは起動時と保存を止めた後の再試行のたびに、記録された版より新しい移行を適用する。

記録された版がプラグインより新しい DB では、次の行を出して保存アクターが止まる。専用のスーパーバイザーが再起動するたびに同じ行が出て、子が諦められ、イベントが届くと `disabled` になる（`docs/plugin-api.md` 第 5.4 節）。戻す移行は無いので、古いプラグインに戻すには移行の前に取ったバックアップから戻す必要がある（取り方と戻し方は [バックアップと復旧](../../docs/operations.md) にある）。

```
[event_logger] database schema version 5 is newer than this plugin supports (up to version 4); stopping the store
```

## 開発

```sh
cd plugins-src/event_logger
gleam deps download
gleam build --warnings-as-errors
gleam test          # TEST_DATABASE_URL があれば統合テストも走る（CI は渡す）
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

**`manifest.toml` はコミットする。** 本体と共有するパッケージ（`gleam_stdlib` / `gleam_erlang` / `gleam_otp` / `gleam_json` / `exception` / `pog` / `pgo` / `pg_types` / `backoff` / `opentelemetry_api` / `gleam_time`。本体もアカウントストアのために `pog` に依存する）は、影に入る側なので**本体の版で実行される**。版がずれても読み込み時には何も起きず、実行時に `undef` で壊れる。`gleam.toml` の制約を揃えるだけでは一致しない（`gleam deps download` は本体と独立に解決する）ため、一致は CI が必須チェックとして検査する。**版を上げるときは本体と同時に上げること。**

## 確認

```sh
docker compose logs nostr-no-su | grep plugin_loader
```

```
[plugin_loader] event_logger: 120 module(s) already provided by the host or another plugin are ignored (backoff 1.1.6, exception 2.1.1, gleam_erlang 1.3.0, gleam_json 3.1.0, gleam_otp 1.2.0, gleam_stdlib 1.0.3, gleam_time 1.10.0, opentelemetry_api 1.5.0, pg_types 0.6.0, pgo 0.20.0, pog 4.1.0)
[plugin_loader] profile: 22 module(s) already provided by the host or another plugin are ignored (gleam_json 3.1.0, gleam_stdlib 1.0.3)
[plugin_loader] loaded 2 plugin(s) from /app/plugins: event_logger, profile
[plugin_loader] loaded no plugins from /plugins
```

影の件数が数百なら Elixir が混入している（ローカルでビルドしている）。上のビルド手順で作り直すこと。上は `./plugins` が空のとき（同梱の `event_logger` と `profile` だけ）の出力である。改造版を `./plugins` に置いて `PLUGIN_DIR=/plugins` を渡した構成では、`/app/plugins` を走査しないので 2 行目と 3 行目が出ず、4 行目が `[plugin_loader] loaded 1 plugin(s) from /plugins: event_logger` になる（1 行目の影の行は改造版でも出る）。`PLUGIN_DIR` を既定のまま改造版を置くと、同梱版が勝って `[plugin_loader] event_logger: module event_logger is already provided by the host or another plugin; skipped` と `[plugin_loader] loaded no plugins from /plugins (1 skipped)` が出る。

```sh
docker compose logs nostr-no-su | grep -e '\[event_logger\]' -e '\[plugin event_logger\]'
```

```
[event_logger] schema ready
```

保存された行は Postgres から直接確認できる。

```sh
docker compose exec postgres psql -U nostr -d nostr_no_su \
  -c "select id, kind, tags->0->>0 from event_logger_events order by received_at desc limit 3"
```

DB を止めると保存だけが止まり、監視は続く。復帰すると捨てた件数がまとめて報告される。

```
[event_logger] database unavailable: ConnectionUnavailable; retrying every 5000ms
[event_logger] database is back; dropped 12 events while it was unavailable
```

管理 UI のページも確認できる。ページの文言は管理 UI の表示の言語で出る（本体が `plugin_pages/2` と `plugin_page_content/3` に言語のコードを渡す。[プラグイン API v1](../../docs/plugin-api.md) 第 13.1 節）。英語では `Monitored accounts`・`Configuration`・`Runtime` の 3 つの見出し、登録アカウントごとのチェックと `Save` のボタン、マスクした URL、プールと保存アクターの `running` のバッジが 2 つ出る。日本語では見出しが「保存するアカウント」・「接続先と上限」・「プロセス」、ボタンが「保存する」、バッジが「動作中」になる。登録が 0 件のときは 1 つ目の節に空の状態の文だけが出る。`Timeline`（日本語では「タイムライン」）のタブを開くと、保存済みのイベントが 1 件 1 枚のカードで最大 20 枚出る。見出しは kind の名前と相対時刻（`post · 3 min ago` の形。日本語では `投稿 · 3 分前`）で、時刻にカーソルを置くと UTC の時刻が出る。カードの先頭には、書いたアカウントが登録アカウントならラベル（項目名は `account`、日本語では「アカウント」）と省略した `npub`、登録に無ければ省略した 16 進の `pubkey` と、イベントの `id` が出る。その下に本文が出る。280 文字（書記素）を超える本文は先頭の 280 文字に `…` を付けて切り、全文を `content` に畳む。本文が JSON の kind（0、3、6、16、10002）は本文をカードに出さず、`content` に畳む。本文が空なら本文も `content` も出ない。`tags`・`signature` は本文の後ろで畳まれている（`content`・`tags`・`signature`・`npub`・`pubkey`・`id` は NIP のフィールド名なので日本語でも訳さない）。0 件のときは空の状態の文だけが出る。チェックを 1 つも付けずに保存したときの理由（`select at least one account`）は、本体が送信の処理に言語を渡さないので英語のまま出る。

```sh
curl -s -u admin:<ADMIN_PASSWORD> http://127.0.0.1:8080/plugins/event_logger/settings
curl -s -u admin:<ADMIN_PASSWORD> http://127.0.0.1:8080/plugins/event_logger/timeline
curl -s -u admin:<ADMIN_PASSWORD> -H 'Accept-Language: ja' http://127.0.0.1:8080/plugins/event_logger/settings
```
