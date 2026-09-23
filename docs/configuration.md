# 設定

この文書は、環境変数の一覧と、`.env` の書き方、秘密をファイルで渡す方法、管理 UI の待ち受けと認証、リバースプロキシーの置き方、同梱の docker compose の構成の詳細をまとめる。導入の手順は [README（日本語）](../README.ja.md) の「インストール」、バックアップと更新は [運用](operations.md) にある。

## 環境変数

表のデフォルトは、アプリが未設定のときに使う値である。docker compose で起動するときは `docker-compose.yml` が一部の変数に別の値を渡す（同梱の Postgres の URL、`PLUGIN_DIR=/app/plugins:/plugins` など）。`docker-compose.yml` の `${...}` の既定値は `.env.example` の変数の行と同じで、CI が一致を検査する（`dev/check_env_example.sh`）。`POSTGRES_*` の 3 変数と `REMSH_ENABLED`、`NOSTR_NO_SU_VERSION` は例外で、アプリ自身は読まず、`POSTGRES_*` は docker compose が同梱の Postgres に渡し、`DATABASE_URL` と `PLUGIN_EVENT_LOGGER_DATABASE_URL` の既定値の組み立てにも使う（デフォルトの欄は compose が渡す既定値で、`NOSTR_NO_SU_VERSION` は `docker-compose.release.yml` が渡す）。

| 変数 | デフォルト | 説明 |
| --- | --- | --- |
| `DATABASE_URL` | （空） | バンカーのアカウントを保存する Postgres の URL（`postgres://user:pass@host:5432/db`。`postgresql://` も可）。必須で、空なら起動しない。docker compose では同梱の Postgres を指す（注 1）。`DATABASE_URL_FILE` でファイルから読める（「秘密をファイルで渡す」） |
| `ACCOUNT_MASTER_KEY` | （空） | アカウントの秘密鍵と接続 secret を暗号化するマスターキー（64 文字の 16 進 = 32 バイト、`openssl rand -hex 32`）。必須で、空か不正なら起動しない。自動生成はしない。`ACCOUNT_MASTER_KEY_FILE` でファイルから読める（「秘密をファイルで渡す」） |
| `POSTGRES_USER` | `nostr` | docker compose 専用。同梱の Postgres の接続ユーザー名（アプリ自身は読まない）。効くのは `postgres-data` volume が空の初回だけ（「docker compose の構成」） |
| `POSTGRES_PASSWORD` | `nostr` | docker compose 専用。同梱の Postgres の接続パスワード（アプリ自身は読まない）。効くのは `postgres-data` volume が空の初回だけ（「docker compose の構成」）。`setup-env.sh` が新しく作る `.env` では、既定ではなく生成した 64 文字の 16 進の値が入る（「`.env` と `setup-env.sh`」） |
| `POSTGRES_DB` | `nostr_no_su` | docker compose 専用。同梱の Postgres のデータベース名（アプリ自身は読まない）。効くのは `postgres-data` volume が空の初回だけ（「docker compose の構成」） |
| `PLUGIN_EVENT_LOGGER_DATABASE_URL` | （空） | 外部プラグイン `event_logger` 固有の設定。イベントを保存する Postgres の URL（`postgres://user:pass@host:5432/db`）。docker イメージには同梱されているので、compose の既定の構成では常に読まれる。空にすると設定不足として拒否されてプラグインが読み込まれず、イベントは保存されない（起動のたびに理由が 1 行出る）。保存をやめるときはこの変数を空にせず、`PLUGIN_DIR=/plugins`（自作プラグインだけを読む）か `PLUGIN_DIR=`（全部無効）にして同梱の `event_logger` を読み込ませない。docker compose では同梱の Postgres を指す |
| `PLUGIN_DIR` | （空） | 外部プラグインを探すディレクトリー。`:` 区切りで複数書くと左から順に読み、名前が重なったら先のディレクトリーが勝つ。空なら読み込まない。ここに置いた BEAM は本体と同じ VM で動くため、信頼できるものだけを置くこと（[プラグイン API v1](plugin-api.md) の第 8 章）。docker イメージは `ENV PLUGIN_DIR=/app/plugins` を持つので、compose を使わない `docker run` でも同梱の `event_logger` と `profile` が読まれる |
| `PLUGIN_<NAME>_<KEY>` | （空） | プラグイン固有の設定。`<NAME>` は `plugin_name/0` の値を大文字化し `[A-Z0-9]` 以外を `_` にしたもの。プラグインには `<KEY>` を小文字にした binary キーの map として届く（[プラグイン API v1](plugin-api.md) の第 6 章） |
| `PLUGIN_CONSOLE_LOGGER_ENABLED` | `true` | 内蔵プラグイン `console_logger`（受信したイベントを 1 件 1 行で出す）の有効・無効。`false` で無効にする。`true` / `false` 以外の値は起動しない |
| `REMSH_ENABLED` | `false` | docker イメージ専用（起動スクリプト `/app/start.sh` が読み、アプリ自身は読まない）。`true` でリモートシェルの口を開く（「docker compose の構成」）。未設定か空は `false`、`true` / `false` 以外の値は起動しない |
| `NOSTR_NO_SU_VERSION` | `latest` | `docker-compose.release.yml` 専用（アプリ自身は読まない）。取る公開イメージのタグ。`latest` は版の大小によらず最後に公開したタグに付くので（[貢献の手引き](../CONTRIBUTING.md) の「リリース」）、README の手順が取った版（`X.Y.Z`）を書く。同じ minor の patch も追うなら `X.Y` に書き換える。`docker-compose.yml` は参照しないので `.env.example` にも行が無い |
| `ADMIN_PORT` | `8080` | 管理 UI が待ち受けるポート（1〜65535）。空文字列か空白だけの値なら管理 UI を無効にする。範囲外や数値でない値は理由をログに出して無効にする |
| `ADMIN_BIND` | `127.0.0.1` | 管理 UI が bind するアドレス。コンテナー外へ公開するには `0.0.0.0` が必要。`"localhost"` と IPv4 / IPv6 以外の値は理由をログに出して管理 UI を無効にする |
| `ADMIN_PASSWORD` | （空） | 管理 UI の Basic 認証パスワード（ユーザー名は `admin`）。管理 UI が有効なら必須で、空なら起動しない。自動生成はしない。`ADMIN_PASSWORD_FILE` でファイルから読める（「秘密をファイルで渡す」） |
| `ADMIN_BASE_URL` | `http://localhost:<ADMIN_PORT>` | 承認ページ（`auth_url`）の URL を組み立てる管理 UI の公開 URL。クライアントのブラウザーから開ける値にする |
| `DEDUP_CAPACITY` | `4096` | 監視の重複排除が記憶する直近のイベント id の件数（実際に記憶するのはこの 1〜2 倍）。1 以上の整数。未設定か空なら既定。0 以下や数値でない値は起動しない |

注 1: `DATABASE_URL` の userinfo はパーセントデコードされない。`:` を含むパスワード、ユーザー名の無い URL（`postgres://host:5432/db` のように `user@` を持たないもの）、データベース名の無い URL は解釈できず、`[main] cannot start: DATABASE_URL is not a valid postgres URL` を出して終了する（URL そのものはログに出さない）。

## `.env` と `setup-env.sh`

docker compose では `DATABASE_URL` が同梱の Postgres を指しているので、`.env` に書く必要があるのはマスターキーと管理パスワードだけである。同梱の `setup-env.sh` が、`.env.example` を `.env` に複製してこの 2 つを生成した値で埋め、あわせて同梱の Postgres のパスワード（`POSTGRES_PASSWORD`）も既定の `nostr` から生成した 64 文字の 16 進の値に置き換え、`.env` を 600 にする:

```sh
sh setup-env.sh
docker compose up --build -d   # 公開イメージなら、README の手順で .env に COMPOSE_FILE を書いて docker compose up -d
```

手で作るなら、複製と必須の 2 つの生成を次のように行う（`POSTGRES_PASSWORD` は既定の `nostr` のままになる）:

```sh
[ -e .env ] || cp .env.example .env
chmod 600 .env
# .env の ACCOUNT_MASTER_KEY= の後に、openssl rand -hex 32 の出力を書く
# .env の ADMIN_PASSWORD= の後に、openssl rand -base64 24 の出力を書く
```

すでに `.env` があれば、`setup-env.sh` も手順も複製しない（書いてあるマスターキーを失うと、保存したアカウントの秘密鍵を復号できなくなる）。`setup-env.sh` はその場合、値の入っている行は変えず、必須の 2 つのうち行が無いか空のものだけを埋め、`.env.example` にあって `.env` に無い変数を `.env.example` の行のまま末尾に足す。`POSTGRES_PASSWORD` も新たな生成はしない（`postgres-data` volume は初回の起動時のパスワードで初期化済みで、後から変えると接続が拒否される）。行が無ければ `.env.example` の `# POSTGRES_PASSWORD=nostr` の行が足される。手で作る場合は `.env.example` と見比べて、足りない変数を書き足す。変数の意味は「環境変数」の表にあり、`.env` に書くときの注意と、compose が渡す既定値は `.env.example` にある。`chmod 600 .env` は、複製したかどうかにかかわらず、マスターキーと管理パスワードを書く `.env` をホストのほかのユーザーから読めないようにする。

## 秘密をファイルで渡す

`DATABASE_URL`、`ACCOUNT_MASTER_KEY`、`ADMIN_PASSWORD` は、`<変数>_FILE` に置いたファイルのパスからも読める。両方を空でない値にすると起動しない。末尾の改行は落とす。読めないファイルと空のファイルは `[main] cannot start: <変数>_FILE could not be read (enoent)` などの 1 行を出して終了する。

本体はこの 3 つを読み込んだ後にプロセスの環境から消すので、同じ VM で動くプラグインは `os:getenv/1` で読めない。ただし環境変数で渡した値は `docker inspect` と `/proc/<pid>/environ` に残る。これを避けるにはファイルで渡す。

docker compose の例:

```sh
mkdir -p secrets
openssl rand -hex 32 > secrets/account_master_key
openssl rand -base64 24 > secrets/admin_password
chmod 600 secrets/*
# ホストの uid が 1000 でなければ続けて実行する（コンテナーは uid 1000 で動き、
# compose の secrets: はホストの所有者とモードのまま見える）
sudo chown 1000 secrets/*
# chown の後はホストの利用者が読めないので、ログインに使うパスワードは
# sudo cat secrets/admin_password で確かめる
```

次の `docker-compose.override.yml`（`COMPOSE_FILE` の無い構成では `docker compose up` が自動で重ねる。`.env` に `COMPOSE_FILE` を書いた公開イメージの構成では自動では重ならないので、`COMPOSE_FILE=docker-compose.release.yml:docker-compose.override.yml` と並べる。「docker compose の構成」）を置き、`.env` の `ACCOUNT_MASTER_KEY=` と `ADMIN_PASSWORD=` は空のままにする。

```yaml
services:
  nostr-no-su:
    environment:
      ACCOUNT_MASTER_KEY_FILE: /run/secrets/account_master_key
      ADMIN_PASSWORD_FILE: /run/secrets/admin_password
    secrets:
      - account_master_key
      - admin_password
secrets:
  account_master_key:
    file: ./secrets/account_master_key
  admin_password:
    file: ./secrets/admin_password
```

`DATABASE_URL_FILE` を compose で使うときは、`.env` に `DATABASE_URL=` と空で書く。同梱の compose は `${DATABASE_URL-...}` で、未設定なら同梱の Postgres の URL を渡すので、書かないと両方が設定された扱いで起動しない。

パーミッション: compose の `secrets:` はホストのファイルをそのままマウントするので、swarm でなければ `uid` や `mode` の指定は効かない。`chown` を忘れると `[main] cannot start: ACCOUNT_MASTER_KEY_FILE could not be read (eacces)` で終了する。`secrets/` は `.gitignore` と `.dockerignore` に入っている。

## 管理 UI の待ち受けと認証

起動すると `http://127.0.0.1:8080/` で管理 UI にアクセスできる。ダッシュボードで、承認待ちの接続要求の承認と拒否、アカウントの登録と操作、承認済みのセッションの取り消し、リレーの追加・用途の編集・削除を行い、リレーとプラグインの状態を確かめる。画面の構成、操作ごとの結果と状態コード、接続の承認（auth_url フロー）、CSRF の防ぎ方は [管理 UI](admin-ui.md) にある。

認証は HTTP Basic で、ユーザー名は `admin` 固定。パスワードは `ADMIN_PASSWORD` で指定する（必須）。未設定か空なら `[main] cannot start: ADMIN_PASSWORD is not set (generate one with: openssl rand -base64 24)` を 1 行出して終了コード 1 で終了する。`ADMIN_PORT=` で管理 UI を無効にした構成では要らない。パスワードは自動生成しない。認証に失敗した要求は `[admin] rejected a request with wrong credentials from 127.0.0.1` のように理由と接続元の IP だけを 1 行ログに出す（資格情報なしの `without credentials`、形式が壊れた `with malformed credentials` もある）。IP は TCP の接続元で、`X-Forwarded-For` は見ない。ブラウザーは最初に資格情報なしで要求するので、`without credentials` の行は正規の利用でも出る。認証に失敗した応答は 1 秒待ってから返す（ブラウザーが資格情報を覚える前の最初の要求も 1 秒待つ）。試行の回数の制限とロックアウトは無いので、推測されにくいパスワードを使い、公開範囲をループバックか VPN の内側に絞ること。

`ADMIN_PORT` で待ち受けポートを変更でき、空文字列や空白だけの値（`ADMIN_PORT=` など）にすると管理 UI を無効にできる。`GET /healthz` だけは認証なしで `ok` を返す。イメージにはこれを叩く `HEALTHCHECK` が入っているため、`docker ps` の `STATUS` にコンテナーの状態が出る。`ADMIN_PORT=` か空白だけの値で管理 UI を無効にした構成では待ち受けが無いのでチェック自体を省略し、healthy として扱う。

ページのスタイルとスクリプトは、ビルドした CSS（`/static/admin.css`）と JS（`/static/admin.js`）を管理 UI 自身が配信する。CDN などの外部のファイルは読まないので、外部に到達できない環境でも表示できる。CSS と JS もページと同じく Basic 認証の後にある。

待ち受けアドレスの既定は `127.0.0.1`（ループバックのみ）で、`ADMIN_BIND` で変更する。コンテナーの外へポートを公開するには `ADMIN_BIND=0.0.0.0` が必要になるが、その場合は公開範囲を別途絞ること（同梱の compose はホスト側のループバックにだけ公開する）。

> ⚠️ **平文 HTTP である**: Basic 認証の資格情報は暗号化されずに送られ、ページには署名権限そのものである secret 入りの `bunker://` URI が表示される。localhost か Docker ネットワーク内での利用を前提とし、外部に公開するときは必ずリバースプロキシーで TLS を終端すること。平文 HTTP で LAN の別のホストから開くと、ブラウザーがクリップボードの API を出さないので、コピーのボタンは欄を選択するだけになる。表示される案内に従って Ctrl+C でコピーする。

## リバースプロキシーの設定

前段のリバースプロキシーは、`Host` ヘッダーをブラウザーが送った値のまま（公開ホスト名と、既定以外のポートならそのポートを含めて）管理 UI へ渡すこと。状態を変える POST は `Origin`（無ければ `Referer`）のホストとポートを `Host` と突き合わせて CSRF を防いでおり（`X-Forwarded-Host` は見ない）、`Host` が上流のアドレス（`127.0.0.1:8080` など）に書き換わっているか、既定以外のポートで公開していてポートが落ちていると、承認、登録、削除を含むブラウザーからの POST がすべて 400 の「要求を処理できません」（`Bad request`）のページ（本文は Origin が Host と一致しないという案内、ログには `Origin-host mismatch: <Host> <Origin>`）になる。nginx は既定で `Host` を `proxy_pass` の宛先に書き換え、`$host` はポートを含まないので、`$http_host` を渡す:

```nginx
server {
    listen 443 ssl;
    server_name admin.example;
    # ssl_certificate と ssl_certificate_key は省略

    location / {
        proxy_set_header Host $http_host;
        proxy_pass http://127.0.0.1:8080;
    }
}
```

管理 UI は Basic 認証の失敗を 1 秒遅らせるだけで、試行の回数の制限とロックアウトは持たない。要求の回数の制限や、失敗の回数による遮断が必要なときは、前段のリバースプロキシーで行うこと。管理 UI のログに出る接続元の IP は TCP の接続元なので、プロキシーの背後ではプロキシーのアドレスになる。

承認ページの URL の土台にする公開 URL（上の例なら `https://admin.example`）は、`ADMIN_BASE_URL` に設定する（[管理 UI](admin-ui.md) の「接続の承認（auth_url フロー）」）。

## docker compose の構成

同梱の `docker-compose.yml`（clone してソースからビルドする）と `docker-compose.release.yml`（公開イメージから取る）は、イメージの取り方の 1 行だけが違い（CI が `dev/check_release_compose.sh` で確かめる）、この節の説明は両方に当てはまる。公開イメージの構成では、README の手順が `.env` に `COMPOSE_FILE=docker-compose.release.yml` と `NOSTR_NO_SU_VERSION=<取った版>` を書く。docker compose は `.env` のあるディレクトリーでこの `COMPOSE_FILE` を読むので、起動と停止も `logs` や `exec` も `-f` 無しで動く。`COMPOSE_FILE` を書くと `docker-compose.override.yml` は自動では重ならないので、「秘密をファイルで渡す」の override を使うときは `COMPOSE_FILE=docker-compose.release.yml:docker-compose.override.yml` と `:` で並べる。取るタグは `${NOSTR_NO_SU_VERSION:-latest}` で、`NOSTR_NO_SU_VERSION` の無い `.env` では `latest` を取る。

compose には Postgres（`postgres:17-alpine` をダイジェストで固定したもの）が同梱されており、アプリは healthcheck が通ってから起動する。同じ Postgres を本体（バンカーのアカウント、`DATABASE_URL`）とプラグイン（イベント、`PLUGIN_EVENT_LOGGER_DATABASE_URL`）の両方が使う。データは `postgres-data` volume に永続化され、`docker compose down -v` で消える（**暗号化したアカウントも消える**。バックアップの取り方は [運用](operations.md) にある）。Postgres のポートはホストに公開しない（アプリは compose ネットワーク経由で到達する）ため、保存されたデータは `docker compose exec postgres psql -U nostr -d nostr_no_su` で確認する。リリースで公開するイメージ（`ghcr.io/neverclear86/nostr-no-su`）は `linux/amd64` と `linux/arm64` の両方を含むマルチアーキテクチャのマニフェストで、x86_64 のホストでも、Raspberry Pi や ARM の VPS、Apple Silicon の docker でも同じタグで動く。

管理 UI のポートはホストのループバック（`127.0.0.1:8080`）にだけ公開する。コンテナー内では `ADMIN_BIND=0.0.0.0` を渡して全インターフェースで待ち受けさせ、外部からの到達性はこの公開先で絞っている。`ADMIN_PORT` を変えると公開ポートも追従する。`ADMIN_PORT=` と空にすると管理 UI は無効になるが、公開は `127.0.0.1:8080` のまま残る。

**`PLUGIN_DIR` に置いた BEAM は本体と同じ VM・同じ権限で動く。サンドボックスは無く、秘密鍵を持つプロセスにも到達できる（`sys:get_state/1`）。信頼できるものだけを置くこと。** 第三者から受け取ったプラグインはソースを読んでから置く。

同梱の `event_logger` と `profile` はイメージの `/app/plugins` に入っており、自作のプラグインは `./plugins` に置くと読み込まれる（コンテナー内の `/plugins` に読み取り専用でマウントし、`PLUGIN_DIR=/app/plugins:/plugins` を渡している）。コンテナーは非 root（uid 1000）で動くため、**置いたあとに `chmod -R a+rX plugins` が必要**である。プラグインの置き方は [プラグイン API v1](plugin-api.md) の第 8 章、動作確認用の例は `examples/plugins/file_logger/`（状態を持たない例）と `examples/plugins/counter/`（状態を持つ例）、実プラグインは `plugins-src/event_logger/`（イベントを Postgres へ保存する）と `plugins-src/profile/`（プロフィールを管理 UI に出す）を参照。`PLUGIN_DIR` は `:` 区切りで複数のディレクトリーを並べられ、左から順に読む。`./plugins` に同梱と同じ名前のプラグインを置くと、先に並べた `/app/plugins` の同梱版が勝つので、改造版を試すときは `PLUGIN_DIR=/plugins` を渡して同梱版を外す。`PLUGIN_DIR=` と空にすると読み込みを無効にできる。

プラグイン固有の設定は `PLUGIN_<NAME>_<KEY>` の形の環境変数で渡す（`file_logger` の出力先なら `PLUGIN_FILE_LOGGER_PATH`）。compose の `environment:` は明示的な列挙なので、自分のプラグインの分は `docker-compose.yml`（公開イメージで動かしているなら `docker-compose.release.yml`）に書き足すこと。設定が足りないプラグインは読み込み時に理由を 1 行出して**そのプラグインだけが無効になり**、本体の起動と他のプラグインには影響しない（[プラグイン API v1](plugin-api.md) の第 6 章）。

アプリのコンテナーはルートを読み取り専用（`read_only`）にし、ケーパビリティーを全部落として（`cap_drop: [ALL]`、`no-new-privileges`）動く。書けるのは `/tmp` だけで、メモリ上の tmpfs なのでコンテナーの再起動（クラッシュの後の自動再起動を含む）で消え、書いた分だけメモリを使う。自作のプラグインも `/tmp` 以外には書けない。`file_logger` の既定の出力先（`PLUGIN_FILE_LOGGER_PATH=/tmp/nostr-no-su-events.log`）もここに書かれ、自動再起動で消える。残したいときは、`docker-compose.override.yml` で volume をマウントし（uid 1000 が書けること）、`PLUGIN_FILE_LOGGER_PATH` をその下に上書きする。

**BEAM のクラッシュダンプは既定では書かない（`ERL_CRASH_DUMP_BYTES=0`）。ダンプには管理パスワードと DB のパスワードが base64 の符号化だけで載り、VM が落ちた瞬間に表示のために取り出していた秘密（ダッシュボードの `bunker://` URI の secret、再表示した nsec など）も載る。管理パスワードが漏れると、管理 UI に届く者が全アカウントの nsec を表示できる。** 不具合の調査のためにダンプを残すときは、`docker-compose.override.yml` で volume をマウントし（uid 1000 が書けること）、`ERL_CRASH_DUMP` をその下に上書きし、`ERL_CRASH_DUMP_BYTES: ""` を渡す（空の値は大きさの上限を外す）。残したダンプは不具合の報告に添付せず、置いた volume も共有しないこと。調べ終えたら override から 2 つの変数を消してコンテナーを作り直し、ダンプを消す。

**`REMSH_ENABLED=true` にするとコンテナーに exec できる者が VM の全て（復号した秘密鍵を含む）に到達できる。既定は無効で、使うときだけ有効にして再作成すること。** 入り方は `docker compose exec nostr-no-su /app/start.sh remsh`、式を流すだけなら `printf '式.\n' | docker compose exec -T nostr-no-su /app/start.sh remsh`。抜けるときは `q().` と `init:stop().` は本体を止めてしまうので使わず、Ctrl+G の後に `q` と入力する。`-T` で式を流した場合は入力の終わりで抜ける。ノード名は `nostr_no_su@localhost`、cookie は起動ごとの乱数で `/tmp/nostr-no-su-remsh.cookie`（0600）に置き、`remsh` はこのファイルから読む。epmd と分散ノードはコンテナー内のループバックにだけ bind する。ポートは公開しない。

同梱の Postgres の資格情報は `.env` の `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` で変える（既定は `nostr` / `nostr` / `nostr_no_su`）。`setup-env.sh` が新しく作る `.env` では、`POSTGRES_PASSWORD` には既定ではなく生成した 64 文字の 16 進の値が入る。`DATABASE_URL` と `PLUGIN_EVENT_LOGGER_DATABASE_URL` の既定値はここから組み立てるので、ほかを書き換える必要は無い。効くのは `postgres-data` volume が空の初回だけで、起動した後に変えるとアプリの URL だけが変わって接続が拒否される。パスワードは URL にそのまま入り、アプリは userinfo をパーセントデコードしない（注 1）ので、`@ : / ? # %` などを含めないこと（生成する値が 16 進なのはこのため）。この文書、[運用](operations.md)、`plugins-src/event_logger/README.md` のコマンドの `-U nostr -d nostr_no_su` は既定値なので、変えたときは読み替えること。

ログは 1 行ずつ `<時刻 UTC> <水準> <本文>` の形で出る。本体と同梱プラグインが出す行の水準は notice（通常）、warning（失敗したが動き続ける）、error（続けられずに止まる。起動の中止、`cannot continue`、プラグインの停止）の 3 つで、OTP のクラッシュレポートも error の行として同じ形で出る。本文中の引用はこの先頭を省いて書いている。docker のログは `json-file` の 10 MB × 3 世代で打ち切られ、`docker compose logs` で見えるのはその範囲だけである。

## 対応クライアントと相互運用

kind 24133 のペイロードは **NIP-44** で暗号化する（現行仕様）。NIP-04 のみの古いクライアントは非対応（受信するとログに記録して無視）。ephemeral イベントなので、レート制限のあるリレーだと転送されないことがある（例: `relay.damus.io` は連続リクエストで応答イベントを rate-limit で拒否することがある）。バンカーに使うリレーには `wss://relay.nsec.app` などバンカー向けリレーを推奨。

バンカーの接続（クライアントの署名要求を受ける接続）は、リレーが NIP-42 の AUTH を要求すると、登録アカウントごとに署名した kind 22242 で応答する（監視の接続は応答せずログに出すだけ）。リレーが challenge を送るたびに、その時点で読み込み済みのアカウントで応答する（バンカー側からアカウントの変化を契機に再認証を始める経路は無い）。最初の読み込みが失敗していれば 0 件で応答し、その後の読み込みの成功や接続確立後のアカウントの追加は、リレーが再び challenge を送るか再接続するまでその接続の認証に反映されない。認証必須のリレーを選ぶ場合はこの制約を踏まえること。

バンカーは監視とは別に専用の接続をリレーごとに張り、NIP-46 の購読だけを開く。`relay.nsec.app` のような NIP-46 専用リレー（kind 24133 以外の購読を拒否する）もバンカー用にはそのまま使える。複数登録すると `bunker://` URI に `relay=` が複数入り、どれか 1 つでも生きていれば署名の往復が成立する（応答は全バンカーリレーへ発行し、`rate-limited:` を返したリレーへのセッションの外の応答だけをしばらく止める。リクエストの重複受信はエンジンが排除）。リレーは `relays` テーブルの行（URL、監視用かどうか、バンカー用かどうか）で決まり、環境変数では設定しない。登録の手順は [使い方](usage.md) の「1. リレーを登録する」と [管理 UI](admin-ui.md) の「リレーの追加」にある。
