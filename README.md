# Nostr-no-Su

Nostr のバンカー兼ユーティリティサーバー（Gleam / BEAM）。

NIP-46 で鍵を管理するバンカーであり、自分のアカウントのイベントを監視してプラグイン形式で様々な処理をするユーティリティサーバー。BEAM の並列処理と安定性を活かして効率的に Nostr のイベントを処理することを目指す。

## 現在の状態

NIP-46 リモート署名バンカーが動作する。クライアント（nsec.app / noStrudel 等）が `bunker://` URI で接続し、暗号化されたリクエスト経由で署名を委任できる。あわせて、設定したアカウントのイベントを監視してプラグインで処理する。

- **NIP-46 バンカー**: kind 24133 のリクエストを検証・復号し、`connect` / `get_public_key` / `sign_event` / `ping` / `nip44_encrypt` / `nip44_decrypt` / `logout` を処理。バンカーは監視とは別の専用接続を複数リレーに張れる（`BUNKER_RELAY_URL` カンマ区切り）。どれか 1 つでも生きていれば署名できる。secret を持たないクライアントは `auth_url` フローで管理 UI の承認を経て接続する。アカウントの秘密鍵と接続 secret は、マスターキー（`ACCOUNT_MASTER_KEY`）で AES-256-GCM により暗号化して Postgres に保存する
- **暗号**: BIP-340 Schnorr 署名と NIP-44 v2 暗号化を自前実装（公式テストベクターに一致）。プリミティブは OTP の `crypto`（OpenSSL）を利用し、NIF は不要
- **イベント監視**: 複数リレーへ同時接続（`RELAY_URL` カンマ区切り）。NIP-01 のコーデック、イベントの ID と署名の検証（リレーの接続ごとのプロセスで行う）、リレー横断の重複排除、プラグイン機構（[プラグイン API v1](docs/plugin-api.md)）、プラグインの障害隔離、コンソールロガー、`PLUGIN_DIR` からの外部プラグイン読み込み
- 接続が切れたリレーは 5 秒後に個別に自動再接続（セッション状態は再接続をまたいで保持）
- **イベントロガー**: 外部プラグイン `event_logger` を `PLUGIN_DIR` に置き、`PLUGIN_EVENT_LOGGER_DATABASE_URL` を設定すると、監視で受信したイベントを `events` テーブルへ保存する（NIP-01 の全フィールド + `tags` は jsonb + 取り込み時刻）。同じイベントを複数のリレーから受け取っても 1 行だけ残る。ソースとビルド手順は `plugins-src/event_logger/`
- **管理 UI**: `http://127.0.0.1:8080/` でアカウントとその `bunker://` 接続 URI、リレーの接続状態、承認待ちの接続要求（承認・拒否）、承認済みセッション（取り消し可）、有効なプラグインとその状態を確認できる。アカウントの登録（nsec の入力とサーバー側での鍵の生成）、削除、接続 secret のローテーション、ラベルの編集、管理パスワードの再入力による秘密鍵の再表示もここで行う。HTTP Basic 認証（ユーザー名 `admin`）で、既定はループバックのみで待ち受ける
- **スーパービジョンツリー**: 全プロセスを `static_supervisor` の下で管理。バンカー actor や重複排除ディスパッチャーが落ちても再起動し、後続のリレー接続も張り直されて配線が復旧する

## 使い方

### バンカーとして使う

アカウント（秘密鍵と接続 secret）は Postgres に暗号化して保存する。バンカーを有効にするには、保存先の `DATABASE_URL` と、暗号化に使うマスターキー `ACCOUNT_MASTER_KEY` の 2 つを設定する。マスターキーは 32 バイトの乱数を 16 進にしたもので、次のように作る:

```sh
openssl rand -hex 32
```

```sh
DATABASE_URL=postgres://nostr:nostr@127.0.0.1:5432/nostr_no_su \
ACCOUNT_MASTER_KEY=<openssl rand -hex 32 の出力> \
BUNKER_RELAY_URL=wss://relay.nsec.app,wss://relay.nostr.band \
gleam run
```

docker compose では `DATABASE_URL` が同梱の Postgres を指しているので、`.env` に書く必要があるのはマスターキーだけである:

```sh
[ -e .env ] || cp .env.example .env
chmod 600 .env
# .env の ACCOUNT_MASTER_KEY= の後に、上の openssl rand -hex 32 の出力を書く
docker compose up --build
```

すでに `.env` があれば複製しない（書いてあるマスターキーを失うと、保存したアカウントの秘密鍵を復号できなくなる）。その場合は `.env.example` と見比べて、足りない変数を書き足す。ほかの変数の既定値と書き方は `.env.example` のコメントにある。`chmod 600 .env` は、複製したかどうかにかかわらず、マスターキーを書く `.env` をホストのほかのユーザーから読めないようにする。

起動するとバンカーはテーブル `bunker_accounts` を作り（すでにあれば何もしない）、保存されたアカウントを読み込んで `[bunker] loaded N account(s)` を出す。起動ログには秘密鍵も `bunker://` URI も出さない。

アカウントは管理 UI（次節）から登録する。

1. ダッシュボードのアカウントの節の「アカウントを追加」（`Add account`）を開き、nsec を貼り付けて「登録する」（`Register`）を押すか、「生成する」（`Generate`）でサーバーに鍵を作らせる。
2. nsec を貼り付けた場合は、完了ページに出る nsec を確かめる。生成した場合は、確認ページの nsec をバックアップしてから「この鍵を登録する」（`Register this key`）を押す（登録するとダッシュボードに戻り、nsec は再び表示されない）。どちらも、以後は管理パスワードを再入力したときにしか表示しない。
3. ダッシュボードの「接続 URI」（`Connection URI`）をコピーしてクライアントに貼り付ける。secret を持たない「接続 URI（要承認）」（`Connection URI (approval)`）で接続すると、管理 UI での承認を経る。

登録したアカウントには再起動なしで接続できる。secret も暗号化して保存するので、再起動しても接続 URI は変わらない。

どちらかが未設定なら、バンカーは `[bunker] disabled: <理由>` を 1 行出して無効になり、監視・プラグイン・管理 UI だけで動く。DB に到達できないときはバンカーのサブツリーは起動したまま、`[bunker] account store unavailable: ...` を 1 行出して 5 秒ごとに読み込みを再試行し、戻れば `account store is back; loaded N account(s)` を出す。この間も監視とプラグインは止まらない。パスワードやデータベース名の誤りも接続の段階で拒否されるので同じ行になり、理由が変わらない限り 2 行目は出ない。この行が出たままなら、DB の停止だけでなく `DATABASE_URL` の資格情報とデータベース名も確かめること。

バンカーは監視とは別に専用の接続をリレーごとに張り、NIP-46 の購読だけを開く。`relay.nsec.app` のような NIP-46 専用リレー（kind 24133 以外の購読を拒否する）もバンカー用にはそのまま使える。複数指定すると `bunker://` URI に `relay=` が複数入り、どれか 1 つでも生きていれば署名の往復が成立する（応答は全バンカーリレーへ発行、リクエストの重複受信はエンジンが排除）。`BUNKER_RELAY_URL` を省略すると `RELAY_URL` と同じリレーを使う（`RELAY_URL` も空なら `wss://relay.damus.io`）。

> ⚠️ **マスターキーの扱い**: マスターキーを失うと、保存した全アカウントの秘密鍵を復号できなくなる（DB だけでは戻せない）。逆に、DB のダンプとマスターキーが揃うと全アカウントの秘密鍵が漏れる。マスターキーはバックアップと同じ場所に置かず、バージョン管理に含めない `.env` などで渡すこと。環境変数はホスト上で `docker inspect` や `/proc/<pid>/environ` から読めるので、ホストの権限も絞ること。

> ⚠️ **アカウントの削除と秘密鍵の表示**: 削除するとバンカーからも DB からも鍵が消え、DB 以外に保存していない鍵は戻らない。秘密鍵を表示すると、ログに `[admin] revealed the private key of <npub>` が残る。コピーした nsec や接続 URI はクリップボードに残るので、貼り付けた後は消すこと。

> ⚠️ **`ACCOUNT_KEYS` と `BUNKER_SECRET` は廃止した**: 設定されていても値は読まず、`[main] ACCOUNT_KEYS is no longer supported and is ignored; ...` を 1 行出すだけである。

#### 対応クライアントと相互運用

kind 24133 のペイロードは **NIP-44** で暗号化する（現行仕様）。NIP-04 のみの古いクライアントは非対応（受信するとログに記録して無視）。ephemeral イベントなので、AUTH やレート制限のあるリレーだと転送されないことがある（例: `relay.damus.io` は連続リクエストで応答イベントを rate-limit で拒否することがある）。`BUNKER_RELAY_URL` には `wss://relay.nsec.app` などバンカー向けリレーを推奨。

### 管理 UI

起動すると `http://127.0.0.1:8080/` で管理 UI にアクセスできる。ダッシュボードには承認待ちの接続要求（承認・拒否ボタン付き）、アカウント（ラベル、署名者 pubkey、secret 入りの `bunker://` 接続 URI と承認を経る URI）、承認済みのクライアントセッション（取り消しボタン付き）、リレーの接続状態（監視用 / バンカー用の別）、有効なプラグインとその状態（「動作中」（`running`）、「過負荷」（`overloaded`）、「無効」（`disabled`））が並ぶ。広い画面では、承認待ち・アカウント・セッションを左の列に、リレーとプラグインを右の列に置いた 2 列で、狭い画面ではこの順に 1 列で並ぶ。リレーとプラグインの状態は、状態の語を色の付いたバッジで示す。アカウントの節は表示のたびにバンカーへ問い合わせるので、実行中に追加・削除したアカウントもそのまま反映される。バンカーが無効なとき（`bunker is disabled: DATABASE_URL is not set` など）と、読み込み中や DB の障害でアカウントを得られないとき（`account store unavailable: ...` など）は、この節に一覧の代わりにその理由が出る。

画面は日本語と英語で表示する。ナビゲーションバーの右端の切り替えで選んだ言語は cookie（`nostr_no_su_language`、365 日）に保存し、ページをまたいで保つ。選んでいなければブラウザーの `Accept-Language` の言語、どちらでもなければ英語で表示する。秘密鍵を表示するページ（生成した鍵の確認、登録の完了、秘密鍵の表示）には、押すと表示を失うので切り替えを置かない。バンカー、アカウントストア、設定、プラグインから届く理由は英語のまま表示する。設定、DB、プラグインの理由は、ログにも同じ文が出る。

アカウントごとに並ぶ次のボタンから操作する。どれも確認のページを経て POST で実行する。

- **「ラベルを編集」（`Edit label`）**: ラベルを差し替える。ラベルは前後の空白を除いて 100 符号位置以内で、制御文字（Unicode の Cc）を含められない
- **「秘密鍵を表示」（`Show private key`）**: 管理パスワードを再入力すると nsec を表示する。Basic 認証の資格情報を覚えたブラウザーの前にいる者が、操作 1 回で秘密鍵を表示できないようにするための再入力である
- **「secret を再生成」（`Rotate secret`）**: 接続 secret を作り直す。古い URI での新しい `connect` は承認なしには通らなくなるが、承認済みのセッションは残る。クライアントには新しい URI を貼り直す
- **「アカウントを削除」（`Delete account`）**: バンカーと DB から鍵を消す。その署名者のセッションと承認待ちも消える

変更の結果は次のように見える。

| 結果 | 画面 | 状態コード |
| --- | --- | --- |
| 反映された | ダッシュボードへ戻る（nsec 入力による登録だけは完了ページ） | 303（nsec 入力による登録は 200） |
| 反映されていない（登録済み、管理 UI が一覧を引いてからバンカーが変更を処理するまでの間に削除された（同時に送られた削除など）、書き込まれていないことが確定した DB の失敗） | フォームに理由が出る | 409 |
| 一覧に無い署名者への操作（削除済みの署名者への削除・secret の作り直し・ラベルの編集など） | `Not found` | 404 |
| 受け付けられない（起動時の読み込みか、結果が曖昧な書き込みの後の読み直しの前、DB の障害で一覧を得られない、バンカーが無効） | 「アカウントを利用できません」（`Accounts are not available`）のページ | 503 |
| 反映されたか分からない（書き込みの期限切れ、途中の切断、DB のクライアントの例外、バンカーの無応答） | 「変更を確認できませんでした」（`Change not confirmed`）のページ | 202 |

「変更を確認できませんでした」（`Change not confirmed`）のページでは、再読み込みで POST を再送せず、ダッシュボードを開いて反映されたかを確かめること。再送した場合の結果は次のとおりで、どの場合も同じ鍵のアカウントが 2 つ登録されることはない。読み直しが終わる前の再送はどれも 503 になる。

| 再送する POST | 最初の変更が反映されていた場合 | 反映されていなかった場合 |
| --- | --- | --- |
| nsec 入力による登録 | 409 `account is already registered`（nsec は表示しない） | 登録して完了ページ（nsec を表示） |
| 生成した鍵の登録 | 409 `account is already registered` | 登録してダッシュボードへ戻る |
| secret の作り直し | secret をもう一度作り直してダッシュボードへ戻る（ダッシュボードは常に最新の URI を出す） | 作り直してダッシュボードへ戻る |
| 削除 | 404 `Not found`（アカウントはすでに一覧に無い） | 削除してダッシュボードへ戻る |
| ラベルの編集 | 同じラベルで差し替えてダッシュボードへ戻る（害は無い） | 差し替えてダッシュボードへ戻る |

nsec 入力による登録の完了ページを再読み込みすると、同じ nsec の再送は 409 になり、nsec は再び表示されない。生成の確認ページを再読み込みすると、別の鍵の確認ページが出るだけで何も登録されない。生成した鍵の登録でラベルだけが規則に反した場合は、生成した鍵を失わないよう、同じ鍵の確認ページが理由付きで出る（400）。

認証は HTTP Basic で、ユーザー名は `admin` 固定。パスワードは `ADMIN_PASSWORD` で指定する。未設定なら起動ごとにランダム生成してログに出力する:

```
[admin] generated password for user "admin": <password>
```

`ADMIN_PORT` で待ち受けポートを変更でき、空文字列（`ADMIN_PORT=`）にすると管理 UI を無効にできる。`GET /healthz` だけは認証なしで `ok` を返す。イメージにはこれを叩く `HEALTHCHECK` が入っているため、`docker ps` の `STATUS` にコンテナーの状態が出る。`ADMIN_PORT=` で管理 UI を無効にした構成では待ち受けが無いのでチェック自体を省略し、healthy として扱う。

ページのスタイルは、ビルドした CSS（`/static/admin.css`）を管理 UI 自身が配信する。CDN などの外部のファイルは読まないので、外部に到達できない環境でも表示できる。CSS もページと同じく Basic 認証の後にある。

待ち受けアドレスの既定は `127.0.0.1`（ループバックのみ）で、`ADMIN_BIND` で変更する。コンテナーの外へポートを公開するには `ADMIN_BIND=0.0.0.0` が必要になるが、その場合は公開範囲を別途絞ること（同梱の compose はホスト側のループバックにだけ公開する）。

> ⚠️ **平文 HTTP である**: Basic 認証の資格情報は暗号化されずに送られ、ページには署名権限そのものである secret 入りの `bunker://` URI が表示される。localhost か Docker ネットワーク内での利用を前提とし、外部に公開するときは必ずリバースプロキシーで TLS を終端すること。

#### リバースプロキシーの設定

前段のリバースプロキシーは、`Host` ヘッダーをブラウザーが送った値のまま（公開ホスト名と、既定以外のポートならそのポートを含めて）管理 UI へ渡すこと。状態を変える POST は `Origin`（無ければ `Referer`）のホストとポートを `Host` と突き合わせて CSRF を防いでおり（`X-Forwarded-Host` は見ない）、`Host` が上流のアドレス（`127.0.0.1:8080` など）に書き換わっているか、既定以外のポートで公開していてポートが落ちていると、承認、登録、削除を含むブラウザーからの POST がすべて 400（本文は `Bad request: Invalid origin`、ログには `Origin-host mismatch: <Host> <Origin>`）になる。nginx は既定で `Host` を `proxy_pass` の宛先に書き換え、`$host` はポートを含まないので、`$http_host` を渡す:

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

承認ページの URL の土台にする公開 URL（上の例なら `https://admin.example`）は、`ADMIN_BASE_URL` に設定する（「接続の承認（auth_url フロー）」）。

#### 接続の承認（auth_url フロー）

secret を持たない `bunker://` URI（ダッシュボードの「接続 URI（要承認）」（`Connection URI (approval)`）の欄）で接続すると、バンカーはその場では承認せず、NIP-46 の `auth_url` 応答で承認ページの URL をクライアントへ返す。クライアントはその URL をブラウザーで開き、管理 UI にログインして内容（署名者・クライアント pubkey・経過時間）を確認したうえで承認または拒否する。承認するとバンカーは元のリクエストと同じ id で `ack` を返し、待っていたクライアントの接続が完了する。拒否するとエラーを返す。承認ページは枠（iframe）の中では開けないので、クライアントは新しいウィンドウかブラウザーで開く必要がある。

承認ページの URL は `ADMIN_BASE_URL` を土台に `<base>/approve/<token>` として組み立てる（既定は `http://localhost:<ADMIN_PORT>`）。クライアントのブラウザーから開ける URL である必要があるため、リバースプロキシーの背後に置くときや別のホストから使うときは公開 URL を設定すること。管理 UI を無効（`ADMIN_PORT=`）にすると承認フローも無効になり、secret の一致しない `connect` は従来どおり `invalid secret` で拒否する。

承認される前にクライアントが再読み込みして `connect` を送り直した場合、承認待ちは最新の要求に置き換わる（同じクライアントの保留が並ばないようにするため）。先に受け取った `auth_url` のページは 404 になるので、新しく開かれた方の承認ページを使う。

承認待ちはダッシュボードの「承認待ちの接続」（`Pending connections`）からも承認・拒否でき、10 分で失効する。一度承認したクライアントは、以後 secret 無しで `connect` し直しても承認を求められない（取り消すには「承認済みのセッション」（`Approved sessions`）の「承認を取り消す」（`Revoke`）を使う）。

状態を変える POST すべて（アカウントの登録・生成・削除・secret の作り直し・ラベルの編集・秘密鍵の再表示、`POST /sessions/revoke`、`POST /approve/<token>`、`POST /deny/<token>`、言語の切り替え（`POST /language`））は `Origin` / `Referer` と `Host` を突き合わせて CSRF を防いでいる。`Origin` を送らないクライアント（curl など）はそのまま通る。前段にリバースプロキシーを置くときの `Host` の渡し方は「リバースプロキシーの設定」にある。

認証済みの応答にはすべて `cache-control: no-store` と、枠への埋め込みを禁じる `x-frame-options: DENY` / `content-security-policy: frame-ancestors 'none'` を付けている。どのページも secret か秘密鍵を含みうるためと、削除やローテーションの確認ページを他のサイトの枠に読み込んでボタンを押させる操作（枠の中の POST は同じオリジンから送られるので CSRF の検査では防げない）を防ぐためである。

### 監視のみ（バンカー無効）

`DATABASE_URL` か `ACCOUNT_MASTER_KEY` が無ければ監視のみモードで動く。同梱の compose は `DATABASE_URL` を同梱の Postgres に向けているので、`ACCOUNT_MASTER_KEY` を設定しなければ監視のみになる:

```sh
docker compose up --build
```

### docker compose

compose には Postgres（`postgres:17-alpine`）が同梱されており、アプリは healthcheck が通ってから起動する。同じ Postgres を本体（バンカーのアカウント、`DATABASE_URL`）とプラグイン（イベント、`PLUGIN_EVENT_LOGGER_DATABASE_URL`）の両方が使う。データは `postgres-data` volume に永続化され、`docker compose down -v` で消える（**暗号化したアカウントも消える**）。Postgres のポートはホストに公開しない（アプリは compose ネットワーク経由で到達する）ため、保存されたデータは `docker compose exec postgres psql -U nostr -d nostr_no_su` で確認する。

管理 UI のポートはホストのループバック（`127.0.0.1:8080`）にだけ公開する。コンテナー内では `ADMIN_BIND=0.0.0.0` を渡して全インターフェースで待ち受けさせ、外部からの到達性はこの公開先で絞っている。`ADMIN_PORT` を変えると公開ポートも追従する。

**`PLUGIN_DIR` に置いた BEAM は本体と同じ VM・同じ権限で動く。サンドボックスは無く、秘密鍵を持つプロセスにも到達できる（`sys:get_state/1`）。信頼できるものだけを置くこと。** 第三者から受け取ったプラグインはソースを読んでから置く。

外部プラグインは `./plugins` に置くと読み込まれる（コンテナー内の `/plugins` に読み取り専用でマウントし、`PLUGIN_DIR=/plugins` を渡している）。コンテナーは非 root（uid 1000）で動くため、**置いたあとに `chmod -R a+rX plugins` が必要**である。プラグインの置き方は [プラグイン API v1](docs/plugin-api.md) の第 8 章、動作確認用の例は `examples/plugins/file_logger/`（状態を持たない例）と `examples/plugins/counter/`（状態を持つ例）、実プラグインは `plugins-src/event_logger/`（イベントを Postgres へ保存する）を参照。`PLUGIN_DIR=` と空にすると読み込みを無効にできる。

プラグイン固有の設定は `PLUGIN_<NAME>_<KEY>` の形の環境変数で渡す（`file_logger` の出力先なら `PLUGIN_FILE_LOGGER_PATH`）。compose の `environment:` は明示的な列挙なので、自分のプラグインの分は `docker-compose.yml` に書き足すこと。設定が足りないプラグインは読み込み時に理由を 1 行出して**そのプラグインだけが無効になり**、本体の起動と他のプラグインには影響しない（[プラグイン API v1](docs/plugin-api.md) の第 6 章）。

資格情報は compose 内で `nostr` / `nostr` / `nostr_no_su` に固定されている。変えるときは `postgres` サービスの `POSTGRES_*`、`DATABASE_URL`、`PLUGIN_EVENT_LOGGER_DATABASE_URL` の 3 か所を合わせること。

**`DATABASE_URL` は意味を変えて復活した。** PR #34 より前はイベント保存の設定だったが、イベント保存は外部プラグイン `event_logger` になり、設定も `PLUGIN_EVENT_LOGGER_DATABASE_URL` へ移った（`PLUGIN_<NAME>_<KEY>` の規則）。現在の `DATABASE_URL` は **本体のバンカーがアカウントを保存する先** である。旧構成の `.env` をそのまま使うと、イベント保存用だった URL がアカウントストアの接続先として読まれ、同じ DB に `bunker_accounts` テーブルが作られる（害は無いが、意図と違うなら値を見直すこと）。**`PLUGIN_EVENT_LOGGER_DATABASE_URL` の空文字列の意味も旧 `DATABASE_URL` と違う。** 旧構成では `DATABASE_URL=` で保存を黙って無効にできたが、`PLUGIN_EVENT_LOGGER_DATABASE_URL=` は空値が落ちてプラグインにはキーごと届かないため、設定不足として拒否され起動のたびに 1 行出る。**イベント保存を無効にする正しいやり方は、プラグインを置かないことである。**

### 環境変数

表のデフォルトは、アプリが未設定のときに使う値である。docker compose で起動するときは `docker-compose.yml` が一部の変数に別の値を渡す（同梱の Postgres の URL、`PLUGIN_DIR=/plugins` など）。`.env` で変える変数の既定値と書き方は `.env.example` にある。

| 変数 | デフォルト | 説明 |
| --- | --- | --- |
| `RELAY_URL` | `wss://relay.damus.io` | 監視先リレーの URL（カンマ区切りで複数可）。空にすると監視無効（バンカーのみ） |
| `BUNKER_RELAY_URL` | `RELAY_URL` と同じ | バンカーが購読・応答するリレーの URL（カンマ区切りで複数可）。`RELAY_URL` も空なら `wss://relay.damus.io` |
| `DATABASE_URL` | （空） | バンカーのアカウントを保存する Postgres の URL（`postgres://user:pass@host:5432/db`。`postgresql://` も可）。空ならバンカー無効。docker compose では同梱の Postgres を指す（注 1） |
| `ACCOUNT_MASTER_KEY` | （空） | アカウントの秘密鍵と接続 secret を暗号化するマスターキー（64 文字の 16 進 = 32 バイト、`openssl rand -hex 32`）。空か不正ならバンカー無効。自動生成はしない |
| `PUBKEYS` | （空） | 監視するアカウントの hex 公開鍵（カンマ区切り）。空なら直近のイベントを購読 |
| `PLUGIN_EVENT_LOGGER_DATABASE_URL` | （空） | 外部プラグイン `event_logger` 固有の設定。イベントを保存する Postgres の URL（`postgres://user:pass@host:5432/db`）。プラグインを置いていなければ誰も読まない。空にしても無効化にはならない（保存をやめるならプラグインを置かない）。docker compose では同梱の Postgres を指す |
| `PLUGIN_DIR` | （空） | 外部プラグインを探すディレクトリー。空なら読み込まない。ここに置いた BEAM は本体と同じ VM で動くため、信頼できるものだけを置くこと（[プラグイン API v1](docs/plugin-api.md) の第 8 章） |
| `PLUGIN_<NAME>_<KEY>` | （空） | プラグイン固有の設定。`<NAME>` は `plugin_name/0` の値を大文字化し `[A-Z0-9]` 以外を `_` にしたもの。プラグインには `<KEY>` を小文字にした binary キーの map として届く（[プラグイン API v1](docs/plugin-api.md) の第 6 章） |
| `ADMIN_PORT` | `8080` | 管理 UI が待ち受けるポート（1〜65535）。空文字列なら管理 UI を無効にする。範囲外や数値でない値は理由をログに出して無効にする |
| `ADMIN_BIND` | `127.0.0.1` | 管理 UI が bind するアドレス。コンテナー外へ公開するには `0.0.0.0` が必要 |
| `ADMIN_PASSWORD` | （空） | 管理 UI の Basic 認証パスワード（ユーザー名は `admin`）。未設定なら起動ごとにランダム生成してログに出力 |
| `ADMIN_BASE_URL` | `http://localhost:<ADMIN_PORT>` | 承認ページ（`auth_url`）の URL を組み立てる管理 UI の公開 URL。クライアントのブラウザーから開ける値にする |

注 1: `DATABASE_URL` の userinfo はパーセントデコードされない。`:` を含むパスワードや、データベース名の無い URL は解釈できず、起動ログに `[bunker] disabled: DATABASE_URL is not a valid postgres URL` が出る（URL そのものはログに出さない）。

`ACCOUNT_KEYS` と `BUNKER_SECRET` は廃止した。設定されていれば名前だけを起動ログに出し、値は読まない。

### ローカル開発 (Gleam 1.17.0 / Erlang OTP 29 で検証)

```sh
gleam run   # 実行
gleam test  # テスト（BIP-340 / NIP-44 / NIP-19 公式ベクター + バンカーのループバック）
```

CI と Docker イメージはどちらも Gleam 1.17.0 / OTP 29 で、検証しているのはこの組み合わせだけ。より古い OTP でも動く可能性はあるが確認していない。

本体のアカウントストアの統合テストも `TEST_DATABASE_URL` が設定されているときだけ走る（未設定ならスキップして 1 行ログを出す）:

```sh
docker run -d --name nns-pg-test -p 127.0.0.1:5433:5432 \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=nostr_no_su_test postgres:17-alpine
TEST_DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5433/nostr_no_su_test gleam test
docker rm -f nns-pg-test
```

本体も `pog` 経由で `opentelemetry_api`（`build_tools = ["rebar3", "mix"]`）に依存するため、ホストに elixir があると、ホストで作った erlang-shipment には Elixir 一式が混ざる。配布する成果物は Dockerfile の中で作ること。

管理 UI の CSS（`priv/static/admin.css`）は、ビルドした生成物をリポジトリに含めているので、`gleam run` と `docker compose up --build` に Node.js は要らない。描画のモジュール（`src/nostr_no_su/admin/` の `.gleam`。文言の `admin/i18n.gleam` を除く）か `assets/admin.css` を変えたときは、ビルドし直して一緒にコミットする（CI が差分を検査する）。Tailwind はクラスに限らず、文字列、識別子、コメントの語もクラスの候補として拾うので、クラスを変えなくても CSS が変わることがある。画面の文言は走査の外の `admin/i18n.gleam` にあるので、文言だけの変更では CSS は変わらない。Node.js 24 で検証している:

```sh
npm ci             # Tailwind CSS、daisyUI、playwright-core を package-lock.json の版で入れる
npm run build:css  # assets/admin.css から priv/static/admin.css を作る
```

管理 UI の全ページを固定の状態で確かめるときは、撮影用のサーバーを起動して撮る。サーバーは `PREVIEW_PORT` から続く 3 つのポートで、通常の状態、アカウントの一覧を得られない状態、すべての一覧が空の状態を出す（ユーザー名は `admin`、パスワードは `preview-password`）。鍵は公開のテストベクター、secret はダミーの値である。サーバーは終了しないので、1 つの端末で起動したまま別の端末で撮る。初回は `npx playwright-core install chromium` で、`playwright-core` の版が使う chromium を入れる（ブラウザーが無いときのエラーが勧める `npx playwright install` は、別のパッケージとその版のブラウザーを入れるので、必要な版が入るとは限らない）:

```sh
PREVIEW_PORT=18461 gleam run -m admin_preview                          # 端末 1（終了しない）
npx playwright-core install chromium                                   # 端末 2。初回だけ
PREVIEW_PORT=18461 node dev/screenshots.mjs build/screenshots          # 26 画面を 1280px と 375px、ライトとダークで撮る
PREVIEW_PORT=18461 node dev/screenshots.mjs build/screenshots-ja ja-JP # 日本語の画面を撮る
```

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
src/nostr_no_su/admin/dashboard.gleam        -- 表示する状態の型、パスとフォームの欄の名前の定義、ダッシュボードと承認と通知のページの描画
src/nostr_no_su/admin/account_pages.gleam    -- アカウントの登録、生成の確認、登録の完了、操作、秘密鍵の表示のページの描画
src/nostr_no_su/admin/view.gleam             -- 管理 UI のページ枠と、本体の他のモジュールに依存しない部品（lustre の要素ツリーを HTML 文字列にする。見た目は daisyUI のクラスで付ける）
src/nostr_no_su/admin/i18n.gleam             -- 管理 UI の表示の言語（型と選び方）と、日本語と英語の文言
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
src/nostr_no_su/crypto/aes_gcm.gleam         -- AES-256-GCM の箱（nonce || 暗号文 || タグ）
src/nostr_no_su/nostr/event.gleam            -- Event 型・コーデック・ID 計算・署名
src/nostr_no_su/nostr/filter.gleam           -- 購読フィルター
src/nostr_no_su/nostr/message.gleam          -- クライアント⇄リレーのメッセージ
src/nostr_no_su/nostr/nip19.gleam            -- NIP-19 の npub / nsec（bech32）の符号化と復号
src/nostr_no_su/relay_client.gleam           -- WebSocket クライアント (stratus)
src/nostr_no_su/relay_connection.gleam       -- リレー 1 本ぶんの接続を保つ actor（切断検知と再接続）
src/nostr_no_su/bunker.gleam                 -- バンカーの actor（セッション状態を保持）
src/nostr_no_su/bunker/engine.gleam          -- NIP-46 リクエスト処理の純粋コア
src/nostr_no_su/bunker/rpc.gleam             -- JSON-RPC コーデック
src/nostr_no_su/bunker/account.gleam         -- 鍵材料と bunker:// URI
src/nostr_no_su/bunker/vault.gleam           -- マスターキーと、アカウントの暗号化形式・行の検証（純粋）
src/nostr_no_su/bunker/account_store.gleam   -- アカウントを Postgres に保存するストア（pog）
src/nostr_no_su/plugin.gleam                 -- プラグイン機構（プラグイン API v1 の検証と読み込み）
src/nostr_no_su/plugin_children.gleam        -- 任意エクスポート plugin_children/0・/1 の検証と子仕様への変換
src/nostr_no_su/plugin_config.gleam          -- プラグイン固有の設定（PLUGIN_<NAME>_<KEY>）の切り出しと map への変換
src/nostr_no_su/plugin_loader.gleam          -- 外部プラグインの走査とコードパスへの追加
src/nostr_no_su/plugin_runner.gleam          -- プラグイン 1 つぶんの実行プロセス（隔離・時間制限・無効化）
src/nostr_no_su/plugins/console_logger.gleam -- コンソールロガープラグイン
src/nostr_no_su_ffi.erl                      -- OTP への FFI（crypto / code / file / process: 監視付きワーカーの生成と終了理由の整形）
assets/admin.css                             -- 管理 UI の CSS の入力（Tailwind CSS / daisyUI。npm run build:css でビルドする）
priv/static/admin.css                        -- ビルドした管理 UI の CSS（生成物。CI で最新であることを検査する）
dev/admin_preview.gleam                      -- 管理 UI を固定の状態で起動する撮影用のサーバー（成果物には入らない）
dev/screenshots.mjs                          -- 撮影用のサーバーから全ページを撮るスクリプト（playwright-core）
dev/check_vendor_stratus.sh                  -- vendor/stratus が上流の tar とパッチから再現できるかの検査（CI でも実行する）
package.json                                 -- CSS のビルドと撮影に使う npm のパッケージ（版は package-lock.json で固定する）
vendor/stratus/                              -- パッチ済み stratus（下記参照）
examples/plugins/file_logger/                -- 外部プラグインの例（状態を持たず、設定を受け取る Erlang 1 ファイル）
examples/plugins/counter/                    -- 外部プラグインの例（plugin_children/0 で子プロセスを申告する）
plugins-src/event_logger/                    -- 同梱の外部プラグイン（Postgres へ保存する。独自の依存と設定を持つ Gleam プロジェクト）
docs/plugin-api.md                           -- プラグイン API v1 の仕様（プラグイン作者向け）
docs/architecture.md                         -- システム構成（プロセス・経路・読み込み・配置・設定の図解）
```

## 設計上の判断・既知の制約

- **スーパービジョンツリー**: root（one_for_one）の下にプラグイン・監視・バンカーのサブツリーを置き、プラグインのサブツリーは one_for_one、他は rest_for_one。先頭の actor（重複排除ディスパッチャー / バンカー actor）が再起動すると後続のリレー接続も再起動し、購読と publisher の再設定が自然に行われる。actor は名前付きプロセスなので、リレー接続は名前宛てに送信すれば再起動後のプロセスにそのまま届く。バンカーのサブツリーだけは、actor の前にアカウントストアの接続プール（pog）を置く。pgo はプール名が未登録のままクエリーを受けると呼び出し側を `noproc` で exit させるため、プールを先頭に置いて actor がプールの登録後にしか動かないようにしている
- **秘密鍵と接続 secret は暗号化して保存する**: 形式は AES-256-GCM の「nonce（12 バイト）|| 暗号文 || タグ（16 バイト）」で、暗号化ごとに乱数の nonce を使う。AAD は用途ラベル（`nostr-no-su:bunker-account:privkey:v1` / `...:secret:v1`）、NUL 1 バイト、x-only 公開鍵の 32 バイトの連結で、ある行の暗号文を別の列や別の行へ移す改ざんはタグの検証で失敗する。ラベル末尾の `v1` は形式の版である。マスターキーは自動生成しない。生成して DB と同じ場所に保存すれば暗号化の意味が無く、起動ごとに作れば再起動でアカウントを失うためである。復号できない行（マスターキー違い、改ざん、公開鍵との不一致など）はその行だけを飛ばして `[bunker] skipped account <pubkey>: <理由>` を出し、完了行を `loaded 2 of 3 account(s)` の形にする。マスターキーと復号した秘密鍵はプロセスの状態に関数として閉じ込め、`string.inspect` やクラッシュレポートに値が出ないようにしている（VM 内のコードから取り出す道は残る。プラグインの信頼モデルの範囲である）
- **DB の障害はバンカーのアカウント読み込みに閉じ込める**: DB の停止はプロセスの死にならない（pgo が再接続を内部で扱い、クエリーは値で失敗する）。バンカー actor はストアの失敗で落ちず、再試行を予約してログを 1 行出すだけである。pog が写せないエラーで `pog.execute` が例外を投げても、`account_store` が例外のクラスと発生箇所だけを持つ値に写し、書き込みなら期限切れと同じく DB から読み直す。起動時にも DB を待たず、読み込みは actor が自分宛に積むメッセージで行う。したがって DB が落ちていても root の `restart_tolerance(3, 60)` は消費されず、監視とプラグインは動き続ける。再試行のタイマーは actor ごとの名前なしの subject に予約するので、actor が再起動しても古いタイマーは取り消され、再試行が重複しない
- **アカウントの追加と削除はバンカー actor を再起動せずに反映する**: 再起動すると rest_for_one で接続も落ち、インメモリのセッションが消えるためである。署名者の集合が変わると（追加、削除、読み込みの失敗からの復帰）、actor は接続 actor を名前で呼んで購読の張り直しを依頼し、接続 actor が生きたソケットへ転送する。ソケットはそのとき現在の署名者を問い合わせて購読を照合し、同じ id の REQ で置き換える（NIP-01 では同じ id の REQ は置き換えで、CLOSE と REQ の間に取りこぼしの窓ができない）。署名者が 0 件になったら空の `#p` は送らず CLOSE を送る（空配列の扱いはリレーによって異なるため）。secret とラベルの差し替えでは購読は変わらない。kind 24133 を保存するリレー（strfry など）は置き換えの REQ に対して直近 60 秒のリクエストを再送するが、処理済みのものはリプレイ防止の `seen` が落とす
- **アカウントの変更は DB への書き込みが成功してからメモリに反映する**: 書き込みはバンカー actor の中で行い、成功したときだけエンジンの状態を変える。書き込まれていないことが確定した失敗（DB に到達できない、制約違反など）ではメモリを変えない。書き込みが 1 秒の期限を過ぎたときや途中で接続が切れたときは、文がサーバー側でまだ実行中か、すでにコミットされていることがある（Postgres は実行中の文でクライアントの切断を検出しない）。この場合はメモリを変えずに DB から読み直して合わせ、管理 UI は 202 の「変更を確認できませんでした」（`Change not confirmed`）のページでダッシュボードでの確認を促す。読み込みは 1 本のトランザクションで `LOCK TABLE bunker_accounts IN SHARE MODE` を取ってから行うので、実行中の書き込みがあればその終了を待ってから読む（起動時の読み込みも同じで、書き込みの途中で落ちた actor の後に再起動した actor が、その書き込みより先に読むことを防ぐ）。つまりメモリは成功した書き込みと成功した読み込みの結果だけで変わり、結果が曖昧な書き込みの後は、読み直しに成功した時点でその書き込みの結果を含めて DB と一致する。**残る窓**として、期限の直前に送った文がサーバーに届いてロックを取るより先に読み直しがロックを取ると、その書き込みは読み直しに見えない。ローカルの Postgres で期限切れの挿入を起こした測定では、コミットされた 704 件のうち読み直しに見えなかったものは 0 件だった（ロックを取らない読み込みでは 712 件中 77 件）。この窓に当たっても、追加はもう一度追加すると、DB が登録済みを返したときに応答の前に読み直すので一致し、secret の作り直しはもう一度作り直せば一致する。読み込みで飛ばされる行（別のマスターキーで暗号化されているなど）の公開鍵を追加すると、読み直してもメモリに入らないので `account is already registered` で拒否される。その行は DB から直接消す必要がある。読み直しに失敗したら 5 秒ごとに再試行し、成功するまでの間は一覧に理由を出して変更を拒否する（NIP-46 の処理はメモリのアカウントで続ける）。書き込みの後に actor が落ちても、再起動した actor が DB から読み直す
- **DB が不調な間は NIP-46 の処理が待たされる**: 書き込みと読み込みはバンカー actor の中で行うので、その間に届いたリクエストはメールボックスに積まれ、終わった後に処理される（捨てない）。変更の操作 1 回の書き込みは最長で約 3 秒（DB に到達できないときのチェックアウトの失敗が約 2〜3 秒、到達できて遅いときは書き込みの期限 1 秒で打ち切る）。読み込み 1 回は期限の 3 秒で打ち切り、DB を `docker pause` で止めた測定では 3000ms、2950ms、2000ms で失敗して返った。結果が曖昧な書き込みの後に DB が止まったままだと、読み直しの再試行（5 秒ごと）のたびに最長 3 秒ずつ待ちが生じ、読み直しが成功するまで続く。起動時に DB に到達できない間も同じ間隔で待ちが生じるが、そのときはまだ署名者がいないので応答すべきリクエストは無い。別の書き込みプロセスに分けないのは、書き込みと状態の変更を 1 つの処理に閉じて扱う順序を単純に保つためで、分けると完了通知の前にプロセスが死んだときの回復や、秘密を運ぶメッセージの経路が増える
- **署名者を問い合わせられないときは購読を変えない**: バンカー actor が 5 秒以内に応答せず購読の定義を得られないときは、開いている購読を閉じずにそのままにし、5 秒ごとに再試行する（ログは `could not evaluate subscriptions; keeping the current ones and retrying in 5000ms`）。応答が無いことを署名者 0 件として扱うと、actor が DB の書き込みで詰まっている間に全署名者の購読を閉じてしまうためである。予約する再試行は常に 1 つだけで、世代を付けて古いタイマーを捨てる
- **DB の行を直接変えても実行中のバンカーには反映されない**: メモリは起動時の読み込みと、actor 経由の変更の成功だけで変わる。`psql` などで `bunker_accounts` の行を直接変えた場合は、次の起動（またはバンカー actor の再起動）まで反映されない
- **pgo のクラッシュレポートには DB のパスワードが出うる**: pgo のプロセス（`pgo_pool`、`pgo_pool_sup`、`pgo_connection` など）は接続設定を状態や起動引数に持ち、`format_status` を定義していない。これは `event_logger` でも同じで、pgo を改変しない限り塞げない。本体は `DATABASE_URL` を理由の文字列やログに入れず、解釈も 1 か所（`account_store.pool_config`）に限っている。マスターキーは pgo に渡さないので影響を受けない
- **プラグインは専用プロセスで動かす**: プラグイン 1 つにつきランナーを 1 つ、root（one_for_one）直下の `plugins` サブツリーに置く。ディスパッチャーはイベントを送るだけで戻るので、遅いプラグインが他のプラグインや監視を止めない。プラグインのイベント処理関数はイベントごとに使い捨てのプロセス（`erlang:spawn_monitor/1`。**リンクは張らない**）で動かすため、プラグインの例外・異常終了・ハングはランナーの死にならない。**プラグインの不調で supervisor の再起動が起きない**ということであり、root の `restart_tolerance(3, 60)` を消費してアプリ全体を落とすことがない。1 件あたり 30 秒で打ち切り、連続 5 回失敗したプラグインは無効化してログに出し、以後はイベントを捨てて件数を数える（管理 UI には「無効」（`disabled`）として残る。再有効化は本体の再起動か、ランナーの強制終了）。未処理のイベントが 1000 件を超えたプラグインは、キューが空になるまで捨てて復帰時に件数を報告する（`event_logger` プラグインが DB 到達不能時に行うのと同じ形。捨てるのは超過分だけでなくバックログ全体なので、配信は best-effort である）。ワーカーの終了理由は FFI 側で `error:badarg` の形の 1 行に整えている。DOWN の理由は既定ではスタックトレース込みで数百文字になり、ログにもダッシュボードにも収まらないため
- **プラグインが申告した子プロセスは Temporary で載せる**: 任意エクスポート `plugin_children/0` を持つプラグインの子は、プラグインごとの専用スーパーバイザー（one_for_one、10 秒に 5 回）にまとめ、その子仕様を **Temporary** にする。段を挟むだけではクラッシュループを止められないので、歯止めは再起動の型で作る。子スーパーバイザーが諦めると理由 `shutdown` で終了し、親は再起動もせず許容回数も消費しない（`supervisor.erl` の `do_restart(shutdown, ...)` は `add_restart/1` を通らない）。Transient ではなく Temporary にするのは、仕様ごと削除されることと、外部からの kill のような別の理由で落ちたときにも再起動されないためである。代償として、一度諦めた子は本体を再起動するまで戻らない。起動時の失敗は空のスーパーバイザーで吸収してアプリの起動を止めず、理由は子ごとの 1 行ログに出す
- **設定を受け取る口はアリティ +1 の任意エクスポートで足す**: プラグイン固有の設定は環境変数 `PLUGIN_<NAME>_<KEY>` から切り出し、binary キーの map として `plugin_children/1` と `handle_event/2` に渡す。既存の `plugin_children/0` / `handle_event/1` を持つプラグインは無変更で動くので、**API バージョンは 1 のまま**である（`handle_event` だけは必須側のアリティが `/1` または `/2` の 2 通りになるが、既存のプラグインは 1 つも落ちないため破壊的変更にあたらない）。設定不足の申告を宣言的な必須キー一覧ではなく `plugin_children/1` の `{error, Reason}` にしたのは、**値の妥当性まで検査できる**のがプラグイン側だけだからである。キーの存在と、その値が Postgres の URL として解釈できることは別で、後者を読み込み時に検査できないと不正な値が「子の起動失敗 → 連続失敗 → `disabled`」という遠回りな症状に化ける
- **リレー接続 actor は exit を trap する**: stratus のプロセスは接続 actor にリンクされる。切断のたびに actor ごと落とすと supervisor の再起動回数を消費してしまうため、exit を trap してメッセージとして受け取り、5 秒後の再接続をスケジュールする。gleam_otp の actor ループは trap した exit を未知のメッセージとして捨てるので、supervisor からの shutdown は接続 actor 側で検出し、trap を解除して同じ理由で exit し直す（リンク経由でソケットも一緒に終了する）
- **バンカーは専用接続（リレーごと）**: 監視と接続を分けることで、NIP-46 以外の購読を拒否するリレー（relay.nsec.app 等）をバンカー用に使える。応答はどのリレーから来たリクエストでも全バンカーリレーへ発行する。クライアントは URI の `relay=` を全部聴くので、リレーが 1 つ生きていれば往復が成立する
- **イベント保存は外部プラグイン**: イベント保存用の pog の接続プールと保存 actor は本体ではなくプラグインが `plugin_children/1` で申告し（本体のプールはバンカーのアカウント専用である）、`plugins` サブツリーの下（one_for_one）で動く。プラグインごとのサブスーパーバイザーが Temporary なので、DB 由来のクラッシュループが本体を巻き込むことはない。保存 actor はプールを名前で参照するため、rest_for_one でなくても再起動をまたいで配線が保たれる。DB に到達できない間は保存を止めて破棄した件数を数え、復帰時にまとめて報告する（挿入のたびに接続を待つと actor がブロックしてメールボックスが伸びるため）。接続の復旧は pog のプールに任せる
- **管理 UI は root 直下の独立した子**: mist（HTTP サーバー）は監視・バンカー・保存のどれにも依存しないため、root（one_for_one）に並べる。表示する状態はハンドラーが直接触らず、Context に注入された関数から名前付き actor へ問い合わせて取る。問い合わせが失敗しても（再起動中、タイムアウト）ページ全体を失敗させず、その項目だけ、リレーは「未接続」（`disconnected`）、プラグインは「応答なし」（`unavailable`）、承認待ちとセッションは空の一覧として描画する。描画は「状態のスナップショット → HTML 文字列」の純粋関数である（次項）
- **管理 UI はサーバー側で描画する**: ページは lustre の要素ツリー（`lustre/element`）で組み立て、Erlang 上で HTML 文字列にして返す。値はテキストか属性値として渡し、HTML のエスケープは lustre の文字列化が行うので、値ごとにエスケープを書く必要が無い（値を HTML やスクリプトとしてそのまま解釈させる経路は、定数だけを渡す `onclick` と、パスの定義から作る `href` と `action` に限る。lustre は URL を検査しないので、`href` と `action` にはパスの定義から `/` で始めて組み立てた値か `"/"` だけを渡す）。lustre のクライアント側のアプリ（SPA）や server components にはしない。SPA にすると秘密鍵や secret 入りの URI を返す JSON API が要り、server components にすると Basic 認証の裏に WebSocket と JS のランタイムの配信が要るので、秘密鍵を POST の本文と応答の本文だけで運ぶ前提を作り直すことになるためである。ブラウザーで動く JS はコピーのボタンの `onclick` だけで、フォームの送信と画面の遷移は JS なしで動く
- **管理 UI の CSS はビルドしてリポジトリに含め、自前で配信する**: Tailwind CSS 4 と daisyUI 5 の CSS を `npm run build:css` でビルドし、生成物の `priv/static/admin.css` をコミットしている。実行時に CDN などの外部のファイルを読まず、Docker のビルドにも Node.js やツールの取得が要らない。版は `package-lock.json` で固定し、CI でビルドし直した結果がコミットと一致することを検査する（同じ入力から、Node.js 24 と 25、glibc と musl、standalone CLI のどれでもバイト単位で同じ CSS ができることを確かめた）。Tailwind はソースに完全な文字列で書かれたクラスしか出力しないので、クラス名を連結で組み立てず、描画しうるクラスがすべて CSS に定義されていることをテストで検査する。文言のモジュール（`admin/i18n.gleam`）は、文の語が daisyUI の部品の名前として拾われないよう、Tailwind の走査から外している。フォーカスできるボタン（`btn`）の文字列には `focus-visible:outline-base-content` を、入力欄（`input`）の文字列には `border-base-content/60` を付ける（daisyUI の既定では、注意と破壊のボタンのフォーカスの輪郭と入力欄の枠が、隣接する背景に対して 3:1 に届かないため）。ボタンのフォーカスの輪郭と入力欄の枠のクラスの付け忘れも、同じテストで検査する。CSS はページと同じく Basic 認証の後に置き、`no-store` で返す。更新しても古い CSS が残らない代わりに、ページを開くたびに約 40 KB を読み直す。テーマは OS の設定（`prefers-color-scheme`）に従う
- **管理 UI の言語は cookie に保存し、切り替えは POST にする**: 言語は切り替えで保存した cookie、`Accept-Language`、英語の順に決める。cookie は値が秘密ではないので署名せず（起動ごとの `secret_key_base` で署名すると再起動で読めなくなる）、平文 HTTP の LAN のアドレスでも保存されるよう `Secure` を付けない。承認ページを別のサイトから開いても選んだ言語で出すよう `SameSite=Lax` にする。切り替えは状態を変えるので POST にし、ほかの POST と同じ CSRF の検査の下に置く。戻り先はページの種類から決まるパスをフォームで送り、サーバーがセグメントから組み立て直すので、別のサイトへは戻らない。文言は言語ごとに `Message` のすべての値を網羅する `case` で持ち、片方の訳が無いとビルドが通らない。管理 UI の外から文字列で届く理由（バンカー、アカウントストア、設定、プラグイン）は訳さずに英語のまま出し（設定、DB、プラグインの理由はログと同じ文である）、日本語のページでは何ができなかったかを日本語で前に置く
- **管理 UI は既定でループバックのみ**: ダッシュボードには secret 入りの `bunker://` URI が載るため、既定 (`ADMIN_BIND=127.0.0.1`) では LAN に露出しない。Docker はホストの iptables を直接操作するので、ポートを公開したうえでファイアウォールに頼る形は避け、compose 側でホストのループバックにだけ公開している
- **秘密鍵は POST の応答でだけ表示する**: 鍵の生成は登録と分けた 2 段で、サーバーは生成した鍵を一時的にも保持しない。鍵はブラウザーとの間を POST の本文と、その応答の本文だけで往復し、クエリー文字列にもリダイレクト先にもログにも載らない。再表示は管理パスワードを再入力した POST だけで、GET で秘密鍵を返す経路は無い。再入力の照合は Basic 認証と同じ定数時間の比較で、ログには npub だけを出す
- **登録時の表示は手続きの中で 1 回**: 「登録の直後に 1 回」という方針を「登録の手続きの中で 1 回、POST の応答でだけ」と読んでいる。nsec を貼り付けた登録では登録の後の完了ページで、生成では登録の前の確認ページで表示し、生成した鍵の登録の後には表示しない。反映されたか分からない応答（202）でも表示しない。生成と登録を 1 回の POST にしないのは、再読み込みの再送で別の鍵のアカウントが登録されるのを防ぐためである
- **再表示のページは履歴から再送できる**: 再表示のページで再読み込みするか、戻る操作で戻ると、ブラウザーは保存したパスワードごと POST を再送でき、nsec が再び表示される（そのたびに `revealed the private key of <npub>` の行が出る）。表示の後はタブを閉じること。署名付きのトークンで塞がないのは、再送できるのが Basic 認証の資格情報を覚えている同じタブだけで、その画面の前にいる者はダッシュボードの secret 入りの URI にも削除にも操作 1 回で到達できるからである
- **パスワード管理機能に頼らない**: nsec と管理パスワードの欄には `autocomplete="off"` を付けているが、ブラウザーのパスワード管理機能はこれを無視することがある。管理パスワードを保存すると再入力の欄が自動入力されて再入力の意味が薄れ、nsec の欄も保存を促されうる。表示用の欄（接続 URI、nsec）には `name` を付けないので、送信にも入力履歴にも含まれない
- **監視はバンカー自身の NIP-46 通信を処理しない**: NIP-01 のフィルターには kind の否定が無いため、`PUBKEYS` に署名者を含めて `RELAY_URL` と `BUNKER_RELAY_URL` を同じリレーにすると、バンカーの応答（kind 24133）が監視の購読にも届く。これはプラグインに渡す前に落とすので、コンソールにも `events` テーブルにも NIP-46 の往復は現れない（kind 24133 は NIP-01 上リレーが保存しない想定のイベントで、保存する意味も無い）
- **監視の重複排除は世代式スライディングウィンドウ**: 複数リレーが同じイベントを配送するため、直近のイベント id（上限 4096〜8192 件）を覚えてプラグインには 1 回だけ渡す。再接続時のストアドイベント再配送もこれで吸収する
- **サイナー鍵 = ユーザー鍵**: 仕様で許可されている。別鍵にすると再起動で URI が無効化されるため v0 では同一にしている
- **secret は再利用可**: 仕様は single-use だが、セッションがインメモリのため再起動でオンボーディングが壊れないよう、正しい secret を知るクライアントの接続を許可する。secret はアカウントごとに暗号化して保存するので、再起動しても接続 URI は変わらない
- **接続の承認は auth_url フロー**: secret の一致しない `connect` は、管理 UI が有効なら承認待ちにして `auth_url` 応答（`result` が `"auth_url"`、`error` が承認ページの URL）を返し、承認された時点で元のリクエストと同じ id で本来の応答を送る。判断も応答イベントの組み立ても純粋なエンジンに置き、承認トークンの乱数と現在時刻は actor が注入する。管理 UI が無効なら承認する手段が無いので、従来どおり `invalid secret` で拒否する
- **セッションと承認待ちはインメモリ**: 再起動するとクライアントは再 `connect` が必要（secret 再利用可なので実害は小）。承認待ちも同じく永続化せず、10 分で失効する。承認済みのクライアントは secret 無しで `connect` し直しても承認を求められないが、再起動後は改めて承認が要る
- **バンカー actor は起動時刻より古いリクエストを処理しない**: リプレイ防止の `seen` ウィンドウはバンカー actor の中にしかなく、プロセスの再起動でも actor の再起動でも空になる。kind 24133 を保存するリレー（NIP-01 上は保存しない想定だが strfry などは保存する）が再購読で処理済みのリクエストを再配送すると、記憶していないため新規として実行し、`sign_event` をやり直して応答を再発行したり、取り消したはずのセッションを復活させたりしてしまう。そこで actor は起動時刻を刻み、`created_at` がそれより古いリクエストをエンジンが落とす。この起点は actor が生きているあいだ動かないので、切断していた間に届いたリクエストを購読の猶予（`since = 現在時刻 - 60 秒`）で拾い直す動きは従来どおり働く。`created_at` は秒までしか持たないため判定は秒単位で、起動と同じ秒のリクエストは通す（起動直後に届いた正当なリクエストを落とすと、クライアントは応答を待ったまま失敗するため）。停止から再起動までが同じ秒に収まった場合、その秒のリクエストは再実行されうる。さらに、判定に使うのはクライアントが自己申告する `created_at` なので、時計が進んでいるクライアントには保護が効かない。ずれが D 秒なら、リレーが再配送しうる `D + 60` 秒のうち `D` 秒ぶんの再起動では再実行が起きる（上限は受付ウィンドウの ±10 分）。副作用として、時計が遅れているクライアントのリクエストは、actor の起動直後、そのずれの秒数ぶんだけ弾かれうる
- **認証の多層防御**: NIP-44 の復号成功が送信者認証になる + 受信イベントの BIP-340 署名検証（リレーの接続のプロセスで行い、バンカー actor には検証を通ったイベントだけが届く） + `created_at` の ±10 分チェック + イベント ID の重複排除
- `nostrconnect://`（クライアント起点フロー）/ NIP-04 / `switch_relays` は未対応

### vendor/stratus について

WebSocket クライアントの stratus は、hex で公開された版を改変して `vendor/stratus/` に同梱している。
改変の内容と理由、上流の版と tar の SHA-256、hex 版に戻す条件は `vendor/stratus/PATCH.md` にある。
CI の `vendor-stratus` ジョブが、上流の tar にパッチを当てた結果と `vendor/stratus/` が一致することを確かめる。

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
