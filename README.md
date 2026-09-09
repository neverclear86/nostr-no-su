# Nostr-no-Su

Nostr のバンカー兼ユーティリティサーバー（Gleam / BEAM）。

NIP-46 で鍵を管理するバンカーであり、自分のアカウントのイベントを監視してプラグイン形式で様々な処理をするユーティリティサーバー。BEAM の並列処理と安定性を活かして効率的に Nostr のイベントを処理することを目指す。

## 現在の状態

NIP-46 リモート署名バンカーが動作する。クライアント（nsec.app / noStrudel 等）が `bunker://` URI で接続し、暗号化されたリクエスト経由で署名を委任できる。あわせて、設定したアカウントのイベントを監視してプラグインで処理する。

- **NIP-46 バンカー**: kind 24133 のリクエストを検証・復号し、`connect` / `get_public_key` / `sign_event` / `ping` / `nip44_encrypt` / `nip44_decrypt` / `logout` を処理。バンカーは監視とは別の専用接続を複数リレーに張れる（`BUNKER_RELAY_URL` カンマ区切り）。どれか 1 つでも生きていれば署名できる
- **暗号**: BIP-340 Schnorr 署名と NIP-44 v2 暗号化を自前実装（公式テストベクタに一致）。プリミティブは OTP の `crypto`（OpenSSL）を利用し、NIF は不要
- **イベント監視**: 複数リレーへ同時接続（`RELAY_URL` カンマ区切り）。NIP-01 のコーデック、イベント ID の検証、リレー横断の重複排除、プラグイン機構、コンソールロガー
- 接続が切れたリレーは 5 秒後に個別に自動再接続（セッション状態は再接続をまたいで保持）

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

### 監視のみ（バンカー無効）

`ACCOUNT_KEYS` を空にすると v0 と同じ監視のみモードで動く:

```sh
docker compose up --build
```

### 環境変数

| 変数 | デフォルト | 説明 |
| --- | --- | --- |
| `RELAY_URL` | `wss://relay.damus.io` | 監視先リレーの URL（カンマ区切りで複数可）。空にすると監視無効（バンカーのみ） |
| `BUNKER_RELAY_URL` | `RELAY_URL` と同じ | バンカーが購読・応答するリレーの URL（カンマ区切りで複数可）。`RELAY_URL` も空なら `wss://relay.damus.io` |
| `ACCOUNT_KEYS` | （空） | バンカーが署名するアカウントの hex 秘密鍵（カンマ区切り）。空ならバンカー無効 |
| `BUNKER_SECRET` | （空） | 接続 secret。未設定なら起動ごとにランダム生成し、URI をログに出力 |
| `PUBKEYS` | （空） | 監視するアカウントの hex 公開鍵（カンマ区切り）。空なら直近のイベントを購読 |

### ローカル開発 (Gleam 1.17+ / Erlang OTP 27+)

```sh
gleam run   # 実行
gleam test  # テスト（BIP-340 / NIP-44 公式ベクタ + バンカーのループバック）
```

## 構成

```
src/nostr_no_su.gleam                        -- エントリポイント + バンカー起動 + リレーごとの再接続ループ
src/nostr_no_su/config.gleam                 -- 環境変数からの設定読み込み
src/nostr_no_su/dedup.gleam                  -- リレー横断のイベント重複排除
src/nostr_no_su/time.gleam                   -- 現在時刻 (FFI)
src/nostr_no_su/crypto/secp256k1.gleam       -- 点演算・鍵導出・ECDH
src/nostr_no_su/crypto/bip340.gleam          -- BIP-340 Schnorr 署名 / 検証
src/nostr_no_su/crypto/nip44.gleam           -- NIP-44 v2 暗号化
src/nostr_no_su/nostr/event.gleam            -- Event 型・コーデック・ID 計算・署名
src/nostr_no_su/nostr/filter.gleam           -- 購読フィルタ
src/nostr_no_su/nostr/message.gleam          -- クライアント⇄リレーのメッセージ
src/nostr_no_su/relay_client.gleam           -- WebSocket クライアント (stratus)
src/nostr_no_su/bunker.gleam                 -- バンカーの actor（セッション状態を保持）
src/nostr_no_su/bunker/engine.gleam          -- NIP-46 リクエスト処理の純粋コア
src/nostr_no_su/bunker/rpc.gleam             -- JSON-RPC コーデック
src/nostr_no_su/bunker/account.gleam         -- 鍵材料と bunker:// URI
src/nostr_no_su/plugin.gleam                 -- プラグイン機構
src/nostr_no_su/plugins/console_logger.gleam -- コンソールロガープラグイン
src/nostr_no_su_ffi.erl                      -- OTP crypto への FFI
vendor/stratus/                              -- パッチ済み stratus（下記参照）
```

## 設計上の判断・既知の制約

- **バンカーは専用接続（リレーごと）**: 監視と接続を分けることで、NIP-46 以外の購読を拒否するリレー（relay.nsec.app 等）をバンカー用に使える。応答はどのリレーから来たリクエストでも全バンカーリレーへ発行する。クライアントは URI の `relay=` を全部聴くので、リレーが 1 つ生きていれば往復が成立する
- **監視の重複排除は世代式スライディングウィンドウ**: 複数リレーが同じイベントを配送するため、直近のイベント id（上限 4096〜8192 件）を覚えてプラグインには 1 回だけ渡す。再接続時のストアドイベント再配送もこれで吸収する
- **サイナー鍵 = ユーザー鍵**: 仕様で許可されている。別鍵にすると再起動で URI が無効化されるため v0 では同一にしている
- **secret は再利用可**: 仕様は single-use だが、セッションがインメモリのため再起動でオンボーディングが壊れないよう、正しい secret を知るクライアントの接続を許可する
- **セッションはインメモリ**: 再起動するとクライアントは再 `connect` が必要（secret 再利用可なので実害は小）
- **認証の多層防御**: NIP-44 の復号成功が送信者認証になる + 受信リクエストの BIP-340 署名検証 + `created_at` の ±10 分チェック + イベント ID の重複排除
- `auth_url` / `nostrconnect://`（クライアント起点フロー）/ NIP-04 / `switch_relays` は未対応

### vendor/stratus について

stratus 3.0.0 はハンドシェイクで `permessage-deflate` を必ずオファーするが、依存先の gramps 6.0.1 は分割された圧縮メッセージをフレーム単位で inflate するため、strfry 系リレーが送る複数フレームの圧縮メッセージで zlib の `data_error` によりクラッシュする。回避のため、圧縮のオファーを削除した stratus を vendor している（パッチは 1 行、`vendor/stratus/src/stratus.gleam` 参照）。上流で修正されたら hex 版に戻す。

## ロードマップ

- [x] BIP-340 (schnorr) 署名の検証・生成
- [x] NIP-46 バンカー（複数アカウントの鍵管理）
- [x] 監視のマルチリレー対応（リレー横断の重複排除つき）
- [x] バンカーのマルチリレー対応（URI に複数 `relay=`、応答は全リレーへ発行）
- [ ] 管理 UI での接続承認（auth_url フロー）
- [ ] Postgres へイベントを保存するロガープラグイン
- [ ] スーパービジョンツリー
- [ ] 管理 UI（Gleam / wisp）
