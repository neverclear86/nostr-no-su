# counter

状態を持つプラグインの最小の例。受信したイベントの件数を gen_server で数え、その gen_server を任意エクスポート `plugin_children/0` で本体のスーパービジョンツリーに載せる。

Gleam プロジェクトにせず Erlang 1 ファイルにしているのは、ネストしたビルドディレクトリーと依存管理を本体のリポジトリーへ持ち込まないためである。`examples/` に置いてあるので、`gleam build` / `gleam test` のコンパイル対象にもならない。

同じディレクトリーの [file_logger](../file_logger/README.md) とは役割が違う。あちらは状態を持たないプラグインの例で、`handle_event/2` の中だけで処理が完結する。こちらは呼び出しをまたいで状態を保つ例である。

子仕様の書き方と本体側の検証は [プラグイン API v1](../../../docs/plugin-api.md) の第 5 章を参照すること。

このプラグインは設定を必要としないので、`plugin_children/0`（アリティ 0）と `handle_event/1` のままである。**プラグイン固有の設定（第 6 章）が入っても、既存のプラグインが無変更で読み込まれること**を示す例でもある。

## 要点

- 子プロセスの登録名（`counter_store`）は VM 全体で一意でなければならない。プラグイン名を接頭辞にしてある。
- 登録は `start_link/0` の中で行う。本体は名前を作らず、渡しもしない。
- `handle_event/1` は `gen_server:call/2` で送る。`cast` は宛先が居なくても成功するため、子が居なくなったことがランナーに失敗として見えなくなる。

## ビルド

**本体と同じイメージでビルドすること。** OTP が違うとローダーが `badfile` で拒否する。

```sh
mkdir -p plugins/counter/ebin
docker run --rm \
  -v "$PWD/examples/plugins/counter:/src:ro" \
  -v "$PWD/plugins/counter/ebin:/out" \
  ghcr.io/gleam-lang/gleam:v1.17.0-erlang-alpine \
  erlc -o /out /src/src/counter.erl
chmod -R a+rX plugins
```

## 置き方

エントリーモジュール名はディレクトリー名と一致させる。上のコマンドは次の形を作る。

```
plugins/counter/ebin/counter.beam
```

同梱の `docker-compose.yml` は `./plugins` を `/plugins` に読み取り専用でマウントし、`PLUGIN_DIR=/plugins` を渡す。コンテナーは非 root（uid 1000）で動くため、ホスト側は誰でも読める権限にしておくこと。

## 確認

起動ログに次の行が出れば読み込まれている。

```sh
docker compose logs nostr-no-su | grep plugin_loader
```

```
[plugin_loader] loaded 1 plugin(s) from /plugins: counter
```

イベントを受信すると、件数が 1 行ずつ出る。

```sh
docker compose logs -f nostr-no-su | grep '\[counter\]'
```

```
[counter] 1 events (last 556f29ae…2385)
```

この行は `counter` 自身が `io:format/2` で出しているもので、本体のログ接頭辞（`[plugin counter]`）とは別物である。子の起動に失敗したときや、子を諦めたときの行は本体が `[plugin counter]` の接頭辞で出す。
