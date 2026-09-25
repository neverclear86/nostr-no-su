<p align="right">English | <a href="README.ja.md">日本語</a></p>

<p align="center">
  <img alt="Nostr-no-Su" src="assets/logo/nostr-no-su-plate.svg" width="96">
</p>

<h1 align="center">Nostr-no-Su</h1>

<p align="center">
  Keep your Nostr private keys off every client and manage them from one server you run. Approving connections and collecting your own posts, all in one nest.
</p>

<p align="center">
  Nostr-no-Su - <em>"Nostr's nest" in Japanese</em> - is a NIP-46 remote signing bunker for multiple accounts, plus a utility server that processes your own events. Written in Gleam, running on the BEAM.
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
> **Still at v0 (0.x): upgrades may contain breaking changes.** While at 0.x, a minor version bump may include incompatible changes to environment variables, compose, the DB schema or the plugin API (the 「版数」 section of [Contributing](CONTRIBUTING.md)). Read the [Changelog](CHANGELOG.md) and take a DB dump before upgrading. There are no down migrations (the 「バックアップ」 and 「更新」 sections of [Operations](docs/operations.md)).
>
> - **Keep a copy of your private keys outside Nostr-no-Su**: store every nsec you register somewhere else too, such as a password manager. Losing either the DB or the master key means Nostr-no-Su can no longer give them back. Write down a generated key before registering it. A registered key can be viewed with "Show private key" in the admin UI
> - **Plugin development means keeping up with the app's version**: plugins whose [Plugin API v1](docs/plugin-api.md) version does not match are not loaded. Dependencies shared with the app (such as `gleam_stdlib`) run at the app's version, so build with the same Gleam / OTP as the Dockerfile and declare versions with `plugin_required_versions/0` and `plugin_min_host_version/0`. Plugins run in the same VM with the same privileges as the app and can reach the processes that hold the private keys

![The dashboard of the admin UI](docs/images/usage/dashboard-en.png)
*Accounts, connection approvals and relays, managed from one screen.*

## ✨ Features

- 🔐 **NIP-46 bunker**: keys of multiple accounts in one instance. Multiple relays
- 🛂 **Connection approval and permissions**: approve each client's connection, and edit which kinds it may sign and whether it may use NIP-44 in the admin UI
- 🗝️ **Keys stored encrypted**: AES-256-GCM with a master key, in Postgres
- 📡 **Event collection and plugins**: your own events from multiple relays, verified and deduplicated, then handed to plugins. The bundled `event_logger` stores them in Postgres, viewable as a timeline in the admin UI. The bundled `profile` edits your accounts' profiles (kind 0) in the admin UI and publishes them. Add your own by placing a BEAM module
- 🖥️ **Admin UI**: accounts, connection approval, sessions, relays and plugins on one screen. Japanese / English, light / dark, no external scripts, CSS or fonts
- 🔁 **Automatic recovery from failures**: OTP supervision tree. Relays reconnect individually, the bunker retries while the DB is down
- 🔏 **Own crypto implementation, checked against the official test vectors**: BIP-340 / NIP-44 v2. No NIFs. Assumptions and known limitations are in the 「v0.1 のセキュリティの前提」 section of [Design decisions and known limitations](docs/design-decisions.md)

## 🚀 Installation

Requirements: docker (compose v2), `curl`, `openssl`. The image ships `linux/amd64` and `linux/arm64`.

From the published image, in one line:

```sh
curl -fsSL https://raw.githubusercontent.com/neverclear86/nostr-no-su/main/install.sh | bash
```

It asks for the name of the directory to create (press Enter for `nostr-no-su`). [`install.sh`](install.sh) looks up the latest release, downloads the same three files as the block below from that release's tag, runs `setup-env.sh`, and appends to `.env`. It does not run `docker compose`, so run the `cd <directory> && docker compose up -d` it prints at the end. To skip the question, end the command with `| bash -s -- <directory>` instead.

To do the same by hand:

```sh
mkdir nostr-no-su && cd nostr-no-su
version=X.Y.Z   # from Releases
base=https://raw.githubusercontent.com/neverclear86/nostr-no-su/v$version
curl -fsSLO "$base/docker-compose.release.yml"
curl -fsSLO "$base/.env.example"
curl -fsSLO "$base/setup-env.sh"
mkdir -p plugins
sh setup-env.sh
printf 'COMPOSE_FILE=docker-compose.release.yml\nNOSTR_NO_SU_VERSION=%s\n' "$version" >> .env
docker compose up -d
```

`NOSTR_NO_SU_VERSION` pins the image to that version, and with `COMPOSE_FILE` every `docker compose ...` in the docs runs without `-f` in this directory. To also receive patch releases, change `NOSTR_NO_SU_VERSION` in `.env` to `X.Y`. Upgrading is in the 「更新」 section of [Operations](docs/operations.md) (Japanese).

From source:

```sh
git clone https://github.com/neverclear86/nostr-no-su.git && cd nostr-no-su
sh setup-env.sh
docker compose up --build -d
```

Open `http://127.0.0.1:24133/`. The username is `admin` and the password is `ADMIN_PASSWORD` in `.env`.
First steps: register a relay and an account, then paste the connection URI into a client (approval only comes into play when you hand the URI to someone else). Details are in [Usage](docs/usage.md) (Japanese).

Running on a remote host such as a VPS or a home server? The admin UI is published only on that host's loopback, so forward the port over SSH (`ssh -L 24133:127.0.0.1:24133 <host>`) and open `http://127.0.0.1:24133/` in your local browser. No inbound port needs to be opened: the bunker and the monitor only make outbound WebSocket connections to relays. To hand a connection URI without a secret to a client on another device, the browser on that device must reach the approval page, so put a TLS-terminating reverse proxy in front and set `ADMIN_BASE_URL` to the public URL (the 「リバースプロキシーの設定」 section of [Configuration](docs/configuration.md)). Memory and disk estimates are in the 「リソース」 section of [Operations](docs/operations.md).

## ⚙️ Configuration

Everything is configured by environment variables in `.env`. Only the master key and the admin password are required, and `setup-env.sh` generates them (a newly created `.env` also gets a generated password for the bundled Postgres).

| Variable | Default | Purpose |
| --- | --- | --- |
| `ADMIN_PORT` | `24133` | Host port the admin UI is published on (loopback only). Empty means the default |
| `ADMIN_BASE_URL` | `http://localhost:<ADMIN_PORT>` | Base URL of the approval page. The public URL behind a reverse proxy |
| `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | `nostr` / `nostr` / `nostr_no_su` | Credentials of the bundled Postgres. Only take effect on the first start. `setup-env.sh` puts a generated password in the `.env` it creates |

All variables, passing secrets via files and reverse proxies are in [Configuration](docs/configuration.md).

## 🔐 Security

- **Losing the master key loses the keys**: keep `ACCOUNT_MASTER_KEY` somewhere separate from backups. Together with a DB dump it leaks every key
- **The admin UI is plain HTTP**: published only to loopback by default. Put a TLS-terminating reverse proxy in front before exposing it
- **Plugins run with the app's privileges**: no sandbox. Place only ones you trust
- **`REMSH_ENABLED` only while in use**: anyone who can exec into the container reaches the decrypted keys

The assumptions, and what is deliberately not mitigated, are in the 「v0.1 のセキュリティの前提」 section of [Design decisions and known limitations](docs/design-decisions.md).
To report a vulnerability, use the private reporting channel in [SECURITY.md](SECURITY.md) instead of a public issue.

## 📚 Documentation

The documents below are written in Japanese.

- [Usage](docs/usage.md): registering relays and accounts, connecting and approving clients, permissions, event_logger, profile
- [Configuration](docs/configuration.md): environment variable table, `.env`, passing secrets via files, reverse proxy, docker compose setup
- [Operations](docs/operations.md): startup logs, backups, version upgrades, recovery, storing and rotating the master key, resource usage
- [Admin UI](docs/admin-ui.md): screen layout, account operations and results, connection approval (the auth_url flow)
- [Plugin API v1](docs/plugin-api.md): the spec for writing plugins. Examples are in [`examples/plugins/`](examples/plugins/), and the bundled plugins are in [`plugins-src/`](plugins-src/)
- [Design decisions and known limitations](docs/design-decisions.md): the decisions that shaped the app and their reasons, and the remaining limitations
- [Architecture](docs/architecture.md): processes, the paths of events and requests, directory structure, configuration readers
- [Development](docs/development.md): running and testing locally, testing conventions, building the admin UI's CSS and taking screenshots
- [Contributing](CONTRIBUTING.md): how to submit changes, versioning policy, release procedure
- [Changelog](CHANGELOG.md): changes per release

## License

[MIT License](LICENSE).
`vendor/stratus/` is a modified copy of stratus under the Apache License 2.0 (attribution in [NOTICE](NOTICE), modifications in [vendor/stratus/PATCH.md](vendor/stratus/PATCH.md)).
The icons of the admin UI are traced from [Lucide](https://lucide.dev) strokes under the ISC license (attribution in [NOTICE](NOTICE)). The logo belongs to this repository and follows the MIT License, except that the product name in the admin UI logo is drawn from the glyphs of [M PLUS 2](https://github.com/coz-m/MPLUS_FONTS) under the SIL Open Font License 1.1 (attribution in [NOTICE](NOTICE)).
