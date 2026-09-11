# Nostr-no-Su

Nostr のバンカー兼ユーティリティサーバー（Gleam / BEAM）。

NIP-46 で鍵を管理するバンカーであり、自分のアカウントのイベントを監視してプラグイン形式で様々な処理をするユーティリティサーバー。BEAM の並列処理と安定性を活かして効率的に Nostr のイベントを処理することを目指す。

## 現在の状態

NIP-46 リモート署名バンカーが動作する。クライアント（nsec.app / noStrudel 等）が `bunker://` URI で接続し、暗号化されたリクエスト経由で署名を委任できる。あわせて、設定したアカウントのイベントを監視してプラグインで処理する。

- **NIP-46 バンカー**: kind 24133 のリクエストを検証・復号し、`connect` / `get_public_key` / `sign_event` / `ping` / `nip44_encrypt` / `nip44_decrypt` / `logout` を処理。バンカーは監視とは別の専用接続を複数リレーに張れる（`BUNKER_RELAY_URL` カンマ区切り）。どれか 1 つでも生きていれば署名できる。secret を持たないクライアントは `auth_url` フローで管理 UI の承認を経て接続する
- **暗号**: BIP-340 Schnorr 署名と NIP-44 v2 暗号化を自前実装（公式テストベクターに一致）。プリミティブは OTP の `crypto`（OpenSSL）を利用し、NIF は不要
- **イベント監視**: 複数リレーへ同時接続（`RELAY_URL` カンマ区切り）。NIP-01 のコーデック、イベント ID の検証、リレー横断の重複排除、プラグイン機構（[プラグイン API v1](docs/plugin-api.md)）、プラグインの障害隔離、コンソールロガー、`PLUGIN_DIR` からの外部プラグイン読み込み
- 接続が切れたリレーは 5 秒後に個別に自動再接続（セッション状態は再接続をまたいで保持）
- **イベントロガー**: 外部プラグイン `event_logger` を `PLUGIN_DIR` に置き、`PLUGIN_EVENT_LOGGER_DATABASE_URL` を設定すると、監視で受信したイベントを `events` テーブルへ保存する（NIP-01 の全フィールド + `tags` は jsonb + 取り込み時刻）。同じイベントを複数のリレーから受け取っても 1 行だけ残る。ソースとビルド手順は `plugins-src/event_logger/`
- **管理 UI**: `http://127.0.0.1:8080/` でアカウントの接続 URI、リレーの接続状態、承認待ちの接続要求（承認・拒否）、承認済みセッション（取り消し可）、有効なプラグインとその状態を確認できる。HTTP Basic 認証（ユーザー名 `admin`）で、既定はループバックのみで待ち受ける
- **スーパービジョンツリー**: 全プロセスを `static_supervisor` の下で管理。バンカー actor や重複排除ディスパッチャーが落ちても再起動し、後続のリレー接続も張り直されて配線が復旧する

## 使い方

### バンカーとして使う

秘密鍵を用意して `ACCOUNT_KEYS` に設定して起動する:

```sh
ACCOUNT_KEYS=<64桁hexの秘密鍵> \
BUNKER_RELAY_URL=wss://relay.nsec.app,wss://relay.nostr.band \
gleam run
```

バンカーは監視とは別に専用の接続をリレーごとに張り、NIP-46 の購読だけを開く。`relay.nsec.app` のような NIP-46 専用リレー（kind 24133 以外の購読を拒否する）もバンカー用にはそのまま使える。複数指定すると `bunker://` URI に `relay=` が複数入り、どれか 1 つでも生きていれば署名の往復が成立する（応答は全バンカーリレーへ発行、リクエストの重複受信はエンジンが排除）。`BUNKER_RELAY_URL` を省略すると `RELAY_URL` と同じリレーを使う（`RELAY_URL` も空なら `wss://relay.damus.io`）。

起動すると各アカウントの接続 URI がログに出力される:

```
[bunker] bunker://<signer-pubkey>?relay=wss%3A%2F%2Frelay.nsec.app&secret=<secret>
```

この `bunker://...` をクライアントの「Nostr Connect / リモート署名」に貼り付けると接続できる。以降、そのクライアントからの署名要求をバンカーが処理する。

> ⚠️ **秘密鍵とログの扱い**: `ACCOUNT_KEYS` は本物の秘密鍵。バージョン管理に含めず `.env` などで渡すこと。また起動ログの `bunker://` URI には secret が含まれるため、`docker logs` の共有には注意。

#### 対応クライアントと相互運用

kind 24133 のペイロードは **NIP-44** で暗号化する（現行仕様）。NIP-04 のみの古いクライアントは非対応（受信するとログに記録して無視）。ephemeral イベントなので、AUTH やレート制限のあるリレーだと転送されないことがある（例: `relay.damus.io` は連続リクエストで応答イベントを rate-limit で拒否することがある）。`BUNKER_RELAY_URL` には `wss://relay.nsec.app` などバンカー向けリレーを推奨。

### 管理 UI

起動すると `http://127.0.0.1:8080/` で管理 UI にアクセスできる。ダッシュボードにはアカウント（署名者 pubkey と `bunker://` 接続 URI: secret 入りのものと、承認を経るもの）、承認待ちの接続要求（承認・拒否ボタン付き）、リレーの接続状態（監視用 / バンカー用の別）、承認済みのクライアントセッション（取り消しボタン付き）、有効なプラグインとその状態（`running` / `overloaded` / `disabled`）、イベントロガーの有効／無効が並ぶ。

認証は HTTP Basic で、ユーザー名は `admin` 固定。パスワードは `ADMIN_PASSWORD` で指定する。未設定なら起動ごとにランダム生成してログに出力する:

```
[admin] generated password for user "admin": <password>
```

`ADMIN_PORT` で待ち受けポートを変更でき、空文字列（`ADMIN_PORT=`）にすると管理 UI を無効にできる。`GET /healthz` だけは認証なしで `ok` を返す。イメージにはこれを叩く `HEALTHCHECK` が入っているため、`docker ps` の `STATUS` にコンテナーの状態が出る。`ADMIN_PORT=` で管理 UI を無効にした構成では待ち受けが無いのでチェック自体を省略し、healthy として扱う。

待ち受けアドレスの既定は `127.0.0.1`（ループバックのみ）で、`ADMIN_BIND` で変更する。コンテナーの外へポートを公開するには `ADMIN_BIND=0.0.0.0` が必要になるが、その場合は公開範囲を別途絞ること（同梱の compose はホスト側のループバックにだけ公開する）。

> ⚠️ **平文 HTTP である**: Basic 認証の資格情報は暗号化されずに送られ、ページには署名権限そのものである secret 入りの `bunker://` URI が表示される。localhost か Docker ネットワーク内での利用を前提とし、外部に公開するときは必ずリバースプロキシーで TLS を終端すること。

#### 接続の承認（auth_url フロー）

secret を持たない `bunker://` URI（ダッシュボードの「Connection URI (approval)」の列）で接続すると、バンカーはその場では承認せず、NIP-46 の `auth_url` 応答で承認ページの URL をクライアントへ返す。クライアントはその URL をブラウザーで開き、管理 UI にログインして内容（署名者・クライアント pubkey・経過時間）を確認したうえで承認または拒否する。承認するとバンカーは元のリクエストと同じ id で `ack` を返し、待っていたクライアントの接続が完了する。拒否するとエラーを返す。

承認ページの URL は `ADMIN_BASE_URL` を土台に `<base>/approve/<token>` として組み立てる（既定は `http://localhost:<ADMIN_PORT>`）。クライアントのブラウザーから開ける URL である必要があるため、リバースプロキシーの背後に置くときや別のホストから使うときは公開 URL を設定すること。管理 UI を無効（`ADMIN_PORT=`）にすると承認フローも無効になり、secret の一致しない `connect` は従来どおり `invalid secret` で拒否する。

承認される前にクライアントが再読み込みして `connect` を送り直した場合、承認待ちは最新の要求に置き換わる（同じクライアントの保留が並ばないようにするため）。先に受け取った `auth_url` のページは 404 になるので、新しく開かれた方の承認ページを使う。

承認待ちはダッシュボードの「Pending connections」からも承認・拒否でき、10 分で失効する。一度承認したクライアントは、以後 secret 無しで `connect` し直しても承認を求められない（取り消すには「Approved sessions」の Revoke を使う）。

状態を変えるリクエスト（`POST /sessions/revoke`、`POST /approve/<token>`、`POST /deny/<token>`）は `Origin` / `Referer` と `Host` を突き合わせて CSRF を防いでいる。`Origin` を送らないクライアント（curl など）はそのまま通る。前段にリバースプロキシーを置く場合は **`Host` ヘッダーをそのまま転送すること**。書き換えるとブラウザーからの POST が 400 になる。

### 監視のみ（バンカー無効）

`ACCOUNT_KEYS` を空にすると監視のみモードで動く:

```sh
docker compose up --build
```

### docker compose

compose には Postgres（`postgres:17-alpine`）が同梱されており、アプリは healthcheck が通ってから起動する。データは `postgres-data` volume に永続化され、`docker compose down -v` で消える。Postgres のポートはホストに公開しない（アプリは compose ネットワーク経由で到達する）ため、保存されたイベントは `docker compose exec postgres psql -U nostr -d nostr_no_su` で確認する。

管理 UI のポートはホストのループバック（`127.0.0.1:8080`）にだけ公開する。コンテナー内では `ADMIN_BIND=0.0.0.0` を渡して全インターフェースで待ち受けさせ、外部からの到達性はこの公開先で絞っている。`ADMIN_PORT` を変えると公開ポートも追従する。

**`PLUGIN_DIR` に置いた BEAM は本体と同じ VM・同じ権限で動く。サンドボックスは無く、秘密鍵を持つプロセスにも到達できる（`sys:get_state/1`）。信頼できるものだけを置くこと。** 第三者から受け取ったプラグインはソースを読んでから置く。

外部プラグインは `./plugins` に置くと読み込まれる（コンテナー内の `/plugins` に読み取り専用でマウントし、`PLUGIN_DIR=/plugins` を渡している）。コンテナーは非 root（uid 1000）で動くため、**置いたあとに `chmod -R a+rX plugins` が必要**である。プラグインの置き方は [プラグイン API v1](docs/plugin-api.md) の第 8 章、動作確認用の例は `examples/plugins/file_logger/`（状態を持たない例）と `examples/plugins/counter/`（状態を持つ例）、実プラグインは `plugins-src/event_logger/`（イベントを Postgres へ保存する）を参照。`PLUGIN_DIR=` と空にすると読み込みを無効にできる。

プラグイン固有の設定は `PLUGIN_<NAME>_<KEY>` の形の環境変数で渡す（`file_logger` の出力先なら `PLUGIN_FILE_LOGGER_PATH`）。compose の `environment:` は明示的な列挙なので、自分のプラグインの分は `docker-compose.yml` に書き足すこと。設定が足りないプラグインは読み込み時に理由を 1 行出して**そのプラグインだけが無効になり**、本体の起動と他のプラグインには影響しない（[プラグイン API v1](docs/plugin-api.md) の第 6 章）。

資格情報は compose 内で `nostr` / `nostr` / `nostr_no_su` に固定されている。変えるときは `postgres` サービスの `POSTGRES_*` と `PLUGIN_EVENT_LOGGER_DATABASE_URL` の両方を合わせること。

**`DATABASE_URL` は廃止した。** イベント保存は本体の機能ではなく外部プラグイン `event_logger` になり、設定も `PLUGIN_EVENT_LOGGER_DATABASE_URL` へ移った（`PLUGIN_<NAME>_<KEY>` の規則）。**空文字列の意味も変わっている。** 旧構成では `DATABASE_URL=` で保存を黙って無効にできたが、`PLUGIN_EVENT_LOGGER_DATABASE_URL=` は空値が落ちてプラグインにはキーごと届かないため、設定不足として拒否され起動のたびに 1 行出る。**保存を無効にする正しいやり方は、プラグインを置かないことである。**

### 環境変数

| 変数 | デフォルト | 説明 |
| --- | --- | --- |
| `RELAY_URL` | `wss://relay.damus.io` | 監視先リレーの URL（カンマ区切りで複数可）。空にすると監視無効（バンカーのみ） |
| `BUNKER_RELAY_URL` | `RELAY_URL` と同じ | バンカーが購読・応答するリレーの URL（カンマ区切りで複数可）。`RELAY_URL` も空なら `wss://relay.damus.io` |
| `ACCOUNT_KEYS` | （空） | バンカーが署名するアカウントの hex 秘密鍵（カンマ区切り）。空ならバンカー無効 |
| `BUNKER_SECRET` | （空） | 接続 secret。未設定なら起動ごとにランダム生成し、URI をログに出力 |
| `PUBKEYS` | （空） | 監視するアカウントの hex 公開鍵（カンマ区切り）。空なら直近のイベントを購読 |
| `PLUGIN_EVENT_LOGGER_DATABASE_URL` | （空） | 外部プラグイン `event_logger` 固有の設定。イベントを保存する Postgres の URL（`postgres://user:pass@host:5432/db`）。プラグインを置いていなければ誰も読まない。空にしても無効化にはならない（保存をやめるならプラグインを置かない）。docker compose では同梱の Postgres を指す |
| `PLUGIN_DIR` | （空） | 外部プラグインを探すディレクトリー。空なら読み込まない。ここに置いた BEAM は本体と同じ VM で動くため、信頼できるものだけを置くこと（[プラグイン API v1](docs/plugin-api.md) の第 8 章） |
| `PLUGIN_<NAME>_<KEY>` | （空） | プラグイン固有の設定。`<NAME>` は `plugin_name/0` の値を大文字化し `[A-Z0-9]` 以外を `_` にしたもの。プラグインには `<KEY>` を小文字にした binary キーの map として届く（[プラグイン API v1](docs/plugin-api.md) の第 6 章） |
| `ADMIN_PORT` | `8080` | 管理 UI が待ち受けるポート（1〜65535）。空文字列なら管理 UI を無効にする。範囲外や数値でない値は理由をログに出して無効にする |
| `ADMIN_BIND` | `127.0.0.1` | 管理 UI が bind するアドレス。コンテナー外へ公開するには `0.0.0.0` が必要 |
| `ADMIN_PASSWORD` | （空） | 管理 UI の Basic 認証パスワード（ユーザー名は `admin`）。未設定なら起動ごとにランダム生成してログに出力 |
| `ADMIN_BASE_URL` | `http://localhost:<ADMIN_PORT>` | 承認ページ（`auth_url`）の URL を組み立てる管理 UI の公開 URL。クライアントのブラウザーから開ける値にする |

### ローカル開発 (Gleam 1.17.0 / Erlang OTP 29 で検証)

```sh
gleam run   # 実行
gleam test  # テスト（BIP-340 / NIP-44 公式ベクター + バンカーのループバック）
```

CI と Docker イメージはどちらも Gleam 1.17.0 / OTP 29 で、検証しているのはこの組み合わせだけ。より古い OTP でも動く可能性はあるが確認していない。

`event_logger` プラグインは独立した Gleam プロジェクトなので、テストもそちらで実行する。統合テストは `TEST_DATABASE_URL` が設定されているときだけ走る（未設定ならスキップして 1 行ログを出す）:

```sh
docker run -d --name nns-pg-test -p 127.0.0.1:5433:5432 \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=nostr_no_su_test postgres:17-alpine
cd plugins-src/event_logger
TEST_DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5433/nostr_no_su_test gleam test
docker rm -f nns-pg-test
```

## 構成

本体の内部構造は [システム構成](docs/architecture.md) に図で示してある。

```
src/nostr_no_su.gleam                        -- エントリポイント（設定の読み込みとツリー仕様の組み立て）
src/nostr_no_su/app.gleam                    -- スーパービジョンツリーの構成
src/nostr_no_su/admin.gleam                  -- 管理 UI の HTTP サーバー（wisp / mist）とルーティング
src/nostr_no_su/admin/dashboard.gleam        -- ダッシュボードの描画（スナップショット → HTML の純粋関数）
src/nostr_no_su/config.gleam                 -- 環境変数からの設定読み込み
src/nostr_no_su/dedup.gleam                  -- リレー横断のイベント重複排除ディスパッチャー（actor）
src/nostr_no_su/dedup/window.gleam           -- 直近のイベント id のスライディングウィンドウ（純粋）
src/nostr_no_su/hex.gleam                    -- 16 進文字列とバイト列の相互変換
src/nostr_no_su/log.gleam                    -- ログ 1 行の組み立て（接頭辞付き）
src/nostr_no_su/named.gleam                  -- 名前付きアクターへの安全な送信・問い合わせ
src/nostr_no_su/random.gleam                 -- 推測されては困る値のための乱数
src/nostr_no_su/time.gleam                   -- 現在時刻 (FFI)
src/nostr_no_su/crypto/secp256k1.gleam       -- 点演算・鍵導出・ECDH
src/nostr_no_su/crypto/bip340.gleam          -- BIP-340 Schnorr 署名 / 検証
src/nostr_no_su/crypto/nip44.gleam           -- NIP-44 v2 暗号化
src/nostr_no_su/nostr/event.gleam            -- Event 型・コーデック・ID 計算・署名
src/nostr_no_su/nostr/filter.gleam           -- 購読フィルター
src/nostr_no_su/nostr/message.gleam          -- クライアント⇄リレーのメッセージ
src/nostr_no_su/relay_client.gleam           -- WebSocket クライアント (stratus)
src/nostr_no_su/relay_connection.gleam       -- リレー 1 本ぶんの接続を保つ actor（切断検知と再接続）
src/nostr_no_su/bunker.gleam                 -- バンカーの actor（セッション状態を保持）
src/nostr_no_su/bunker/engine.gleam          -- NIP-46 リクエスト処理の純粋コア
src/nostr_no_su/bunker/rpc.gleam             -- JSON-RPC コーデック
src/nostr_no_su/bunker/account.gleam         -- 鍵材料と bunker:// URI
src/nostr_no_su/plugin.gleam                 -- プラグイン機構（プラグイン API v1 の検証と読み込み）
src/nostr_no_su/plugin_children.gleam        -- 任意エクスポート plugin_children/0・/1 の検証と子仕様への変換
src/nostr_no_su/plugin_config.gleam          -- プラグイン固有の設定（PLUGIN_<NAME>_<KEY>）の切り出しと map への変換
src/nostr_no_su/plugin_loader.gleam          -- 外部プラグインの走査とコードパスへの追加
src/nostr_no_su/plugin_runner.gleam          -- プラグイン 1 つぶんの実行プロセス（隔離・時間制限・無効化）
src/nostr_no_su/plugins/console_logger.gleam -- コンソールロガープラグイン
src/nostr_no_su_ffi.erl                      -- OTP への FFI（crypto / code / file / process: 監視付きワーカーの生成と終了理由の整形）
vendor/stratus/                              -- パッチ済み stratus（下記参照）
examples/plugins/file_logger/                -- 外部プラグインの例（状態を持たず、設定を受け取る Erlang 1 ファイル）
examples/plugins/counter/                    -- 外部プラグインの例（plugin_children/0 で子プロセスを申告する）
plugins-src/event_logger/                    -- 同梱の外部プラグイン（Postgres へ保存する。独自の依存と設定を持つ Gleam プロジェクト）
docs/plugin-api.md                           -- プラグイン API v1 の仕様（プラグイン作者向け）
docs/architecture.md                         -- システム構成（プロセス・経路・読み込み・配置・設定の図解）
```

## 設計上の判断・既知の制約

- **スーパービジョンツリー**: root（one_for_one）の下にプラグイン・監視・バンカーのサブツリーを置き、プラグインのサブツリーは one_for_one、他は rest_for_one。先頭の actor（重複排除ディスパッチャー / バンカー actor）が再起動すると後続のリレー接続も再起動し、購読と publisher の再設定が自然に行われる。actor は名前付きプロセスなので、リレー接続は名前宛てに送信すれば再起動後のプロセスにそのまま届く
- **プラグインは専用プロセスで動かす**: プラグイン 1 つにつきランナーを 1 つ、root（one_for_one）直下の `plugins` サブツリーに置く。ディスパッチャーはイベントを送るだけで戻るので、遅いプラグインが他のプラグインや監視を止めない。プラグインのイベント処理関数はイベントごとに使い捨てのプロセス（`erlang:spawn_monitor/1`。**リンクは張らない**）で動かすため、プラグインの例外・異常終了・ハングはランナーの死にならない。**プラグインの不調で supervisor の再起動が起きない**ということであり、root の `restart_tolerance(3, 60)` を消費してアプリ全体を落とすことがない。1 件あたり 30 秒で打ち切り、連続 5 回失敗したプラグインは無効化してログに出し、以後はイベントを捨てて件数を数える（管理 UI には `disabled` として残る。再有効化は本体の再起動か、ランナーの強制終了）。未処理のイベントが 1000 件を超えたプラグインは、キューが空になるまで捨てて復帰時に件数を報告する（`event_logger` プラグインが DB 到達不能時に行うのと同じ形。捨てるのは超過分だけでなくバックログ全体なので、配信は best-effort である）。ワーカーの終了理由は FFI 側で `error:badarg` の形の 1 行に整えている。DOWN の理由は既定ではスタックトレース込みで数百文字になり、ログにもダッシュボードにも収まらないため
- **プラグインが申告した子プロセスは Temporary で載せる**: 任意エクスポート `plugin_children/0` を持つプラグインの子は、プラグインごとの専用スーパーバイザー（one_for_one、10 秒に 5 回）にまとめ、その子仕様を **Temporary** にする。段を挟むだけではクラッシュループを止められないので、歯止めは再起動の型で作る。子スーパーバイザーが諦めると理由 `shutdown` で終了し、親は再起動もせず許容回数も消費しない（`supervisor.erl` の `do_restart(shutdown, ...)` は `add_restart/1` を通らない）。Transient ではなく Temporary にするのは、仕様ごと削除されることと、外部からの kill のような別の理由で落ちたときにも再起動されないためである。代償として、一度諦めた子は本体を再起動するまで戻らない。起動時の失敗は空のスーパーバイザーで吸収してアプリの起動を止めず、理由は子ごとの 1 行ログに出す
- **設定を受け取る口はアリティ +1 の任意エクスポートで足す**: プラグイン固有の設定は環境変数 `PLUGIN_<NAME>_<KEY>` から切り出し、binary キーの map として `plugin_children/1` と `handle_event/2` に渡す。既存の `plugin_children/0` / `handle_event/1` を持つプラグインは無変更で動くので、**API バージョンは 1 のまま**である（`handle_event` だけは必須側のアリティが `/1` または `/2` の 2 通りになるが、既存のプラグインは 1 つも落ちないため破壊的変更にあたらない）。設定不足の申告を宣言的な必須キー一覧ではなく `plugin_children/1` の `{error, Reason}` にしたのは、**値の妥当性まで検査できる**のがプラグイン側だけだからである。キーの存在と、その値が Postgres の URL として解釈できることは別で、後者を読み込み時に検査できないと不正な値が「子の起動失敗 → 連続失敗 → `disabled`」という遠回りな症状に化ける
- **リレー接続 actor は exit を trap する**: stratus のプロセスは接続 actor にリンクされる。切断のたびに actor ごと落とすと supervisor の再起動回数を消費してしまうため、exit を trap してメッセージとして受け取り、5 秒後の再接続をスケジュールする。gleam_otp の actor ループは trap した exit を未知のメッセージとして捨てるので、supervisor からの shutdown は接続 actor 側で検出し、trap を解除して同じ理由で exit し直す（リンク経由でソケットも一緒に終了する）
- **バンカーは専用接続（リレーごと）**: 監視と接続を分けることで、NIP-46 以外の購読を拒否するリレー（relay.nsec.app 等）をバンカー用に使える。応答はどのリレーから来たリクエストでも全バンカーリレーへ発行する。クライアントは URI の `relay=` を全部聴くので、リレーが 1 つ生きていれば往復が成立する
- **イベント保存は外部プラグイン**: pog の接続プールと保存 actor は本体ではなくプラグインが `plugin_children/1` で申告し、`plugins` サブツリーの下（one_for_one）で動く。プラグインごとのサブスーパーバイザーが Temporary なので、DB 由来のクラッシュループが本体を巻き込むことはない。保存 actor はプールを名前で参照するため、rest_for_one でなくても再起動をまたいで配線が保たれる。DB に到達できない間は保存を止めて破棄した件数を数え、復帰時にまとめて報告する（挿入のたびに接続を待つと actor がブロックしてメールボックスが伸びるため）。接続の復旧は pog のプールに任せる
- **管理 UI は root 直下の独立した子**: mist（HTTP サーバー）は監視・バンカー・保存のどれにも依存しないため、root（one_for_one）に並べる。表示する状態はハンドラーが直接触らず、Context に注入された関数から名前付き actor へ問い合わせて取る。問い合わせが失敗しても（再起動中、タイムアウト）ページ全体を失敗させず、その項目だけ「未接続」「該当なし」として描画する。描画は「状態のスナップショット → HTML 文字列」の純粋関数で、テンプレートエンジンも JS フレームワークも使わない
- **管理 UI は既定でループバックのみ**: ダッシュボードには secret 入りの `bunker://` URI が載るため、既定 (`ADMIN_BIND=127.0.0.1`) では LAN に露出しない。Docker はホストの iptables を直接操作するので、ポートを公開したうえでファイアウォールに頼る形は避け、compose 側でホストのループバックにだけ公開している
- **監視はバンカー自身の NIP-46 通信を処理しない**: NIP-01 のフィルターには kind の否定が無いため、`PUBKEYS` に署名者を含めて `RELAY_URL` と `BUNKER_RELAY_URL` を同じリレーにすると、バンカーの応答（kind 24133）が監視の購読にも届く。これはプラグインに渡す前に落とすので、コンソールにも `events` テーブルにも NIP-46 の往復は現れない（kind 24133 は NIP-01 上リレーが保存しない想定のイベントで、保存する意味も無い）
- **監視の重複排除は世代式スライディングウィンドウ**: 複数リレーが同じイベントを配送するため、直近のイベント id（上限 4096〜8192 件）を覚えてプラグインには 1 回だけ渡す。再接続時のストアドイベント再配送もこれで吸収する
- **サイナー鍵 = ユーザー鍵**: 仕様で許可されている。別鍵にすると再起動で URI が無効化されるため v0 では同一にしている
- **secret は再利用可**: 仕様は single-use だが、セッションがインメモリのため再起動でオンボーディングが壊れないよう、正しい secret を知るクライアントの接続を許可する
- **接続の承認は auth_url フロー**: secret の一致しない `connect` は、管理 UI が有効なら承認待ちにして `auth_url` 応答（`result` が `"auth_url"`、`error` が承認ページの URL）を返し、承認された時点で元のリクエストと同じ id で本来の応答を送る。判断も応答イベントの組み立ても純粋なエンジンに置き、承認トークンの乱数と現在時刻は actor が注入する。管理 UI が無効なら承認する手段が無いので、従来どおり `invalid secret` で拒否する
- **セッションと承認待ちはインメモリ**: 再起動するとクライアントは再 `connect` が必要（secret 再利用可なので実害は小）。承認待ちも同じく永続化せず、10 分で失効する。承認済みのクライアントは secret 無しで `connect` し直しても承認を求められないが、再起動後は改めて承認が要る
- **バンカー actor は起動時刻より古いリクエストを処理しない**: リプレイ防止の `seen` ウィンドウはバンカー actor の中にしかなく、プロセスの再起動でも actor の再起動でも空になる。kind 24133 を保存するリレー（NIP-01 上は保存しない想定だが strfry などは保存する）が再購読で処理済みのリクエストを再配送すると、記憶していないため新規として実行し、`sign_event` をやり直して応答を再発行したり、取り消したはずのセッションを復活させたりしてしまう。そこで actor は起動時刻を刻み、`created_at` がそれより古いリクエストをエンジンが落とす。この起点は actor が生きているあいだ動かないので、切断していた間に届いたリクエストを購読の猶予（`since = 現在時刻 - 60 秒`）で拾い直す動きは従来どおり働く。`created_at` は秒までしか持たないため判定は秒単位で、起動と同じ秒のリクエストは通す（起動直後に届いた正当なリクエストを落とすと、クライアントは応答を待ったまま失敗するため）。停止から再起動までが同じ秒に収まった場合、その秒のリクエストは再実行されうる。さらに、判定に使うのはクライアントが自己申告する `created_at` なので、時計が進んでいるクライアントには保護が効かない。ずれが D 秒なら、リレーが再配送しうる `D + 60` 秒のうち `D` 秒ぶんの再起動では再実行が起きる（上限は受付ウィンドウの ±10 分）。副作用として、時計が遅れているクライアントのリクエストは、actor の起動直後、そのずれの秒数ぶんだけ弾かれうる
- **認証の多層防御**: NIP-44 の復号成功が送信者認証になる + 受信リクエストの BIP-340 署名検証 + `created_at` の ±10 分チェック + イベント ID の重複排除
- `nostrconnect://`（クライアント起点フロー）/ NIP-04 / `switch_relays` は未対応

### vendor/stratus について

stratus 3.0.0 はハンドシェイクで `permessage-deflate` を必ずオファーするが、依存先の gramps 6.0.1 は分割された圧縮メッセージをフレーム単位で inflate するため、strfry 系リレーが送る複数フレームの圧縮メッセージで zlib の `data_error` によりクラッシュする。回避のため、圧縮のオファーを削除した stratus を vendor している（パッチは 1 行、`vendor/stratus/src/stratus.gleam` 参照）。上流で修正されたら hex 版に戻す。

## ロードマップ

- [x] BIP-340 (schnorr) 署名の検証・生成
- [x] NIP-46 バンカー（複数アカウントの鍵管理）
- [x] 監視のマルチリレー対応（リレー横断の重複排除つき）
- [x] バンカーのマルチリレー対応（URI に複数 `relay=`、応答は全リレーへ発行）
- [x] スーパービジョンツリー
- [x] 管理 UI での接続承認（auth_url フロー）
- [x] イベントロガープラグイン（Postgres へ保存）
- [x] 管理 UI（Gleam / wisp）
