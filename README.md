<p align="right">English | <a href="README.ja.md">日本語</a></p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo/nostr-no-su-color-dark.svg">
    <img alt="Nostr-no-Su" src="assets/logo/nostr-no-su-color.svg" width="96">
  </picture>
</p>

<h1 align="center">Nostr-no-Su</h1>

<p align="center">
  A NIP-46 remote signing bunker for Nostr, plus a utility server that processes your own events. Written in Gleam, running on the BEAM.
</p>

<p align="center">
  <a href="https://github.com/neverclear86/nostr-no-su/actions/workflows/ci.yml"><img alt="CI" src="https://img.shields.io/github/actions/workflow/status/neverclear86/nostr-no-su/ci.yml?branch=main&label=CI&logo=githubactions&logoColor=white&style=for-the-badge"></a>
  <img alt="Coverage" src="https://img.shields.io/badge/coverage-92%25-brightgreen?style=for-the-badge">
  <a href="https://github.com/neverclear86/nostr-no-su/releases"><img alt="Release" src="https://img.shields.io/github/v/tag/neverclear86/nostr-no-su?label=release&sort=semver&style=for-the-badge"></a>
  <a href="https://github.com/neverclear86/nostr-no-su/pkgs/container/nostr-no-su"><img alt="Container image" src="https://img.shields.io/badge/ghcr.io-nostr--no--su-2496ED?logo=docker&logoColor=white&style=for-the-badge"></a>
  <img alt="Gleam 1.17" src="https://img.shields.io/badge/Gleam-1.17-ffaff3?logo=gleam&logoColor=black&style=for-the-badge">
  <img alt="OTP 29" src="https://img.shields.io/badge/Erlang%2FOTP-29-A90533?logo=erlang&logoColor=white&style=for-the-badge">
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue?style=for-the-badge"></a>
</p>

The server answers signing requests from clients connected over a `bunker://` URI (nsec.app, noStrudel, etc.) without ever handing them your private key. It also watches relays for events from your registered accounts and processes them with plugins (the bundled `event_logger` stores them in Postgres). It comes up together with Postgres via docker compose, and you operate keys and relays from the admin UI.

Nostr-no-Su - means "Nostr's nest" in Japanese - answers signing requests from clients connected over `bunker://` (nsec.app, noStrudel, etc.) without ever handing them your private key.
It also collects events of your registered accounts from relays and processes them with plugins.
It comes up together with Postgres via docker compose, and keys and relays are managed in the admin UI.

![The dashboard of the admin UI](docs/images/usage/dashboard-en.png)

## ✨ Features

- **NIP-46 bunker**: keys of multiple accounts in one instance. Multiple relays, approval flow (auth_url)
- **Keys stored encrypted**: AES-256-GCM with a master key, in Postgres
- **Permission management**: per client, which kinds it may sign and whether it may use NIP-44, editable in the admin UI
- **Own crypto implementation**: BIP-340 / NIP-44 v2. No NIFs
- **Event monitoring and plugins**: your own events from multiple relays, verified and deduplicated, then handed to plugins. Add one by placing a BEAM module
- **Admin UI**: accounts, connection approval, sessions, relays and plugins on one screen. Japanese / English, light / dark, no external files
- **Keeps running**: OTP supervision tree. Relays reconnect individually, the bunker retries while the DB is down

## 🚀 Getting started

Requirements: docker (compose v2), `curl`, `openssl`. The image ships `linux/amd64` and `linux/arm64`.

From the published image:

```sh
mkdir nostr-no-su && cd nostr-no-su
base=https://raw.githubusercontent.com/neverclear86/nostr-no-su/v<version>   # X.Y.Z from Releases
curl -fsSLO "$base/docker-compose.release.yml"
curl -fsSLO "$base/.env.example"
curl -fsSLO "$base/setup-env.sh"
mkdir -p plugins
sh setup-env.sh
docker compose -f docker-compose.release.yml up -d
```

From source:

```sh
git clone https://github.com/neverclear86/nostr-no-su.git && cd nostr-no-su
sh setup-env.sh
docker compose up --build -d
```

Open `http://127.0.0.1:8080/`. The username is `admin` and the password is `ADMIN_PASSWORD` in `.env`.
Registering relays and accounts and connecting a client are in [Usage](docs/usage.md) (Japanese).

## ⚙️ Configuration

Everything is configured by environment variables in `.env`. Only the master key and the admin password are required, and `setup-env.sh` generates them.

| Variable | Default | Purpose |
| --- | --- | --- |
| `ADMIN_PORT` | `8080` | Port of the admin UI. Empty disables it |
| `ADMIN_BASE_URL` | `http://localhost:<ADMIN_PORT>` | Base URL of the approval page. The public URL behind a reverse proxy |
| `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | `nostr` / `nostr` / `nostr_no_su` | Credentials of the bundled Postgres. Only take effect on the first start |

All variables, passing secrets via files and reverse proxies are in [Configuration](docs/configuration.md).

## 🔐 Security

- **Losing the master key loses the keys**: keep `ACCOUNT_MASTER_KEY` somewhere separate from backups. Together with a DB dump it leaks every key
- **The admin UI is plain HTTP**: published only to loopback by default. Put a TLS-terminating reverse proxy in front before exposing it
- **Plugins run with the app's privileges**: no sandbox. Place only ones you trust
- **`REMSH_ENABLED` only while in use**: anyone who can exec into the container reaches the decrypted keys

The assumptions, and what is deliberately not mitigated, are in the 「v0.1 のセキュリティの前提」 section of [Design decisions and known limitations](docs/design-decisions.md).

## 📚 Documentation

The documents below are written in Japanese.

- [Usage](docs/usage.md): registering relays and accounts, connecting and approving clients, permissions, event_logger
- [Configuration](docs/configuration.md): environment variable table, `.env`, passing secrets via files, reverse proxy, docker compose setup
- [Operations](docs/operations.md): startup logs, backups, version upgrades, recovery, storing and rotating the master key
- [Admin UI](docs/admin-ui.md): screen layout, account operations and results, connection approval (the auth_url flow)
- [Plugin API v1](docs/plugin-api.md): the spec for writing plugins. Examples are in [`examples/plugins/`](examples/plugins/), and the bundled event_logger is in [`plugins-src/event_logger/`](plugins-src/event_logger/README.md)
- [Design decisions and known limitations](docs/design-decisions.md): the decisions that shaped the app and their reasons, and the remaining limitations
- [Architecture](docs/architecture.md): processes, the paths of events and requests, directory structure, configuration readers
- [Development](docs/development.md): running and testing locally, testing conventions, building the admin UI's CSS and taking screenshots
- [Contributing](CONTRIBUTING.md): how to submit changes, versioning policy, release procedure
- [Changelog](CHANGELOG.md): changes per release

## License

[MIT License](LICENSE).
`vendor/stratus/` is a modified copy of stratus under the Apache License 2.0 (attribution in [NOTICE](NOTICE), modifications in [vendor/stratus/PATCH.md](vendor/stratus/PATCH.md)).
The icons of the admin UI are traced from [Lucide](https://lucide.dev) strokes under the ISC license (attribution in [NOTICE](NOTICE)). The logo belongs to this repository and follows the MIT License.
