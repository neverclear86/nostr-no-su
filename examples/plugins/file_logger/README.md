# file_logger

プラグインローダーの動作確認に使う最小のプラグイン。受信したイベントを 1 件 1 行でファイルへ追記する。

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

## 出力

既定の出力先は `/tmp/nostr-no-su-events.log`（プラグインディレクトリーは読み取り専用なのでそこには書けない）。`FILE_LOGGER_PATH` で変更できる。

```sh
docker compose exec nostr-no-su cat /tmp/nostr-no-su-events.log
```

1 行は `<id> <kind> <content>` の形になる。
