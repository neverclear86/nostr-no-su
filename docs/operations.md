# 運用

この文書は、起動時のログの読み方、バックアップ、版の更新、復旧、マスターキーの交換、リソースの目安をまとめる。リポジトリ同梱の `docker-compose.yml`（同梱の Postgres を使う構成）を前提にする。公開イメージで動かしている場合は、以下の `docker compose ...` をすべて `docker compose -f docker-compose.release.yml ...` と読み替える（`-f` を付けると `docker-compose.override.yml` は自動では重ならないので、使っているときは `-f docker-compose.release.yml -f docker-compose.override.yml` と 2 つ並べる。[設定](configuration.md) の「docker compose の構成」）。
失うと戻らないものが 2 つある。DB そのものと、DB の暗号文を復号するマスターキーである。

## 起動時のログ

起動するとバンカーはテーブル `bunker_accounts` を作り（すでにあれば何もしない）、保存されたアカウントを読み込んで `[bunker] loaded N account(s)` を出す。起動ログには秘密鍵も `bunker://` URI も出さない。

いずれかが未設定か不正なら、`[main] cannot start: <理由>` を 1 行出して終了コード 1 で終了する（同梱の compose は `restart: unless-stopped` なので、docker が間隔を延ばしながら再起動を繰り返し、そのたびに同じ行が出る）。DB に記録されたスキーマの版がビルドより新しいときは、`[main] cannot continue: database schema version N is newer than this build supports (up to version M)` を 1 行出して終了コード 1 で終了する（[設計上の判断と既知の制約](design-decisions.md) の「スキーマの版は前向きにだけ自動で進める」）。同じ DB を別のインスタンスが使っているときは、`[main] cannot continue: another instance is using this database (advisory lock 7237235 is held by another session)` を 1 行出して終了コード 1 で終了する（[設計上の判断と既知の制約](design-decisions.md) の「同じ DB に対して動けるのは 1 インスタンスだけである」）。DB に到達できないときはバンカーのサブツリーは起動したまま、`[bunker] account store unavailable: database is unreachable or rejected the connection; retrying in 5000ms` を 1 行出して読み込みを再試行し（間隔は失敗のたびに倍に延び、2 分で頭打ちになる）、戻れば `account store is back; loaded N account(s)` を出す。この間もプラグインは止まらない。リレーの接続は DB から行を読めた後に開く。パスワードやデータベース名の誤りも接続の段階で拒否されるので同じ行になり、理由が変わらない限り 2 行目は出ない。DB が読み込みの期限までに応答しないか、途中で接続が切れたときは、理由が `database did not answer in time or the connection was lost` の行になる。この行が出たままなら、DB の停止だけでなく `DATABASE_URL` の資格情報とデータベース名も確かめること。

登録で「このアカウントはすでに登録されています。」（`account is already registered`）と出るのにダッシュボードのアカウントの節にそのアカウントが無いときは、起動時の読み込みで飛ばされた行が `bunker_accounts` に残っている（ダッシュボードの「読み込めなかったアカウント」（`Unreadable accounts`）のカードに出る。ログは `[bunker] skipped account <pubkey>: <理由>`）。別のマスターキーで暗号化された行は、そのマスターキーでなければ復号できない。その鍵を使わないと決めたときは、その行の「削除」（`Delete`）から消してから登録し直す。「pubkey の列を読めない行です。」で始まる行は pubkey を読めないため画面からは消せず、DB から直接消す（docker compose では `docker compose exec postgres psql -U nostr -d nostr_no_su -c "DELETE FROM bunker_accounts WHERE pubkey = '<pubkey 列の値>'"`）。

空の DB でもリレー 0 件で起動する。不正な URL や、`observe` と `bunker` がどちらも false の行は起動を止めずに `[relay <URL>] skipped registered relay: <理由>` の Warning を出して飛ばす。

ログは 1 行ずつ `<時刻 UTC> <水準> <本文>` の形で出る（水準と docker のログの打ち切りは [設定](configuration.md) の「docker compose の構成」）。この文書で引用する行はこの先頭を省いて書いている。

## 守るもの

| 対象 | 中身 | 失ったとき |
| --- | --- | --- |
| `bunker_accounts` | 公開鍵、ラベル、暗号化した秘密鍵と接続 secret | 全アカウントを登録し直す必要があり、`bunker://` URI の secret も変わる |
| `bunker_sessions` | 承認済みのクライアントのセッション（署名者、クライアント、許可した権限、最終利用の時刻） | 失うと承認済みだったクライアントの要求が `unauthorized: send connect first` で拒否され、そのクライアントは接続をやり直す（承認を経る URI で接続したクライアントは承認もやり直す） |
| `bunker_pending` | 承認待ちの接続要求 | 失うと承認待ちだった要求が消え、そのクライアントは接続をやり直す。承認待ちは 10 分で失効するので、失って困るのは取った時点で待っていた分だけである |
| `monitor_resume` | 監視の購読の再開点（リレーごとの `since`） | 失うと次の購読が保存済みのイベントをすべて求め、`dedup` のウィンドウを超える分がプラグインへもう一度届く |
| `plugin_resume` | プラグインごとの再開点（プラグイン名ごとの `since`） | 失うとそのプラグインの再開点が無い状態に戻り、復帰時の取り直しの購読も定義されない |
| `relays` | 登録したリレーの URL と用途（監視・バンカー） | 失うと `bunker://` URI の `relay=` が変わり、下の「復旧後の確認」の 2 が一致しなくなる |
| `schema_version` | 本体の移行の版 | データの表（`bunker_accounts`、`monitor_resume`、`bunker_sessions`、`bunker_pending`、`relays`、`plugin_resume`）と対で戻す必要がある。片方だけ戻すと版とデータが食い違う |
| `events` | `event_logger` が保存したイベント（docker イメージに同梱されているので、compose の既定の構成では常に存在する） | プラグインが保存した履歴が失われる |
| `monitored_accounts` | `event_logger` が保存の対象とするアカウント（行が 0 件なら全アカウントが対象） | 失うと保存の対象が全アカウントに戻る |
| `event_logger_schema_version` | `event_logger` の移行の版 | `events`・`monitored_accounts` と対で戻す必要がある |
| マスターキー | `.env` の `ACCOUNT_MASTER_KEY`、または `ACCOUNT_MASTER_KEY_FILE` が指すファイル（[設定](configuration.md) の「秘密をファイルで渡す」の例では `secrets/account_master_key`） | DB のどの表にも無い。失うと `bunker_accounts` の秘密鍵と secret を復号できない |

## マスターキーの保管

- ダンプの `encrypted_privkey` と `encrypted_secret` はマスターキーで暗号化されている（[設計上の判断と既知の制約](design-decisions.md)）。マスターキーを失うとダンプからは戻せない。マスターキーは自動生成されず、ほかに写しは無い。
- ダンプとマスターキーが揃うと全アカウントの秘密鍵が漏れる。そのため両者は別の場所に置く（例: ダンプはバックアップ先のストレージ、マスターキーはパスワードマネージャー）。
- 別のマスターキーで起動すると、行は消えずに飛ばされ、ログが `[bunker] skipped account <pubkey>: <理由>` と `loaded 0 of N account(s)` になる。管理 UI のダッシュボードにも「読み込めなかったアカウント」（`Unreadable accounts`）のカードとして出る。この場合は正しいマスターキーに直して読み直させれば戻る。**管理 UI から同じ鍵を登録し直そうとしない**（「このアカウントはすでに登録されています。」（`account is already registered`）になる）。

ファイルで渡す構成では、そのファイルと `docker-compose.override.yml` の写しをダンプと別の場所に保つ。作り方と権限は [設定](configuration.md) の「秘密をファイルで渡す」にある（ホストの uid が 1000 でなく `chown` した場合は、写しを取るのに `sudo` が要る）。

## バックアップ

```sh
docker compose exec -T postgres pg_dump -U nostr -d nostr_no_su -Fc > nostr-no-su-$(date +%Y%m%d).dump
```

`-T` は端末を割り当てないための指定である。端末から `-T` を付けずに実行すると TTY が割り当てられ、そのダンプは `pg_restore` が `could not read from input file: end of file` で読めない。

その時点のアカウント数を、ダンプと一緒に控える（下の「復旧後の確認」の 1 で比べる）。

```sh
docker compose exec -T postgres psql -At -U nostr -d nostr_no_su -c "SELECT count(*) FROM bunker_accounts"
```

取ったダンプの中身は次で確かめる。compose の既定の構成（同梱の `event_logger` が読まれる）では 10 行、`PLUGIN_DIR=/plugins` や `PLUGIN_DIR=` で同梱版を読み込ませていなければ 7 行の `TABLE DATA` が出る。

```sh
docker compose exec -T postgres pg_restore -l < <ファイル> | grep 'TABLE DATA'
```

版を上げる前にも取る。戻す移行は無いので、移行後に問題が見つかっても、移行前のダンプが無ければ戻せない（[設計上の判断と既知の制約](design-decisions.md)）。

ダンプは暗号文を含むので、ダンプ自体も他人に読めない場所に置く（`chmod 600`）。

`PLUGIN_EVENT_LOGGER_DATABASE_URL` を別のデータベースに向けた構成では、そのデータベースも同じ形で取る。

## 更新

新しい版に上げる前にダンプを取る（上の「バックアップ」。戻す移行は無いため）。公開イメージで動かしている構成では次で入れ替える。

```sh
docker compose -f docker-compose.release.yml pull
docker compose -f docker-compose.release.yml up -d
```

`.env` の `NOSTR_NO_SU_VERSION` で版を固定している構成では、`pull` はその値のタグしか取らないので、先に値を上げてから同じ 2 つを実行する。clone してソースから動かしている構成では `git pull` の後に `docker compose up -d --build` を実行する。

上げた後の確認は下の「復旧後の確認」の 1 と 3 と同じで、`[bunker] loaded N account(s)` の `N` が上げる前と同じであることと、`bunker://` URI でクライアントから署名できることを見る。DB の移行は起動時に自動で進む。記録された版がビルドより新しいときは `[main] cannot continue: database schema version N is newer than this build supports (up to version M)` を出して終了し、compose が再起動を繰り返すたびに同じ行が出るので、前の版のイメージに戻す。

新しい版が `docker-compose.release.yml` や `.env.example` を変えていることがある（[変更履歴](../CHANGELOG.md) の「変更」と、**破壊的変更** の行）。公開イメージで動かしている構成では、`pull` の前に新しい版の 3 つのファイルを取り直し、`setup-env.sh` を実行し直す。`setup-env.sh` は既にある `.env` の値（マスターキーを含む）を変えず、`.env.example` に増えた変数だけを既定値のまま末尾に足す（[設定](configuration.md) の「`.env` と `setup-env.sh`」）。

```sh
base=https://raw.githubusercontent.com/neverclear86/nostr-no-su/v<version>
curl -fsSLO "$base/docker-compose.release.yml"
curl -fsSLO "$base/.env.example"
curl -fsSLO "$base/setup-env.sh"
sh setup-env.sh
```

データは compose の `postgres-data` volume にあり、`pull` と `up -d` は volume に触れない。volume の名前は compose のプロジェクト名（既定はディレクトリーの名前）で決まるので、ディレクトリーの名前を変えたり別のディレクトリーで起動したりすると、空の volume で新しく始まる（古い volume は `docker volume ls` に `<旧プロジェクト名>_postgres-data` として残る。戻すときはディレクトリーの名前を戻すか、`docker compose -p <旧プロジェクト名> ...` で起動する）。`docker compose down -v` だけが volume を消す。

同梱の Postgres はメジャー版（`postgres:17`）を固定している。Postgres のメジャー版を上げるとデータディレクトリーの形式が変わり、`postgres-data` volume をそのままでは起動できない。この更新はダンプと復元を伴う手順として `CHANGELOG.md` に **破壊的変更** で書き、この文書に手順を足す（[貢献の手引き](../CONTRIBUTING.md) の「版数」）。

## 復旧

始める前に、同じマスターキーを含む `.env` を用意する（マスターキーをファイルで渡す構成なら同じ秘密のファイルと `docker-compose.override.yml`。ファイルの権限は [設定](configuration.md) の「秘密をファイルで渡す」）。リレーはダンプの `relays` に入っているので、同じダンプなら `bunker://` URI の `relay=` も変わらない。

新しいホストへ移して復旧するときは、先に旧ホストのアプリを止める。advisory lock は同じ `DATABASE_URL` の DB に対してしか働かないため（[設計上の判断と既知の制約](design-decisions.md) の「同じ DB に対して動けるのは 1 インスタンスだけである」）、新旧ホストがそれぞれ同梱の Postgres を持つ構成では DB が別になり、ロックは効かず、旧ホストのアプリが動いたままだと同じアカウントに 2 つのバンカーが応答してしまう。外部の Postgres を新旧ホストで共有する構成なら、advisory lock により 2 台目は `[main] cannot continue: another instance is using this database (advisory lock 7237235 is held by another session)` で止まる。

新しいホストでは volume も起動中のアプリも無いため、手順 1 と 2 は不要である。同じホストで戻すときは次の順で進める。

1. アプリを止める。

   ```sh
   docker compose stop nostr-no-su
   ```

2. volume を空にする。**表が既にある DB には戻せない。** `down -v` はアカウントを含む volume を消すので、実行の前にダンプの `pg_restore -l` で中身を確かめておくこと。

   ```sh
   docker compose down -v
   ```

3. Postgres だけを起動する。

   ```sh
   docker compose up -d --wait postgres
   ```

4. ダンプから戻す。

   ```sh
   docker compose exec -T postgres pg_restore -U nostr -d nostr_no_su --no-owner --exit-on-error --single-transaction < <ファイル>
   ```

   `--single-transaction` により、途中で失敗しても表は残らない。失敗したときは原因を直し、この手順からやり直せばよい。

5. アプリを起動する。

   ```sh
   docker compose up -d
   ```

## 復旧後の確認

1. `docker compose logs nostr-no-su` に `[bunker] loaded N account(s)` が出て、`N` がバックアップの時点に控えたアカウント数と一致すること。`of` の形（`loaded N of M account(s)`、飛ばした行がある）になっていないこと。
2. 管理 UI のダッシュボードの `bunker://` URI がバックアップ前と同じであること。URI は公開鍵、リレー、secret だけで決まる。secret は DB の `encrypted_secret` から復号するので、同じダンプと同じマスターキーなら変わらない。リレーもダンプの `relays` から決まるので、同じダンプなら `relay=` も変わらない。
3. その URI でクライアントから署名できること。

`loaded 0 of N account(s)` や `skipped account` が出たときは、DB の行を消さずに次で戻す。マスターキーの渡し方で操作が異なる。

- `.env` で渡す構成: `ACCOUNT_MASTER_KEY` を直して `docker compose up -d` し直す（値が変わるとコンテナーが作り直される）。
- ファイルで渡す構成: ファイルの中身を直しても compose の設定は変わらないので `docker compose up -d` では作り直されない。ファイルは起動時に読むので `docker compose restart nostr-no-su` で読み直させる。

## マスターキーの交換

`ACCOUNT_MASTER_KEY` を別の値に変えると、それまでのキーで暗号化した行はすべて復号できなくなる。暗号文を別のキーで暗号化し直す機能は持たないため、交換は控えた nsec でアカウントを登録し直す形で行う。

1. 交換の前に、全アカウントの nsec を控える。ダッシュボードの各行の「秘密鍵を表示」（`Show private key`）で管理パスワードを再入力して表示する。控え忘れに気づいたときは、手順 3 で行を消す前に、以前の `ACCOUNT_MASTER_KEY` に戻して起動し直せば表示して控えられる。
2. 新しいマスターキーを `openssl rand -hex 32` で作って渡し直し、起動し直す。マスターキーは起動時に読むので再起動が要る。docker compose では、`.env` の値を変えたときは `docker compose up -d`、ファイルの中身を変えたときは `docker compose restart nostr-no-su` で読み直させる。起動すると全行が飛ばされ、ログに `loaded 0 of N account(s)` と `skipped account <pubkey>: <理由>` が出て、ダッシュボードに「読み込めなかったアカウント」（`Unreadable accounts`）のカードが出る。
3. そのカードの各行の「削除」（`Delete`）から、飛ばされた行を消す。`pubkey` 列を読めない行があるときは、「このアカウントはすでに登録されています。」（`account is already registered`）について述べた上の段落にあるとおり DB から直接消す。
4. アカウントの節の「追加」（`Add`）から控えた nsec で登録し直す。飛ばされた行が残っていると「このアカウントはすでに登録されています。」（`account is already registered`）で拒否されるので、先に消しておく。登録し直したアカウントは、その時点から再起動なしで署名と監視に戻る。

交換で失われるものは次のとおりである。接続 secret は登録のたびに新しい値が作られるので、secret 入りの `bunker://` URI が変わり、クライアントにはダッシュボードから新しい URI を貼り直す（古い URI での接続は承認なしには通らない）。「secret を再生成」（`Rotate secret`）とは違い、承認済みのセッションと承認待ちの接続要求も行の削除で一緒に消えるので、承認を経るクライアントは接続と承認をやり直す。ラベルも行と一緒に消えるので、登録し直すときに入れ直す（消す前ならカードに出ている）。

リレーの登録、監視の再開点、プラグインが保存したイベントはマスターキーに依らず変わらない。同じ nsec で登録し直せば公開鍵も同じなので、`bunker://` URI で変わるのは `secret=` だけである。

## リソース

小さな VPS や Raspberry Pi で動かすときの目安として、x86_64 のホスト（docker 29.6）でリポジトリの `docker-compose.yml` を起動して測ったメモリ（`docker stats` の `MEM USAGE`）を次に挙げる。起動直後は起動の約 1 分後、アカウントありはリレー 1 つ（バンカーと監視の両方）と 5 アカウントを登録した約 1 分半後の値である。

| 状態 | アプリ | Postgres |
| --- | --- | --- |
| 起動直後 | 81 MiB | 35 MiB |
| 5 アカウントとリレー 1 つ | 83 MiB | 36 MiB |

動かしている構成の値は `docker stats --no-stream` で確かめられる。起動直後の Postgres のデータベースの大きさは約 8 MB である。`event_logger` が保存する `events` テーブルには保持期間が無く、保存の対象にしたアカウントのイベントが届くたびに増え続ける。`events` の大きさは次で確かめられる。

```sh
docker compose exec -T postgres psql -U nostr -d nostr_no_su -c "SELECT pg_size_pretty(pg_total_relation_size('events'))"
```
