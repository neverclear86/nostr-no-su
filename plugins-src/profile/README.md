# profile

登録アカウントの現在のプロフィール（kind 0）を管理 UI に出す外部プラグイン。

`examples/plugins/` の 2 つが仕様の例示なのに対し、こちらは**第一級の同梱プラグイン**である。DB も監視の保持も持たず、ページを開いたときに、キャッシュに無いアカウントの最新の kind 0 を本体の複数の公開鍵の取得の口（[プラグイン API v1](../../docs/plugin-api.md) 第 14.10 節）でリレーからまとめて取る。プロフィールの編集もでき、送信は本体の送信の口（同第 14.1 節）に委ねる（秘密鍵には触れない）。

仕様の全文は [プラグイン API v1](../../docs/plugin-api.md) を参照すること。

## ビルド

このプラグインは docker イメージに同梱されており（`/app/plugins/profile`）、同梱版を使うだけならビルドは要らない。以下は改造版のための手順である。

<!-- この節の最初の sh ブロックは、CI（.github/workflows/ci.yml の plugin-readme-build）がリポジトリーのルートでそのまま実行する。 -->

**本体と同じイメージでビルドすること。** 理由は 2 つある。

- **OTP が違う BEAM はローダーが `badfile` で拒否する。**
- **ホスト環境でビルドすると同梱物が別物になる。** ホストに elixir があると混入する経緯は [`event_logger` の README](../event_logger/README.md) の同節を参照。

```sh
mkdir -p plugins/profile
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$PWD/plugins-src/profile:/src:ro" \
  -v "$PWD/plugins/profile:/out" \
  ghcr.io/gleam-lang/gleam:v1.17.0-erlang-alpine \
  sh -c 'cp -r /src /tmp/work && rm -rf /tmp/work/build && cd /tmp/work && gleam deps download \
         && gleam export erlang-shipment && cp -r build/erlang-shipment/. /out/'
chmod -R a+rX plugins
```

`/src` は読み取り専用でマウントするので、一度 `/tmp/work` へ複写してからビルドする。**複写したあとに `build/` を消すのを忘れないこと。** ローカルで一度ビルドしていると、Elixir 一式を含むホスト側の成果物がそのままコンテナーへ持ち込まれる。ローカルの `gleam export erlang-shipment` はスモークテストであって、その出力を `plugins/` に置いてはならない。

コンテナーは `--user` でホストの利用者として動かす。root で動かすと成果物が root 所有になり、非 root の利用者が続く `chmod` を実行すると EPERM で止まる。この手順は、コンテナーの uid がホストの uid と一致する構成（rootful の docker、Docker Desktop）を前提にする。この利用者はイメージの `/` に書けない（`HOME` も `/` になる）ので、複写先を誰でも書ける `/tmp` の下（`/tmp/work`）に置き、`gleam deps download` がキャッシュを置く `HOME` を `/tmp` にする。

## 置き方

`gleam export erlang-shipment` の出力を**そのまま**置く。ローダーは `<name>/<app>/ebin` のレイアウトを受け付けるので、flatten してはならない。

```
plugins/profile/profile/ebin/profile.beam   -- エントリー
plugins/profile/entrypoint.sh                -- ローダーは黙って無視する
```

エントリーモジュール名はディレクトリー名と一致させる（`plugins/profile` → モジュール `profile`）。同梱の `docker-compose.yml` は `./plugins` を `/plugins` に読み取り専用でマウントし、`PLUGIN_DIR=/app/plugins:/plugins` を渡す。同名のプラグインはイメージの `/app/plugins` の同梱版が勝つので、ここへ置いた改造版を読ませるには `PLUGIN_DIR=/plugins` を渡す。コンテナーは非 root（uid 1000）で動くため、ホスト側は誰でも読める権限にしておくこと。

## 設定

このプラグイン固有の環境変数は無い。

## 画面

`/plugins/profile/profile` に登録アカウントごとの節が出る。取得できないアカウント（kind 0 が無い）は未設定として空欄で出す。取得に失敗したアカウントは、その節にだけ理由を出し、他のアカウントの表示は止めない。`picture`・`banner` の画像は URL を管理 UI に渡すだけで、実体は管理者のブラウザーが直接取りに行く（本体は中継しない。[プラグイン API v1](../../docs/plugin-api.md) 第 13.4 節）。各節の末尾には 8 項目を編集する `form`（`name` / `display_name` / `about` / `picture` / `banner` / `nip05` / `website` / `lud16`、送信ボタンは `Save`）があり、取得に失敗したアカウントには出ない。送信の成否は同じ節の `alert` に出る。出る内容は最大 60 秒前に取得したものである（「取得」の節）。

## 取得

ページを開くと、キャッシュに無いアカウントの kind 0 を本体の `fetch_events`（[プラグイン API v1](../../docs/plugin-api.md) 第 14.10 節）の 1 回の呼び出しでまとめて取る。本体は監視の用途のリレー 1 本につき接続を 1 本開いて REQ を 1 件だけ送るので、1 回の描画で開く接続はアカウントの件数によらずリレーの本数までになる。

取得できた内容（kind 0 が無かったことを含む）は 60 秒キャッシュし、その間にページを開き直してもリレーには問い合わせない。他のクライアントでの変更は最大 60 秒遅れて出る。取得に失敗したアカウントはキャッシュせず、次に開いたときに取り直す。キャッシュは揮発で、本体を再起動すると消える。

`Save` の送信に成功すると、送った kind 0 をそのままキャッシュに入れる。送信後のリダイレクトで開き直したページは、リレーに問い合わせずに送った内容を出す。

## 更新

`Save` を押すと、送信の直前に対象アカウントの kind 0 をキャッシュを使わずに取得し直し、フォームの 8 項目だけを差し替えて送る。未知のキーはそのまま残る。空欄のまま送った項目はキーごと削除され、そのプロフィールから消える。取得に失敗した節には `form` を出さない（現在のプロフィールが分からないまま編集させないため）。送信したイベントは、登録アカウントの監視の購読で戻ってくる（[プラグイン API v1](../../docs/plugin-api.md) 第 14.6 節）。

## 開発

```sh
cd plugins-src/profile
gleam deps download
gleam build --warnings-as-errors
gleam test          # DB は使わない
gleam format --check src test
```

**`manifest.toml` はコミットする。** 本体と共有するパッケージ（`gleam_stdlib` / `gleam_json`）は、影に入る側なので**本体の版で実行される**。版がずれても読み込み時には何も起きず、実行時に `undef` で壊れる。`gleam.toml` の制約を揃えるだけでは一致しない（`gleam deps download` は本体と独立に解決する）ため、一致は CI が必須チェックとして検査する。**版を上げるときは本体と同時に上げること。**
