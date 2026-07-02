# Nostr-no-Su

Nostr のバンカー兼ユーティリティサーバー（Gleam / BEAM）。

NIP-46 で鍵を管理するバンカーであり、自分のアカウントのイベントを監視してプラグイン形式で様々な処理をするユーティリティサーバー。BEAM の並列処理と安定性を活かして効率的に Nostr のイベントを処理することを目指す。

## 現在の状態 (v0)

リレーへ WebSocket で接続し、設定したアカウントのイベントを購読して、プラグインが処理する最小構成が動作する。

- NIP-01 のイベント / フィルタ / リレーメッセージの JSON コーデック
- イベント ID（正規形の sha256）の検証。ID が一致しないイベントは破棄
- プラグイン機構と、イベント概要を標準出力に書くコンソールロガープラグイン
- 接続が切れたら 5 秒後に自動再接続

## 使い方

### Docker

```sh
docker compose up --build
```

### ローカル (Gleam 1.17+ / Erlang OTP 27+)

```sh
gleam run   # 実行
gleam test  # テスト
```

### 環境変数

| 変数 | デフォルト | 説明 |
| --- | --- | --- |
| `RELAY_URL` | `wss://relay.damus.io` | 接続するリレーの URL |
| `PUBKEYS` | （空） | 監視するアカウントの hex 公開鍵（カンマ区切り）。空の場合は直近のイベントを購読する |

例:

```sh
RELAY_URL=wss://relay.damus.io \
PUBKEYS=3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d \
docker compose up --build
```

## 構成

```
src/nostr_no_su.gleam                        -- エントリポイント + 再接続ループ
src/nostr_no_su/config.gleam                 -- 環境変数からの設定読み込み
src/nostr_no_su/nostr/event.gleam            -- Event 型、JSON コーデック、NIP-01 ID 計算
src/nostr_no_su/nostr/filter.gleam           -- 購読フィルタ
src/nostr_no_su/nostr/message.gleam          -- クライアント⇄リレーのメッセージ
src/nostr_no_su/relay_client.gleam           -- WebSocket クライアント (stratus)
src/nostr_no_su/plugin.gleam                 -- プラグイン機構
src/nostr_no_su/plugins/console_logger.gleam -- コンソールロガープラグイン
vendor/stratus/                              -- パッチ済み stratus（下記参照）
```

### vendor/stratus について

stratus 3.0.0 はハンドシェイクで `permessage-deflate` を必ずオファーするが、依存先の gramps 6.0.1 は分割された圧縮メッセージをフレーム単位で inflate するため、strfry 系リレーが送る複数フレームの圧縮メッセージで zlib の `data_error` によりクラッシュする。回避のため、圧縮のオファーを削除した stratus を vendor している（パッチは 1 行、`vendor/stratus/src/stratus.gleam` 参照）。上流で修正されたら hex 版に戻す。

## ロードマップ

- [ ] BIP-340 (schnorr) 署名の検証・生成 — BEAM で使えるライブラリの調査から
- [ ] NIP-46 バンカー（複数アカウントの鍵管理）
- [ ] Postgres へイベントを保存するロガープラグイン
- [ ] マルチリレー対応とスーパービジョンツリー
- [ ] 管理 UI（Gleam / wisp）
