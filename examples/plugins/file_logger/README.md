# file_logger

プラグインローダーの動作確認に使う最小のプラグイン。受信したイベントを 1 件 1 行でファイルへ追記する。プラグイン固有の設定を受け取る例でもある。

Gleam プロジェクトにせず Erlang 1 ファイルにしているのは、ネストしたビルドディレクトリーと依存管理を本体のリポジトリーへ持ち込まないためである。`examples/` に置いてあるので、`gleam build` / `gleam test` のコンパイル対象にもならない。

`test/support/minimal_plugin.erl` とは役割が違う。あちらは [プラグイン API v1](../../../docs/plugin-api.md) に載せる最小実装例で、本体の ebin に混ぜてコンパイルされるため最初からコードパス上にある（コードパスを足さなくても読めるので、ローダーの検証には使えない）。こちらは「外から持ち込む」側の例である。

## ビルド

**本体と同じイメージでビルドすること。** OTP が違うとローダーが `badfile` で拒否する。

```sh
mkdir -p plugins/file_logger/ebin
docker run --rm \
  -v "$PWD/examples/plugins/file_logger:/src:ro" \
  -v "$PWD/plugins/file_logger/ebin:/out" \
  ghcr.io/gleam-lang/gleam:v1.17.0-erlang-alpine \
  erlc -o /out /src/src/file_logger.erl
chmod -R a+rX plugins
```

## 置き方

エントリーモジュール名はディレクトリー名と一致させる。上のコマンドは次の形を作る。

```
plugins/file_logger/ebin/file_logger.beam
```

同梱の `docker-compose.yml` は `./plugins` を `/plugins` に読み取り専用でマウントし、`PLUGIN_DIR=/plugins` を渡す。コンテナーは非 root（uid 1000）で動くため、ホスト側は誰でも読める権限にしておくこと。

起動ログに次の行が出れば読み込まれている。

```
[plugin_loader] loaded 1 plugin(s) from /plugins: file_logger
```

## 設定

出力先は **`PLUGIN_FILE_LOGGER_PATH` で必ず指定する**（[プラグイン API v1](../../../docs/plugin-api.md) の第 6 章）。プラグイン側に既定値は持たせず、同梱の `docker-compose.yml` が `/tmp/nostr-no-su-events.log` を渡している。**プラグインディレクトリーは読み取り専用でマウントされるので、そこには書けない。** コンテナーの `/tmp` は実行ユーザー（uid 1000）が書ける。

設定が無いとこのプラグインだけが無効になり、理由が 1 行出る。本体の起動と他のプラグインには影響しない。

```
[plugin_loader] file_logger: plugin_children/1 rejected the configuration (path is required); 設定は PLUGIN_FILE_LOGGER_* で渡す
```

エクスポートしているのは `handle_event/2` だけで、`handle_event/1` は持たない。設定が必須のプラグインは、設定を受け取らない `handle_event/1` を正しく書けないためである（既定値に落とすか、落ちるだけの死んだ節を書くしかない）。その代わり、**このプラグインは `handle_event/2` に対応した本体でしか読み込めない。**

子プロセスは持たないが、設定の検査のために `plugin_children/1` をエクスポートし、設定が揃っていれば空のリストを返している。

## 出力

```sh
docker compose exec nostr-no-su cat /tmp/nostr-no-su-events.log
```

1 行は `<id> <kind> <content>` の形になる。
