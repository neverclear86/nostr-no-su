<p align="right"><a href="README.md">English</a> | 日本語</p>

<p align="center">
  <img alt="Nostr-no-Su" src="assets/logo/nostr-no-su-plate.svg" width="96">
</p>

<h1 align="center">Nostr-no-Su</h1>

<p align="center">
  Nostr の秘密鍵をクライアントごとに渡さず、自分のサーバーでまとめて管理。接続の承認も、自分の投稿の収集も、ひとつの「巣」で。
</p>

<p align="center">
  Nostr-no-Su - <em>Nostr の巣</em> - は、複数アカウントに対応した NIP-46 のリモート署名バンカー兼、自分のイベントを処理するユーティリティサーバー。Gleam / BEAM 製。
</p>

<p align="center">
  <a href="https://github.com/neverclear86/nostr-no-su/actions/workflows/ci.yml"><img alt="CI" src="https://img.shields.io/github/actions/workflow/status/neverclear86/nostr-no-su/ci.yml?branch=main&label=CI&logo=githubactions&logoColor=white&style=for-the-badge"></a>
  <img alt="Coverage" src="https://img.shields.io/badge/coverage-94%25-brightgreen?style=for-the-badge">
  <a href="https://github.com/neverclear86/nostr-no-su/releases"><img alt="Release" src="https://img.shields.io/github/v/tag/neverclear86/nostr-no-su?label=release&sort=semver&style=for-the-badge"></a>
  <a href="https://github.com/neverclear86/nostr-no-su/pkgs/container/nostr-no-su"><img alt="Container image" src="https://img.shields.io/badge/ghcr.io-nostr--no--su-2496ED?logo=docker&logoColor=white&style=for-the-badge"></a>
  <img alt="Gleam 1.17" src="https://img.shields.io/badge/Gleam-1.17-ffaff3?logo=gleam&logoColor=black&style=for-the-badge">
  <img alt="OTP 29" src="https://img.shields.io/badge/Erlang%2FOTP-29-A90533?logo=erlang&logoColor=white&style=for-the-badge">
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue?style=for-the-badge"></a>
</p>

> [!WARNING]
> **まだ v0（0.x）で、版を上げると破壊的変更が入りうる。** 0.x の間は minor の版上げに、環境変数、compose、DB のスキーマ、プラグイン API の非互換を含めうる（[貢献の手引き](CONTRIBUTING.md) の「版数」）。更新の前に [変更履歴](CHANGELOG.md) を読み、DB のダンプを取る。戻す移行は無い（[運用](docs/operations.md) の「バックアップ」「更新」）。
>
> - **秘密鍵は Nostr-no-Su の外にも控える**：登録する nsec は、パスワードマネージャーなど別の場所にも保管。DB かマスターキーのどちらかを失うと、Nostr-no-Su からは取り出せない。生成した鍵も登録の前に控える。登録済みの鍵は管理 UI の「秘密鍵を表示」で確認できる
> - **プラグインの開発は本体の版への追随が前提**：[プラグイン API v1](docs/plugin-api.md) の版が合わないプラグインは読み込まれない。本体と共有する依存（`gleam_stdlib` など）は本体の版が使われるので、Dockerfile と同じ Gleam / OTP でビルドし、`plugin_required_versions/0` と `plugin_min_host_version/0` で版を宣言する。プラグインは本体と同じ VM と権限で動き、秘密鍵を持つプロセスにも到達できる

![管理 UI のダッシュボード](docs/images/usage/dashboard-ja.png)
*アカウント、接続の承認、リレーをまとめて管理する画面。*

## ✨ 特徴

- 🔐 **NIP-46 バンカー**：複数アカウントの鍵を 1 台で管理。複数リレー対応
- 🛂 **接続の承認と権限の管理**：クライアントごとに接続を承認し、署名できる kind と NIP-44 の暗号化を管理 UI で編集
- 🗝️ **鍵は暗号化して保存**：AES-256-GCM + マスターキー。Postgres に保存
- 📡 **イベントの収集とプラグイン処理**：自分のイベントを複数リレーから集め、検証と重複排除をしてプラグインへ。同梱の `event_logger` は Postgres に保存し、管理 UI のタイムラインで確認できる。同梱の `profile` は、アカウントのプロフィール（kind 0）を管理 UI で編集して発行する。自作は BEAM のモジュールを置くだけ
- 🖥️ **管理 UI**：アカウント、接続の承認、セッション、リレー、プラグインを 1 画面で。日英、ライト / ダーク、外部のスクリプト・CSS・フォントなし
- 🔁 **障害からの自動復帰**：OTP のスーパービジョンツリー。リレーは個別に再接続、DB が落ちても再試行
- 🔏 **暗号は自前実装、公式テストベクターで検証**：BIP-340 / NIP-44 v2。NIF 不要。前提と既知の制約は [設計上の判断と既知の制約](docs/design-decisions.md) の「v0.1 のセキュリティの前提」

## 🚀 インストール

必要なもの: docker（compose v2）、`curl`、`openssl`。イメージは `linux/amd64` と `linux/arm64`。

公開イメージから（1 行で）:

```sh
curl -fsSL https://raw.githubusercontent.com/neverclear86/nostr-no-su/main/install.sh | bash
```

作るディレクトリーの名前を聞かれる（空のまま Enter で `nostr-no-su`）。[`install.sh`](install.sh) は最新の Release の版を調べ、その版のタグから次のブロックと同じ 3 つのファイルを取り、`setup-env.sh` と `.env` への追記までを行う。`docker compose` は実行しないので、最後に表示される `cd <ディレクトリー> && docker compose up -d` を実行する。名前を聞かずに進めるなら、末尾を `| bash -s -- <ディレクトリー>` にする。

同じことを手で行うなら:

```sh
mkdir nostr-no-su && cd nostr-no-su
version=X.Y.Z   # Releases から
base=https://raw.githubusercontent.com/neverclear86/nostr-no-su/v$version
curl -fsSLO "$base/docker-compose.release.yml"
curl -fsSLO "$base/.env.example"
curl -fsSLO "$base/setup-env.sh"
mkdir -p plugins
sh setup-env.sh
printf 'COMPOSE_FILE=docker-compose.release.yml\nNOSTR_NO_SU_VERSION=%s\n' "$version" >> .env
docker compose up -d
```

`NOSTR_NO_SU_VERSION` がイメージを取った版に固定する。`.env` に `COMPOSE_FILE` があるので、このディレクトリーでは文書の `docker compose ...` が `-f` 無しで動く。patch も追うなら、`.env` の `NOSTR_NO_SU_VERSION` を `X.Y` に書き換える。版の上げ方は [運用](docs/operations.md) の「更新」。

ソースから:

```sh
git clone https://github.com/neverclear86/nostr-no-su.git && cd nostr-no-su
sh setup-env.sh
docker compose up --build -d
```

`http://127.0.0.1:24133/` を開く。ユーザー名は `admin`、パスワードは `.env` の `ADMIN_PASSWORD`。
最初の流れは、リレーとアカウントを登録 → 接続 URI をクライアントに貼る、の 2 段階（他人の端末に渡すときだけ承認が挟まる）。詳しい手順は [使い方](docs/usage.md) にある。

VPS や自宅サーバーなどリモートのホストで動かすときは、管理 UI はそのホストのループバックにだけ公開されるので、`ssh -L 24133:127.0.0.1:24133 <ホスト>` でポートを転送してから手元のブラウザーで `http://127.0.0.1:24133/` を開く。受信用にポートを開ける必要は無い（バンカーと監視はリレーへの外向きの WebSocket だけで動く）。secret 無しの接続 URI を別の端末のクライアントに渡すときは、その端末のブラウザーから管理 UI の承認ページに到達できる必要があるため、TLS のリバースプロキシーを前に置いて `ADMIN_BASE_URL` に公開 URL を設定する（[設定](docs/configuration.md) の「リバースプロキシーの設定」）。メモリとディスクの目安は [運用](docs/operations.md) の「リソース」にある。

## ⚙️ 設定

設定は `.env` の環境変数。必須はマスターキーと管理パスワードだけで、`setup-env.sh` が生成する（新しく作る `.env` には同梱 Postgres のパスワードも生成した値が入る）。

| 変数 | 既定 | 用途 |
| --- | --- | --- |
| `ADMIN_PORT` | `24133` | 管理 UI をホストのループバックに公開するポート。空なら既定 |
| `ADMIN_BASE_URL` | `http://localhost:<ADMIN_PORT>` | 承認ページの URL の土台。リバースプロキシーの公開 URL |
| `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | `nostr` / `nostr` / `nostr_no_su` | 同梱 Postgres の資格情報。効くのは初回起動だけ。`setup-env.sh` が作る `.env` ではパスワードは生成した値 |

全部の変数、秘密をファイルで渡す方法、リバースプロキシーは [設定](docs/configuration.md)。

## 🔐 安全に使うために

- **マスターキーを失うと鍵が戻らない**：`ACCOUNT_MASTER_KEY` はバックアップと別の場所に。DB のダンプと揃うと全鍵が漏れる
- **管理 UI は平文 HTTP**：既定はループバックだけに公開。外に出すなら TLS を終端するリバースプロキシーを前に
- **プラグインは本体と同じ権限**：サンドボックスなし。信頼できるものだけ置く
- **`REMSH_ENABLED` は使うときだけ**：exec できる者が復号済みの鍵に到達できる

前提と、あえて対策していない項目は [設計上の判断と既知の制約](docs/design-decisions.md) の「v0.1 のセキュリティの前提」。
脆弱性の報告は公開の issue ではなく [SECURITY.md](SECURITY.md) の窓口から。

## 📚 文書

- [使い方](docs/usage.md)：リレーとアカウントの登録、クライアントの接続と承認、権限、event_logger、profile
- [設定](docs/configuration.md)：環境変数の表、`.env`、秘密をファイルで渡す、リバースプロキシー、docker compose の構成
- [運用](docs/operations.md)：起動時のログ、バックアップ、版の更新、復旧、マスターキーの保管と交換、リソースの目安
- [管理 UI](docs/admin-ui.md)：画面の構成、アカウントの操作と結果、接続の承認（auth_url フロー）
- [プラグイン API v1](docs/plugin-api.md)：自作プラグインの仕様。例は [`examples/plugins/`](examples/plugins/)、同梱のプラグインは [`plugins-src/`](plugins-src/)
- [設計上の判断と既知の制約](docs/design-decisions.md)：本体の形を決めた判断とその理由、残っている制約
- [システム構成](docs/architecture.md)：プロセス、イベントとリクエストの経路、ディレクトリ構造、設定の読み手
- [開発](docs/development.md)：ローカルでの実行とテスト、テストの流儀、管理 UI の CSS のビルドと画面の撮影
- [貢献の手引き](CONTRIBUTING.md)：変更の出し方、版数の方針、リリースの手順
- [変更履歴](CHANGELOG.md)：リリースごとの変更

## ライセンス

[MIT License](LICENSE)。
`vendor/stratus/` は Apache License 2.0 の stratus の改変版（帰属は [NOTICE](NOTICE)、改変は [vendor/stratus/PATCH.md](vendor/stratus/PATCH.md)）。
管理 UI のアイコンは ISC ライセンスの [Lucide](https://lucide.dev) のストロークを写したもの（帰属は [NOTICE](NOTICE)）。ロゴはこのリポジトリのもので MIT License に従う。ただし、管理 UI のロゴの製品名は SIL Open Font License 1.1 の [M PLUS 2](https://github.com/coz-m/MPLUS_FONTS) の字形から描いたもの（帰属は [NOTICE](NOTICE)）。
