# 運用: バックアップと復旧

この文書は、リポジトリ同梱の `docker-compose.yml`（同梱の Postgres を使う構成）を前提にする。
失うと戻らないものが 2 つある。DB そのものと、DB の暗号文を復号するマスターキーである。

## 守るもの

| 対象 | 中身 | 失ったとき |
| --- | --- | --- |
| `bunker_accounts` | 公開鍵、ラベル、暗号化した秘密鍵と接続 secret | 全アカウントを登録し直す必要があり、`bunker://` URI の secret も変わる |
| `monitor_resume` | 監視の購読の再開点（リレーごとの `since`） | 失うと次の購読が保存済みのイベントをすべて求め、`dedup` のウィンドウを超える分がプラグインへもう一度届く |
| `relays` | 登録したリレーの URL と用途（監視・バンカー） | 失うと `bunker://` URI の `relay=` が変わり、下の「復旧後の確認」の 2 が一致しなくなる |
| `schema_version` | 本体の移行の版 | データの表（`bunker_accounts`、`monitor_resume`、`relays`）と対で戻す必要がある。片方だけ戻すと版とデータが食い違う |
| `events` | `event_logger` が保存したイベント（このプラグインを置いたときだけ存在する） | プラグインが保存した履歴が失われる |
| `event_logger_schema_version` | `event_logger` の移行の版 | `events` と対で戻す必要がある |
| マスターキー | `.env` の `ACCOUNT_MASTER_KEY`、または `ACCOUNT_MASTER_KEY_FILE` が指すファイル（README の例では `secrets/account_master_key`） | DB のどの表にも無い。失うと `bunker_accounts` の秘密鍵と secret を復号できない |

## マスターキーの保管

- ダンプの `encrypted_privkey` と `encrypted_secret` はマスターキーで暗号化されている（[設計上の判断と既知の制約](design-decisions.md)）。マスターキーを失うとダンプからは戻せない。マスターキーは自動生成されず、ほかに写しは無い。
- ダンプとマスターキーが揃うと全アカウントの秘密鍵が漏れる。そのため両者は別の場所に置く（例: ダンプはバックアップ先のストレージ、マスターキーはパスワードマネージャー）。
- 別のマスターキーで起動すると、行は消えずに飛ばされ、ログが `[bunker] skipped account <pubkey>: <理由>` と `loaded 0 of N account(s)` になる。この場合は正しいマスターキーに直して読み直させれば戻る。**管理 UI から同じ鍵を登録し直そうとしない**（`account is already registered` になる）。

ファイルで渡す構成では、そのファイルと `docker-compose.override.yml` の写しをダンプと別の場所に保つ。作り方と権限は [README](../README.md) の「秘密をファイルで渡す」にある（ホストの uid が 1000 でなく `chown` した場合は、写しを取るのに `sudo` が要る）。

## バックアップ

```sh
docker compose exec -T postgres pg_dump -U nostr -d nostr_no_su -Fc > nostr-no-su-$(date +%Y%m%d).dump
```

`-T` は端末を割り当てないための指定である。端末から `-T` を付けずに実行すると TTY が割り当てられ、そのダンプは `pg_restore` が `could not read from input file: end of file` で読めない。

その時点のアカウント数を、ダンプと一緒に控える（下の「復旧後の確認」の 1 で比べる）。

```sh
docker compose exec -T postgres psql -At -U nostr -d nostr_no_su -c "SELECT count(*) FROM bunker_accounts"
```

取ったダンプの中身は次で確かめる。プラグインを置いていなければ 5 行、`event_logger` を置いていれば 7 行の `TABLE DATA` が出る。

```sh
docker compose exec -T postgres pg_restore -l < <ファイル> | grep 'TABLE DATA'
```

版を上げる前にも取る。戻す移行は無いので、移行後に問題が見つかっても、移行前のダンプが無ければ戻せない（[設計上の判断と既知の制約](design-decisions.md)）。

ダンプは暗号文を含むので、ダンプ自体も他人に読めない場所に置く（`chmod 600`）。

`PLUGIN_EVENT_LOGGER_DATABASE_URL` を別のデータベースに向けた構成では、そのデータベースも同じ形で取る。

## 復旧

始める前に、同じマスターキーを含む `.env` を用意する（マスターキーをファイルで渡す構成なら同じ秘密のファイルと `docker-compose.override.yml`。ファイルの権限は [README](../README.md) の「秘密をファイルで渡す」）。リレーはダンプの `relays` に入っているので、同じダンプなら `bunker://` URI の `relay=` も変わらない。

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

## 関連

マスターキーを交換する手順はまだ無い。
