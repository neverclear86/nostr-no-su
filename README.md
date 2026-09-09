# Nostr-no-Su

Nostr のバンカー兼ユーティリティサーバー（Gleam / BEAM）。

NIP-46 で鍵を管理するバンカーであり、自分のアカウントのイベントを監視してプラグイン形式で様々な処理をするユーティリティサーバー。BEAM の並列処理と安定性を活かして効率的に Nostr のイベントを処理することを目指す。

## 現在の状態

NIP-46 リモート署名バンカーが動作する。クライアント（nsec.app / noStrudel 等）が `bunker://` URI で接続し、暗号化されたリクエスト経由で署名を委任できる。あわせて、設定したアカウントのイベントを監視してプラグインで処理する。

- **NIP-46 バンカー**: kind 24133 のリクエストを検証・復号し、`connect` / `get_public_key` / `sign_event` / `ping` / `nip44_encrypt` / `nip44_decrypt` / `logout` を処理。バンカーは監視とは別の専用接続を複数リレーに張れる（`BUNKER_RELAY_URL` カンマ区切り）。どれか 1 つでも生きていれば署名できる。secret を持たないクライアントは `auth_url` フローで管理 UI の承認を経て接続する
- **暗号**: BIP-340 Schnorr 署名と NIP-44 v2 暗号化を自前実装（公式テストベクターに一致）。プリミティブは OTP の `crypto`（OpenSSL）を利用し、NIF は不要
- **イベント監視**: 複数リレーへ同時接続（`RELAY_URL` カンマ区切り）。NIP-01 のコーデック、イベント ID の検証、リレー横断の重複排除、プラグイン機構、コンソールロガー
- 接続が切れたリレーは 5 秒後に個別に自動再接続（セッション状態は再接続をまたいで保持）
- **Postgres ロガー**: `DATABASE_URL` を設定すると、監視で受信したイベントを `events` テーブルへ保存する（NIP-01 の全フィールド + `tags` は jsonb + 取り込み時刻）。同じイベントを複数のリレーから受け取っても 1 行だけ残る
- **管理 UI**: `http://127.0.0.1:8080/` でアカウントの接続 URI、リレーの接続状態、承認待ちの接続要求（承認・拒否）、承認済みセッション（取り消し可）、有効なプラグインを確認できる。HTTP Basic 認証（ユーザー名 `admin`）で、既定はループバックのみで待ち受ける
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

起動すると `http://127.0.0.1:8080/` で管理 UI にアクセスできる。ダッシュボードにはアカウント（署名者 pubkey と `bunker://` 接続 URI: secret 入りのものと、承認を経るもの）、承認待ちの接続要求（承認・拒否ボタン付き）、リレーの接続状態（監視用 / バンカー用の別）、承認済みのクライアントセッション（取り消しボタン付き）、有効なプラグインと Postgres 保存の有効／無効が並ぶ。

認証は HTTP Basic で、ユーザー名は `admin` 固定。パスワードは `ADMIN_PASSWORD` で指定する。未設定なら起動ごとにランダム生成してログに出力する:

```
[admin] generated password for user "admin": <password>
```

`ADMIN_PORT` で待ち受けポートを変更でき、空文字列（`ADMIN_PORT=`）にすると管理 UI を無効にできる。`GET /healthz` だけは認証なしで `ok` を返すので、コンテナーの healthcheck に使える。

待ち受けアドレスの既定は `127.0.0.1`（ループバックのみ）で、`ADMIN_BIND` で変更する。コンテナーの外へポートを公開するには `ADMIN_BIND=0.0.0.0` が必要になるが、その場合は公開範囲を別途絞ること（同梱の compose はホスト側のループバックにだけ公開する）。

> ⚠️ **平文 HTTP である**: Basic 認証の資格情報は暗号化されずに送られ、ページには署名権限そのものである secret 入りの `bunker://` URI が表示される。localhost か Docker ネットワーク内での利用を前提とし、外部に公開するときは必ずリバースプロキシで TLS を終端すること。

#### 接続の承認（auth_url フロー）

secret を持たない `bunker://` URI（ダッシュボードの「Connection URI (approval)」の列）で接続すると、バンカーはその場では承認せず、NIP-46 の `auth_url` 応答で承認ページの URL をクライアントへ返す。クライアントはその URL をブラウザーで開き、管理 UI にログインして内容（署名者・クライアント pubkey・経過時間）を確認したうえで承認または拒否する。承認するとバンカーは元のリクエストと同じ id で `ack` を返し、待っていたクライアントの接続が完了する。拒否するとエラーを返す。

承認ページの URL は `ADMIN_BASE_URL` を土台に `<base>/approve/<token>` として組み立てる（既定は `http://localhost:<ADMIN_PORT>`）。クライアントのブラウザーから開ける URL である必要があるため、リバースプロキシの背後に置くときや別のホストから使うときは公開 URL を設定すること。管理 UI を無効（`ADMIN_PORT=`）にすると承認フローも無効になり、secret の一致しない `connect` は従来どおり `invalid secret` で拒否する。

承認される前にクライアントが再読み込みして `connect` を送り直した場合、承認待ちは最新の要求に置き換わる（同じクライアントの保留が並ばないようにするため）。先に受け取った `auth_url` のページは 404 になるので、新しく開かれた方の承認ページを使う。

承認待ちはダッシュボードの「Pending connections」からも承認・拒否でき、10 分で失効する。一度承認したクライアントは、以後 secret 無しで `connect` し直しても承認を求められない（取り消すには「Approved sessions」の Revoke を使う）。

状態を変えるリクエスト（`POST /sessions/revoke`、`POST /approve/<token>`、`POST /deny/<token>`）は `Origin` / `Referer` と `Host` を突き合わせて CSRF を防いでいる。`Origin` を送らないクライアント（curl など）はそのまま通る。前段にリバースプロキシを置く場合は **`Host` ヘッダーをそのまま転送すること**。書き換えるとブラウザーからの POST が 400 になる。

### 監視のみ（バンカー無効）

`ACCOUNT_KEYS` を空にすると監視のみモードで動く:

```sh
docker compose up --build
```

### docker compose

compose には Postgres（`postgres:17-alpine`）が同梱されており、アプリは healthcheck が通ってから起動する。データは `postgres-data` volume に永続化され、`docker compose down -v` で消える。Postgres のポートはホストに公開しない（アプリは compose ネットワーク経由で到達する）ため、保存されたイベントは `docker compose exec postgres psql -U nostr -d nostr_no_su` で確認する。

管理 UI のポートはホストのループバック（`127.0.0.1:8080`）にだけ公開する。コンテナー内では `ADMIN_BIND=0.0.0.0` を渡して全インターフェースで待ち受けさせ、外部からの到達性はこの公開先で絞っている。`ADMIN_PORT` を変えると公開ポートも追従する。

資格情報は compose 内で `nostr` / `nostr` / `nostr_no_su` に固定されている。変えるときは `postgres` サービスの `POSTGRES_*` と `DATABASE_URL` の両方を合わせること。`DATABASE_URL=` を空にすると Postgres への保存だけを無効化できる。

### 環境変数

| 変数 | デフォルト | 説明 |
| --- | --- | --- |
| `RELAY_URL` | `wss://relay.damus.io` | 監視先リレーの URL（カンマ区切りで複数可）。空にすると監視無効（バンカーのみ） |
| `BUNKER_RELAY_URL` | `RELAY_URL` と同じ | バンカーが購読・応答するリレーの URL（カンマ区切りで複数可）。`RELAY_URL` も空なら `wss://relay.damus.io` |
| `ACCOUNT_KEYS` | （空） | バンカーが署名するアカウントの hex 秘密鍵（カンマ区切り）。空ならバンカー無効 |
| `BUNKER_SECRET` | （空） | 接続 secret。未設定なら起動ごとにランダム生成し、URI をログに出力 |
| `PUBKEYS` | （空） | 監視するアカウントの hex 公開鍵（カンマ区切り）。空なら直近のイベントを購読 |
| `DATABASE_URL` | （空） | イベントを保存する Postgres の URL（`postgres://user:pass@host:5432/db`）。空なら保存しない。docker compose では同梱の Postgres を指す |
| `ADMIN_PORT` | `8080` | 管理 UI が待ち受けるポート（1〜65535）。空文字列なら管理 UI を無効にする。範囲外や数値でない値は理由をログに出して無効にする |
| `ADMIN_BIND` | `127.0.0.1` | 管理 UI が bind するアドレス。コンテナー外へ公開するには `0.0.0.0` が必要 |
| `ADMIN_PASSWORD` | （空） | 管理 UI の Basic 認証パスワード（ユーザー名は `admin`）。未設定なら起動ごとにランダム生成してログに出力 |
| `ADMIN_BASE_URL` | `http://localhost:<ADMIN_PORT>` | 承認ページ（`auth_url`）の URL を組み立てる管理 UI の公開 URL。クライアントのブラウザーから開ける値にする |

### ローカル開発 (Gleam 1.17+ / Erlang OTP 27+)

```sh
gleam run   # 実行
gleam test  # テスト（BIP-340 / NIP-44 公式ベクター + バンカーのループバック）
```

Postgres ロガーの統合テストは `TEST_DATABASE_URL` が設定されているときだけ実行される（未設定ならスキップして 1 行ログを出す）:

```sh
docker run -d --name nns-pg-test -p 127.0.0.1:5433:5432 \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=nostr_no_su_test postgres:17-alpine
TEST_DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5433/nostr_no_su_test gleam test
docker rm -f nns-pg-test
```

## 構成

```
src/nostr_no_su.gleam                         -- エントリポイント（設定の読み込みとツリー仕様の組み立て）
src/nostr_no_su/app.gleam                     -- スーパービジョンツリーの構成
src/nostr_no_su/admin.gleam                   -- 管理 UI の HTTP サーバー（wisp / mist）とルーティング
src/nostr_no_su/admin/dashboard.gleam         -- ダッシュボードの描画（スナップショット → HTML の純粋関数）
src/nostr_no_su/config.gleam                  -- 環境変数からの設定読み込み
src/nostr_no_su/dedup.gleam                   -- リレー横断のイベント重複排除
src/nostr_no_su/named.gleam                   -- 名前付きアクターへの安全な送信・問い合わせ
src/nostr_no_su/random.gleam                  -- 推測されては困る値のための乱数
src/nostr_no_su/time.gleam                    -- 現在時刻 (FFI)
src/nostr_no_su/crypto/secp256k1.gleam        -- 点演算・鍵導出・ECDH
src/nostr_no_su/crypto/bip340.gleam           -- BIP-340 Schnorr 署名 / 検証
src/nostr_no_su/crypto/nip44.gleam            -- NIP-44 v2 暗号化
src/nostr_no_su/nostr/event.gleam             -- Event 型・コーデック・ID 計算・署名
src/nostr_no_su/nostr/filter.gleam            -- 購読フィルター
src/nostr_no_su/nostr/message.gleam           -- クライアント⇄リレーのメッセージ
src/nostr_no_su/relay_client.gleam            -- WebSocket クライアント (stratus)
src/nostr_no_su/relay_connection.gleam        -- リレー 1 本ぶんの接続を保つ actor（切断検知と再接続）
src/nostr_no_su/bunker.gleam                  -- バンカーの actor（セッション状態を保持）
src/nostr_no_su/bunker/engine.gleam           -- NIP-46 リクエスト処理の純粋コア
src/nostr_no_su/bunker/rpc.gleam              -- JSON-RPC コーデック
src/nostr_no_su/bunker/account.gleam          -- 鍵材料と bunker:// URI
src/nostr_no_su/plugin.gleam                  -- プラグイン機構
src/nostr_no_su/plugins/console_logger.gleam  -- コンソールロガープラグイン
src/nostr_no_su/plugins/postgres_logger.gleam -- Postgres ロガープラグイン（保存 actor + スキーマ）
src/nostr_no_su_ffi.erl                       -- OTP crypto への FFI
vendor/stratus/                               -- パッチ済み stratus（下記参照）
```

## 設計上の判断・既知の制約

- **スーパービジョンツリー**: root（one_for_one）の下に監視・バンカー・イベント保存のサブツリーを置き、各サブツリーは rest_for_one。先頭の actor（重複排除ディスパッチャー / バンカー actor）が再起動すると後続のリレー接続も再起動し、購読と publisher の再設定が自然に行われる。actor は名前付きプロセスなので、リレー接続は名前宛てに送信すれば再起動後のプロセスにそのまま届く
- **リレー接続 actor は exit を trap する**: stratus のプロセスは接続 actor にリンクされる。切断のたびに actor ごと落とすと supervisor の再起動回数を消費してしまうため、exit を trap してメッセージとして受け取り、5 秒後の再接続をスケジュールする。gleam_otp の actor ループは trap した exit を未知のメッセージとして捨てるので、supervisor からの shutdown は接続 actor 側で検出し、trap を解除して同じ理由で exit し直す（リンク経由でソケットも一緒に終了する）
- **バンカーは専用接続（リレーごと）**: 監視と接続を分けることで、NIP-46 以外の購読を拒否するリレー（relay.nsec.app 等）をバンカー用に使える。応答はどのリレーから来たリクエストでも全バンカーリレーへ発行する。クライアントは URI の `relay=` を全部聴くので、リレーが 1 つ生きていれば往復が成立する
- **イベント保存は独立したサブツリー**: pog の接続プールと保存 actor は監視サブツリーとは別の子として root（one_for_one）にぶら下げる。DB が落ちて再起動が起きてもリレーの購読を巻き込まないため。DB に到達できない間は保存を止めて破棄した件数を数え、復帰時にまとめて報告する（挿入のたびに接続を待つと actor がブロックしてメールボックスが伸びるため）。接続の復旧は pog のプールに任せる
- **管理 UI は root 直下の独立した子**: mist（HTTP サーバー）は監視・バンカー・保存のどれにも依存しないため、root（one_for_one）に並べる。表示する状態はハンドラーが直接触らず、Context に注入された関数から名前付き actor へ問い合わせて取る。問い合わせが失敗しても（再起動中、タイムアウト）ページ全体を失敗させず、その項目だけ「未接続」「該当なし」として描画する。描画は「状態のスナップショット → HTML 文字列」の純粋関数で、テンプレートエンジンも JS フレームワークも使わない
- **管理 UI は既定でループバックのみ**: ダッシュボードには secret 入りの `bunker://` URI が載るため、既定 (`ADMIN_BIND=127.0.0.1`) では LAN に露出しない。Docker はホストの iptables を直接操作するので、ポートを公開したうえでファイアウォールに頼る形は避け、compose 側でホストのループバックにだけ公開している
- **監視の重複排除は世代式スライディングウィンドウ**: 複数リレーが同じイベントを配送するため、直近のイベント id（上限 4096〜8192 件）を覚えてプラグインには 1 回だけ渡す。再接続時のストアドイベント再配送もこれで吸収する
- **サイナー鍵 = ユーザー鍵**: 仕様で許可されている。別鍵にすると再起動で URI が無効化されるため v0 では同一にしている
- **secret は再利用可**: 仕様は single-use だが、セッションがインメモリのため再起動でオンボーディングが壊れないよう、正しい secret を知るクライアントの接続を許可する
- **接続の承認は auth_url フロー**: secret の一致しない `connect` は、管理 UI が有効なら承認待ちにして `auth_url` 応答（`result` が `"auth_url"`、`error` が承認ページの URL）を返し、承認された時点で元のリクエストと同じ id で本来の応答を送る。判断も応答イベントの組み立ても純粋なエンジンに置き、承認トークンの乱数と現在時刻は actor が注入する。管理 UI が無効なら承認する手段が無いので、従来どおり `invalid secret` で拒否する
- **セッションと承認待ちはインメモリ**: 再起動するとクライアントは再 `connect` が必要（secret 再利用可なので実害は小）。承認待ちも同じく永続化せず、10 分で失効する。承認済みのクライアントは secret 無しで `connect` し直しても承認を求められないが、再起動後は改めて承認が要る
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
- [x] Postgres へイベントを保存するロガープラグイン
- [x] 管理 UI（Gleam / wisp）
