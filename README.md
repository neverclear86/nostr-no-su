# Nostr-no-Su

Nostr のバンカー兼ユーティリティサーバー（Gleam / BEAM）。

NIP-46 で鍵を管理するバンカーであり、自分のアカウントのイベントを監視してプラグイン形式で様々な処理をするユーティリティサーバー。BEAM の並列処理と安定性を活かして効率的に Nostr のイベントを処理することを目指す。

## 現在の状態

NIP-46 リモート署名バンカーが動作する。クライアント（nsec.app / noStrudel 等）が `bunker://` URI で接続し、暗号化されたリクエスト経由で署名を委任できる。あわせて、バンカーに登録したアカウントのイベントを監視してプラグインで処理する。

- **NIP-46 バンカー**: kind 24133 のリクエストを検証・復号し、`connect` / `get_public_key` / `sign_event` / `ping` / `nip44_encrypt` / `nip44_decrypt` / `logout` を処理。バンカーは監視とは別の専用接続を複数リレーに張れる（`BUNKER_RELAY_URL` カンマ区切り）。どれか 1 つでも生きていれば署名できる。secret を持たないクライアントは `auth_url` フローで管理 UI の承認を経て接続する。アカウントの秘密鍵と接続 secret は、マスターキー（`ACCOUNT_MASTER_KEY`）で AES-256-GCM により暗号化して Postgres に保存する
- **暗号**: BIP-340 Schnorr 署名と NIP-44 v2 暗号化を自前実装（公式テストベクターに一致）。プリミティブは OTP の `crypto`（OpenSSL）を利用し、NIF は不要
- **イベント監視**: 複数リレーへ同時接続（`RELAY_URL` カンマ区切り）。監視するのはバンカーに登録した全アカウントが作ったイベントで、管理 UI でのアカウントの追加と削除は再起動なしで購読に反映する。ephemeral イベント（kind 20000〜29999。バンカーの NIP-46 の通信を含む）はプラグインに渡さない。登録アカウント以外のイベントを受け取るプラグインは想定しない。NIP-01 のコーデック、イベントの ID と署名の検証（リレーの接続ごとのプロセスで行う）、リレー横断の重複排除、プラグイン機構（[プラグイン API v1](docs/plugin-api.md)）、プラグインの障害隔離、コンソールロガー、`PLUGIN_DIR` からの外部プラグイン読み込み
- 接続が切れたリレーは個別に自動再接続（セッション状態は再接続をまたいで保持。基準の間隔は 5 秒から倍に延び 5 分で頭打ちで、実際の間隔はそれを ±20% ずらす）
- **イベントロガー**: 外部プラグイン `event_logger` を `PLUGIN_DIR` に置き、`PLUGIN_EVENT_LOGGER_DATABASE_URL` を設定すると、監視で受信したイベントを `events` テーブルへ保存する（NIP-01 の全フィールド + `tags` は jsonb + 取り込み時刻）。同じイベントを複数のリレーから受け取っても 1 行だけ残る。ソースとビルド手順は `plugins-src/event_logger/`
- **管理 UI**: `http://127.0.0.1:8080/` でアカウントとその `bunker://` 接続 URI、リレーの接続状態、承認待ちの接続要求（承認・拒否）、承認済みセッション（取り消し可）、有効なプラグインとその状態（無効なら再有効化可）を確認できる。アカウントの登録（nsec の入力とサーバー側での鍵の生成）、削除、接続 secret のローテーション、ラベルの編集、管理パスワードの再入力による秘密鍵の再表示もここで行う。HTTP Basic 認証（ユーザー名 `admin`）で、既定はループバックのみで待ち受ける
- **スーパービジョンツリー**: 全プロセスを `static_supervisor` の下で管理。バンカー actor や重複排除ディスパッチャーが落ちても再起動し、後続のリレー接続も張り直されて配線が復旧する

## 使い方

### バンカーとして使う

アカウント（秘密鍵と接続 secret）は Postgres に暗号化して保存する。起動には、保存先の `DATABASE_URL`、暗号化に使うマスターキー `ACCOUNT_MASTER_KEY`、管理 UI（次節）のパスワード `ADMIN_PASSWORD` の 3 つが必要である。マスターキーは 32 バイトの乱数を 16 進にしたもので、次のように作る:

```sh
openssl rand -hex 32
```

```sh
DATABASE_URL=postgres://nostr:nostr@127.0.0.1:5432/nostr_no_su \
ACCOUNT_MASTER_KEY=<openssl rand -hex 32 の出力> \
ADMIN_PASSWORD=<openssl rand -base64 24 の出力> \
BUNKER_RELAY_URL=wss://relay.nsec.app,wss://relay.nostr.band \
gleam run
```

docker compose では `DATABASE_URL` が同梱の Postgres を指しているので、`.env` に書く必要があるのはマスターキーと管理パスワードだけである:

```sh
[ -e .env ] || cp .env.example .env
chmod 600 .env
# .env の ACCOUNT_MASTER_KEY= の後に、上の openssl rand -hex 32 の出力を書く
# .env の ADMIN_PASSWORD= の後に、openssl rand -base64 24 の出力を書く
docker compose up --build
```

すでに `.env` があれば複製しない（書いてあるマスターキーを失うと、保存したアカウントの秘密鍵を復号できなくなる）。その場合は `.env.example` と見比べて、足りない変数を書き足す。変数の意味は「環境変数」の表にあり、`.env` に書くときの注意と、compose が渡す既定値は `.env.example` にある。`chmod 600 .env` は、複製したかどうかにかかわらず、マスターキーと管理パスワードを書く `.env` をホストのほかのユーザーから読めないようにする。

起動するとバンカーはテーブル `bunker_accounts` を作り（すでにあれば何もしない）、保存されたアカウントを読み込んで `[bunker] loaded N account(s)` を出す。起動ログには秘密鍵も `bunker://` URI も出さない。

アカウントは管理 UI（次節）から登録する。

1. ダッシュボードのアカウントの節の「アカウントを追加」（`Add account`）を開き、nsec を貼り付けて「登録する」（`Register`）を押すか、「生成する」（`Generate`）でサーバーに鍵を作らせる。
2. nsec を貼り付けた場合は、完了ページに出る nsec を確かめる。生成した場合は、確認ページの nsec をバックアップしてから「この鍵を登録する」（`Register this key`）を押す（登録するとダッシュボードに戻り、nsec は再び表示されない）。どちらも、以後は管理パスワードを再入力したときにしか表示しない。
3. ダッシュボードの「接続 URI」（`Connection URI`）をコピーしてクライアントに貼り付ける。secret を持たない「接続 URI（要承認）」（`Connection URI (approval)`）で接続すると、管理 UI での承認を経る。

登録したアカウントには再起動なしで接続できる。secret も暗号化して保存するので、再起動しても接続 URI は変わらない。

いずれかが未設定か不正なら、`[main] cannot start: <理由>` を 1 行出して終了コード 1 で終了する（同梱の compose は `restart: unless-stopped` なので、docker が間隔を延ばしながら再起動を繰り返し、そのたびに同じ行が出る）。`RELAY_URL` か `BUNKER_RELAY_URL` の URL が不正（スキームの無いものなど）なときも、`[main] cannot start: RELAY_URL has an invalid relay url: <url> (use ws:// or wss://)` のように起動時に止まる。DB に記録されたスキーマの版がビルドより新しいときは、`[main] cannot continue: database schema version N is newer than this build supports (up to version M)` を 1 行出して終了コード 1 で終了する（[設計上の判断と既知の制約](docs/design-decisions.md) の「スキーマの版は前向きにだけ自動で進める」）。同じ DB を別のインスタンスが使っているときは、`[main] cannot continue: another instance is using this database (advisory lock 7237235 is held by another session)` を 1 行出して終了コード 1 で終了する（[設計上の判断と既知の制約](docs/design-decisions.md) の「同じ DB に対して動けるのは 1 インスタンスだけである」）。DB に到達できないときはバンカーのサブツリーは起動したまま、`[bunker] account store unavailable: database is unreachable or rejected the connection; retrying in 5000ms` を 1 行出して読み込みを再試行し（間隔は失敗のたびに倍に延び、2 分で頭打ちになる）、戻れば `account store is back; loaded N account(s)` を出す。この間も監視とプラグインは止まらない。パスワードやデータベース名の誤りも接続の段階で拒否されるので同じ行になり、理由が変わらない限り 2 行目は出ない。DB が読み込みの期限までに応答しないか、途中で接続が切れたときは、理由が `database did not answer in time or the connection was lost` の行になる。この行が出たままなら、DB の停止だけでなく `DATABASE_URL` の資格情報とデータベース名も確かめること。

登録で `account is already registered` と出るのにダッシュボードにそのアカウントが無いときは、起動時の読み込みで飛ばされた行（ログの `[bunker] skipped account <pubkey>: <理由>`）が `bunker_accounts` に残っている。別のマスターキーで暗号化された行は、そのマスターキーでなければ復号できない。その鍵を使わないと決めたときだけ、行を DB から直接消してから登録し直す（docker compose では `docker compose exec postgres psql -U nostr -d nostr_no_su -c "DELETE FROM bunker_accounts WHERE pubkey = '<pubkey>'"`）。

バンカーは監視とは別に専用の接続をリレーごとに張り、NIP-46 の購読だけを開く。`relay.nsec.app` のような NIP-46 専用リレー（kind 24133 以外の購読を拒否する）もバンカー用にはそのまま使える。複数指定すると `bunker://` URI に `relay=` が複数入り、どれか 1 つでも生きていれば署名の往復が成立する（応答は全バンカーリレーへ発行、リクエストの重複受信はエンジンが排除）。`BUNKER_RELAY_URL` を省略すると `RELAY_URL` と同じリレーを使う（`RELAY_URL` も空なら `wss://relay.damus.io`）。

> ⚠️ **マスターキーの扱い**: マスターキーを失うと、保存した全アカウントの秘密鍵を復号できなくなる（DB だけでは戻せない）。逆に、DB のダンプとマスターキーが揃うと全アカウントの秘密鍵が漏れる。マスターキーはバックアップと同じ場所に置かず、バージョン管理に含めない `.env` などで渡すこと。環境変数で渡した値はホスト上で `docker inspect` や `/proc/<pid>/environ` から読めるので、ファイルで渡すか（後述の「秘密をファイルで渡す」）、ホストの権限を絞ること。取り方と戻し方は [バックアップと復旧](docs/operations.md) にある。

> ⚠️ **アカウントの削除と秘密鍵の表示**: 削除するとバンカーからも DB からも鍵が消え、DB 以外に保存していない鍵は戻らない。秘密鍵を表示すると、ログに `[admin] revealed the private key of <npub>` が残る。管理パスワードの再入力が違うときは `[admin] rejected a private key reveal for <npub>: incorrect password` が残る。コピーした nsec や接続 URI はクリップボードに残るので、貼り付けた後は消すこと。

#### 秘密をファイルで渡す

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

次の `docker-compose.override.yml`（`docker compose up` が自動で重ねる）を置き、`.env` の `ACCOUNT_MASTER_KEY=` と `ADMIN_PASSWORD=` は空のままにする。

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

パーミッション: compose の `secrets:` はホストのファイルをそのままマウントするので、swarm でなければ `uid` や `mode` の指定は効かない。`chown` を忘れると `[main] cannot start: ACCOUNT_MASTER_KEY_FILE could not be read (eacces)` で終了する。`secrets/` は `.gitignore` に入っている。

#### 対応クライアントと相互運用

kind 24133 のペイロードは **NIP-44** で暗号化する（現行仕様）。NIP-04 のみの古いクライアントは非対応（受信するとログに記録して無視）。ephemeral イベントなので、AUTH やレート制限のあるリレーだと転送されないことがある（例: `relay.damus.io` は連続リクエストで応答イベントを rate-limit で拒否することがある）。`BUNKER_RELAY_URL` には `wss://relay.nsec.app` などバンカー向けリレーを推奨。

### 管理 UI

起動すると `http://127.0.0.1:8080/` で管理 UI にアクセスできる。ダッシュボードで、承認待ちの接続要求の承認と拒否、アカウントの登録と操作、承認済みのセッションの取り消しを行い、リレーとプラグインの状態を確かめる。画面の構成、操作ごとの結果と状態コード、接続の承認（auth_url フロー）、CSRF の防ぎ方は [管理 UI](docs/admin-ui.md) にある。

認証は HTTP Basic で、ユーザー名は `admin` 固定。パスワードは `ADMIN_PASSWORD` で指定する（必須）。未設定か空なら `[main] cannot start: ADMIN_PASSWORD is not set (generate one with: openssl rand -base64 24)` を 1 行出して終了コード 1 で終了する。`ADMIN_PORT=` で管理 UI を無効にした構成では要らない。パスワードは自動生成しない。認証に失敗した要求は `[admin] rejected a request with wrong credentials` のように理由だけを 1 行ログに出す（資格情報なしの `without credentials`、形式が壊れた `with malformed credentials` もある）。ブラウザーは最初に資格情報なしで要求するので、`without credentials` の行は正規の利用でも出る。試行の回数の制限や遅延は無いので、推測されにくいパスワードを使い、公開範囲をループバックか VPN の内側に絞ること。

`ADMIN_PORT` で待ち受けポートを変更でき、空文字列や空白だけの値（`ADMIN_PORT=` など）にすると管理 UI を無効にできる。`GET /healthz` だけは認証なしで `ok` を返す。イメージにはこれを叩く `HEALTHCHECK` が入っているため、`docker ps` の `STATUS` にコンテナーの状態が出る。`ADMIN_PORT=` か空白だけの値で管理 UI を無効にした構成では待ち受けが無いのでチェック自体を省略し、healthy として扱う。

ページのスタイルとスクリプトは、ビルドした CSS（`/static/admin.css`）と JS（`/static/admin.js`）を管理 UI 自身が配信する。CDN などの外部のファイルは読まないので、外部に到達できない環境でも表示できる。CSS と JS もページと同じく Basic 認証の後にある。

待ち受けアドレスの既定は `127.0.0.1`（ループバックのみ）で、`ADMIN_BIND` で変更する。コンテナーの外へポートを公開するには `ADMIN_BIND=0.0.0.0` が必要になるが、その場合は公開範囲を別途絞ること（同梱の compose はホスト側のループバックにだけ公開する）。

> ⚠️ **平文 HTTP である**: Basic 認証の資格情報は暗号化されずに送られ、ページには署名権限そのものである secret 入りの `bunker://` URI が表示される。localhost か Docker ネットワーク内での利用を前提とし、外部に公開するときは必ずリバースプロキシーで TLS を終端すること。平文 HTTP で LAN の別のホストから開くと、ブラウザーがクリップボードの API を出さないので、コピーのボタンは欄を選択するだけになる。表示される案内に従って Ctrl+C でコピーする。

#### リバースプロキシーの設定

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

承認ページの URL の土台にする公開 URL（上の例なら `https://admin.example`）は、`ADMIN_BASE_URL` に設定する（[管理 UI](docs/admin-ui.md) の「接続の承認（auth_url フロー）」）。

### docker compose

compose には Postgres（`postgres:17-alpine` をダイジェストで固定したもの）が同梱されており、アプリは healthcheck が通ってから起動する。同じ Postgres を本体（バンカーのアカウント、`DATABASE_URL`）とプラグイン（イベント、`PLUGIN_EVENT_LOGGER_DATABASE_URL`）の両方が使う。データは `postgres-data` volume に永続化され、`docker compose down -v` で消える（**暗号化したアカウントも消える**。バックアップの取り方は [バックアップと復旧](docs/operations.md) にある）。Postgres のポートはホストに公開しない（アプリは compose ネットワーク経由で到達する）ため、保存されたデータは `docker compose exec postgres psql -U nostr -d nostr_no_su` で確認する。

管理 UI のポートはホストのループバック（`127.0.0.1:8080`）にだけ公開する。コンテナー内では `ADMIN_BIND=0.0.0.0` を渡して全インターフェースで待ち受けさせ、外部からの到達性はこの公開先で絞っている。`ADMIN_PORT` を変えると公開ポートも追従する。`ADMIN_PORT=` と空にすると管理 UI は無効になるが、公開は `127.0.0.1:8080` のまま残る。

**`PLUGIN_DIR` に置いた BEAM は本体と同じ VM・同じ権限で動く。サンドボックスは無く、秘密鍵を持つプロセスにも到達できる（`sys:get_state/1`）。信頼できるものだけを置くこと。** 第三者から受け取ったプラグインはソースを読んでから置く。

外部プラグインは `./plugins` に置くと読み込まれる（コンテナー内の `/plugins` に読み取り専用でマウントし、`PLUGIN_DIR=/plugins` を渡している）。コンテナーは非 root（uid 1000）で動くため、**置いたあとに `chmod -R a+rX plugins` が必要**である。プラグインの置き方は [プラグイン API v1](docs/plugin-api.md) の第 8 章、動作確認用の例は `examples/plugins/file_logger/`（状態を持たない例）と `examples/plugins/counter/`（状態を持つ例）、実プラグインは `plugins-src/event_logger/`（イベントを Postgres へ保存する）を参照。`PLUGIN_DIR=` と空にすると読み込みを無効にできる。

プラグイン固有の設定は `PLUGIN_<NAME>_<KEY>` の形の環境変数で渡す（`file_logger` の出力先なら `PLUGIN_FILE_LOGGER_PATH`）。compose の `environment:` は明示的な列挙なので、自分のプラグインの分は `docker-compose.yml` に書き足すこと。設定が足りないプラグインは読み込み時に理由を 1 行出して**そのプラグインだけが無効になり**、本体の起動と他のプラグインには影響しない（[プラグイン API v1](docs/plugin-api.md) の第 6 章）。

アプリのコンテナーはルートを読み取り専用（`read_only`）にし、ケーパビリティーを全部落として（`cap_drop: [ALL]`、`no-new-privileges`）動く。書けるのは `/tmp` だけで、メモリ上の tmpfs なのでコンテナーの再起動（クラッシュの後の自動再起動を含む）で消え、書いた分だけメモリを使う。自作のプラグインも `/tmp` 以外には書けない。`file_logger` の既定の出力先（`PLUGIN_FILE_LOGGER_PATH=/tmp/nostr-no-su-events.log`）と BEAM のクラッシュダンプ（`ERL_CRASH_DUMP=/tmp/erl_crash.dump`）もここに書かれるので、クラッシュダンプは既定では自動再起動で消える。どちらも残したいときは、`docker-compose.override.yml` で volume をマウントし（uid 1000 が書けること）、`PLUGIN_FILE_LOGGER_PATH` と `ERL_CRASH_DUMP` をその下に上書きする。

**`REMSH_ENABLED=true` にするとコンテナーに exec できる者が VM の全て（復号した秘密鍵を含む）に到達できる。既定は無効で、使うときだけ有効にして再作成すること。** 入り方は `docker compose exec nostr-no-su /app/start.sh remsh`、式を流すだけなら `printf '式.\n' | docker compose exec -T nostr-no-su /app/start.sh remsh`。抜けるときは `q().` と `init:stop().` は本体を止めてしまうので使わず、Ctrl+G の後に `q` と入力する。`-T` で式を流した場合は入力の終わりで抜ける。ノード名は `nostr_no_su@localhost`、cookie は起動ごとの乱数で `/tmp/nostr-no-su-remsh.cookie`（0600）にだけ置き、epmd と分散ノードはコンテナー内のループバックにだけ bind する。ポートは公開しない。

同梱の Postgres の資格情報は `.env` の `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` で変える（既定は `nostr` / `nostr` / `nostr_no_su`）。`DATABASE_URL` と `PLUGIN_EVENT_LOGGER_DATABASE_URL` の既定値はここから組み立てるので、ほかを書き換える必要は無い。効くのは `postgres-data` volume が空の初回だけで、起動した後に変えるとアプリの URL だけが変わって接続が拒否される。パスワードは URL にそのまま入り、アプリは userinfo をパーセントデコードしない（注 1）ので、`@ : / ? # %` などを含めないこと。この文書、[バックアップと復旧](docs/operations.md)、`plugins-src/event_logger/README.md` のコマンドの `-U nostr -d nostr_no_su` は既定値なので、変えたときは読み替えること。

ログは 1 行ずつ `<時刻 UTC> <水準> <本文>` の形で出る。本体と同梱プラグインが出す行の水準は notice（通常）、warning（失敗したが動き続ける）、error（続けられずに止まる。起動の中止、`cannot continue`、プラグインの停止）の 3 つで、OTP のクラッシュレポートも error の行として同じ形で出る。本文中の引用はこの先頭を省いて書いている。docker のログは `json-file` の 10 MB × 3 世代で打ち切られ、`docker compose logs` で見えるのはその範囲だけである。

### 環境変数

表のデフォルトは、アプリが未設定のときに使う値である。docker compose で起動するときは `docker-compose.yml` が一部の変数に別の値を渡す（同梱の Postgres の URL、`PLUGIN_DIR=/plugins` など）。`docker-compose.yml` の `${...}` の既定値は `.env.example` の変数の行と同じで、CI が一致を検査する（`dev/check_env_example.sh`）。`POSTGRES_*` の 3 変数と `REMSH_ENABLED` は例外で、アプリ自身は読まず、`POSTGRES_*` は docker compose が同梱の Postgres に渡し、`DATABASE_URL` と `PLUGIN_EVENT_LOGGER_DATABASE_URL` の既定値の組み立てにも使う（デフォルトの欄は `docker-compose.yml` が渡す既定値）。

| 変数 | デフォルト | 説明 |
| --- | --- | --- |
| `RELAY_URL` | `wss://relay.damus.io` | 監視先リレーの URL（カンマ区切りで複数可）。空にすると監視無効（バンカーのみ） |
| `BUNKER_RELAY_URL` | `RELAY_URL` と同じ | バンカーが購読・応答するリレーの URL（カンマ区切りで複数可）。`RELAY_URL` も空なら `wss://relay.damus.io` |
| `DATABASE_URL` | （空） | バンカーのアカウントを保存する Postgres の URL（`postgres://user:pass@host:5432/db`。`postgresql://` も可）。必須で、空なら起動しない。docker compose では同梱の Postgres を指す（注 1）。`DATABASE_URL_FILE` でファイルから読める（「秘密をファイルで渡す」） |
| `ACCOUNT_MASTER_KEY` | （空） | アカウントの秘密鍵と接続 secret を暗号化するマスターキー（64 文字の 16 進 = 32 バイト、`openssl rand -hex 32`）。必須で、空か不正なら起動しない。自動生成はしない。`ACCOUNT_MASTER_KEY_FILE` でファイルから読める（「秘密をファイルで渡す」） |
| `POSTGRES_USER` | `nostr` | docker compose 専用。同梱の Postgres の接続ユーザー名（アプリ自身は読まない）。効くのは `postgres-data` volume が空の初回だけ（「docker compose」の節） |
| `POSTGRES_PASSWORD` | `nostr` | docker compose 専用。同梱の Postgres の接続パスワード（アプリ自身は読まない）。効くのは `postgres-data` volume が空の初回だけ（「docker compose」の節） |
| `POSTGRES_DB` | `nostr_no_su` | docker compose 専用。同梱の Postgres のデータベース名（アプリ自身は読まない）。効くのは `postgres-data` volume が空の初回だけ（「docker compose」の節） |
| `PLUGIN_EVENT_LOGGER_DATABASE_URL` | （空） | 外部プラグイン `event_logger` 固有の設定。イベントを保存する Postgres の URL（`postgres://user:pass@host:5432/db`）。プラグインを置いていなければ誰も読まない。空にすると設定不足として拒否されてプラグインが読み込まれず、イベントは保存されない（起動のたびに理由が 1 行出る）。保存をやめるときは空にせず、プラグインを置かない。docker compose では同梱の Postgres を指す |
| `PLUGIN_DIR` | （空） | 外部プラグインを探すディレクトリー。空なら読み込まない。ここに置いた BEAM は本体と同じ VM で動くため、信頼できるものだけを置くこと（[プラグイン API v1](docs/plugin-api.md) の第 8 章） |
| `PLUGIN_<NAME>_<KEY>` | （空） | プラグイン固有の設定。`<NAME>` は `plugin_name/0` の値を大文字化し `[A-Z0-9]` 以外を `_` にしたもの。プラグインには `<KEY>` を小文字にした binary キーの map として届く（[プラグイン API v1](docs/plugin-api.md) の第 6 章） |
| `PLUGIN_CONSOLE_LOGGER_ENABLED` | `true` | 内蔵プラグイン `console_logger`（受信したイベントを 1 件 1 行で出す）の有効・無効。`false` で無効にする。`true` / `false` 以外の値は起動しない |
| `REMSH_ENABLED` | `false` | docker イメージ専用（起動スクリプト `/app/start.sh` が読み、アプリ自身は読まない）。`true` でリモートシェルの口を開く（「docker compose」の節）。未設定か空は `false`、`true` / `false` 以外の値は起動しない |
| `ADMIN_PORT` | `8080` | 管理 UI が待ち受けるポート（1〜65535）。空文字列か空白だけの値なら管理 UI を無効にする。範囲外や数値でない値は理由をログに出して無効にする |
| `ADMIN_BIND` | `127.0.0.1` | 管理 UI が bind するアドレス。コンテナー外へ公開するには `0.0.0.0` が必要 |
| `ADMIN_PASSWORD` | （空） | 管理 UI の Basic 認証パスワード（ユーザー名は `admin`）。管理 UI が有効なら必須で、空なら起動しない。自動生成はしない。`ADMIN_PASSWORD_FILE` でファイルから読める（「秘密をファイルで渡す」） |
| `ADMIN_BASE_URL` | `http://localhost:<ADMIN_PORT>` | 承認ページ（`auth_url`）の URL を組み立てる管理 UI の公開 URL。クライアントのブラウザーから開ける値にする |

注 1: `DATABASE_URL` の userinfo はパーセントデコードされない。`:` を含むパスワード、ユーザー名の無い URL（`postgres://host:5432/db` のように `user@` を持たないもの）、データベース名の無い URL は解釈できず、`[main] cannot start: DATABASE_URL is not a valid postgres URL` を出して終了する（URL そのものはログに出さない）。

## 文書

- [管理 UI](docs/admin-ui.md)：画面の構成、アカウントの操作と結果、接続の承認（auth_url フロー）
- [設計上の判断と既知の制約](docs/design-decisions.md)：本体の形を決めた判断とその理由、残っている制約
- [システム構成](docs/architecture.md)：プロセス、イベントとリクエストの経路、ディレクトリ構造、設定の読み手
- [バックアップと復旧](docs/operations.md)：DB のダンプと復元、マスターキーの保管、復旧後の確認
- [開発](docs/development.md)：ローカルでの実行とテスト、管理 UI の CSS のビルドと画面の撮影
- [プラグイン API v1](docs/plugin-api.md)：プラグインを書くための仕様
- [貢献の手引き](CONTRIBUTING.md)：変更の出し方、版数の方針、リリースの手順
- [変更履歴](CHANGELOG.md)：リリースごとの変更


## ロードマップ

- [x] BIP-340 (schnorr) 署名の検証・生成
- [x] NIP-46 バンカー（複数アカウントの鍵管理）
- [x] 監視のマルチリレー対応（リレー横断の重複排除つき）
- [x] バンカーのマルチリレー対応（URI に複数 `relay=`、応答は全リレーへ発行）
- [x] スーパービジョンツリー
- [x] 管理 UI での接続承認（auth_url フロー）
- [x] イベントロガープラグイン（Postgres へ保存）
- [x] 管理 UI（Gleam / wisp）

## ライセンス

このリポジトリのライセンスは [MIT License](LICENSE) である。
`vendor/stratus/` は Apache License 2.0 の stratus を改変したもので、帰属は [NOTICE](NOTICE)、改変の記録は [vendor/stratus/PATCH.md](vendor/stratus/PATCH.md) にある。
