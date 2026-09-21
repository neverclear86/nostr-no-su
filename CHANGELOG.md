# 変更履歴

形式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) 1.1.0 に従う。版の付け方と書き方の決まりは [CONTRIBUTING.md](CONTRIBUTING.md) の「版数」「変更履歴」を参照。

## [Unreleased]

## [0.1.0] - 2026-09-22

最初のリリース。0.1.0 より前の変更は記録していない。

### 追加

- NIP-46 リモート署名バンカー。`connect` / `get_public_key` / `sign_event` / `ping` / `nip44_encrypt` / `nip44_decrypt` / `logout` に応え、複数アカウントの鍵を預かり、複数のリレーに専用の接続を張る。secret を持たないクライアントは管理 UI の承認（`auth_url` フロー）を経て接続し、署名と暗号化は `connect` で宣言した権限（perms）の範囲だけを許す
- BIP-340 Schnorr 署名と NIP-44 v2 暗号化の自前実装（公式のテストベクターに一致）
- 登録アカウントのイベント監視（複数リレー、ID と署名の検証、リレー横断の重複排除、保存した再開点からの購読）とプラグイン機構（プラグイン API v1、`PLUGIN_DIR` からの読み込み、専用プロセスによる障害隔離）
- 同梱プラグイン `event_logger`（受信したイベントを Postgres の `events` テーブルへ保存）と内蔵プラグイン `console_logger`
- 管理 UI（サーバー側描画、日本語と英語、ライトとダーク）。アカウントの登録・削除・secret の再生成・ラベルの編集・秘密鍵の再表示、接続の承認と拒否、セッションの取り消し、リレーの追加・用途の編集・削除、プラグインの状態と再有効化
- アカウント（秘密鍵と接続 secret は `ACCOUNT_MASTER_KEY` で AES-256-GCM により暗号化）、リレー、セッション、承認待ち、再開点の Postgres への保存と、版つきの前向きの移行
- docker compose（Postgres 同梱、読み取り専用のルート、非 root、healthcheck）、公開イメージ `ghcr.io/neverclear86/nostr-no-su`（`linux/amd64` と `linux/arm64`）、公開イメージから起動する `docker-compose.release.yml`、`.env` を用意する `setup-env.sh`
- 文書: 設定、運用（バックアップ、更新、復旧、マスターキーの交換）、管理 UI、プラグイン API v1、設計上の判断と既知の制約、システム構成、開発、貢献の手引き

[Unreleased]: https://github.com/neverclear86/nostr-no-su/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/neverclear86/nostr-no-su/releases/tag/v0.1.0
