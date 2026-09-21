FROM ghcr.io/gleam-lang/gleam:v1.17.0-erlang-alpine@sha256:e0b22aa9dc1c38ae564106e1d6c97c11caf592b25736f53a62900eccd79827cd AS toolchain

FROM toolchain AS build
WORKDIR /build
# ソースだけを変えた再ビルドで依存の取得をキャッシュから使うため、マニフェストを先にコピーする。
# path 依存の stratus は gleam.toml が無いと解決できない。
COPY gleam.toml manifest.toml ./
COPY vendor/stratus/gleam.toml vendor/stratus/
RUN gleam deps download
COPY . ./
# erlang-shipment にはライセンスのファイルが入らないので、再配布の条件として本体、
# vendor/stratus、Hex の依存のライセンスを shipment に集める。Hex の依存のファイルは
# build/packages にしか無いので、ビルドステージで集める。
RUN gleam export erlang-shipment \
  && sh dev/collect_licenses.sh build/erlang-shipment \
  && mv build/erlang-shipment /app \
  && install -m 0755 docker/start.sh /app/start.sh

# 同梱プラグイン event_logger を本体と同じ toolchain の中でビルドする（OTP を揃え、
# ホストの Elixir を混ぜないため）。写すのはソースとマニフェストだけにする。
FROM toolchain AS plugin-build
WORKDIR /build/event_logger
COPY plugins-src/event_logger/gleam.toml plugins-src/event_logger/manifest.toml ./
RUN gleam deps download
COPY plugins-src/event_logger/src src
RUN gleam export erlang-shipment

# gleam のビルドイメージは erlang:29.0.1-alpine の上に /bin/gleam を足したものなので、
# BEAM ファイルをコンパイルした OTP と実行する OTP を一致させるため、実行ステージには
# その基底イメージを使う（一致は CI の docker-image ジョブが確かめる）。
# gleam の版を上げるときは、toolchain の FROM のタグとダイジェストに合わせて、下のタグと
# ダイジェストも一緒に変える（取り違えは docker-image ジョブの OTP の検査で落ちる）。
FROM erlang:29.0.1-alpine@sha256:3ab831e65c5d398281e00d24bae3901b4cfdc1b49f79fadfd2562a1a9a17aabd
# 実行に rebar3 は要らないので消す。利用者を adduser で作ると /etc/shadow に
# ビルド日を書いてしまい再現性を壊すので、adduser と同じ内容の行を直接足す。
# wss:// のときにリレーの TLS 証明書を検証する CA 証明書と healthcheck の wget は
# 基底イメージに既にあるので、apk add は行わない。
RUN rm /usr/local/bin/rebar3 \
  && echo 'nostr:x:1000:1000::/home/nostr:/bin/sh' >> /etc/passwd \
  && echo 'nostr:x:1000:' >> /etc/group
WORKDIR /app
COPY --from=build --chown=nostr:nostr /app /app
# ローダーが受け付ける <PLUGIN_DIR>/<name>/<app>/ebin/ のレイアウトのまま置く
# （docs/plugin-api.md 第 8.1 節）。同名なら先の /app/plugins の同梱版が勝つ。
COPY --from=plugin-build --chown=nostr:nostr /build/event_logger/build/erlang-shipment /app/plugins/event_logger
ENV PLUGIN_DIR=/app/plugins
# 秘密鍵を暗号化するマスターキーを環境変数かファイルで受け取り、復号した秘密鍵を
# メモリに持つプロセスなので、root では動かさない。
USER nostr
# 管理 UI の /healthz は認証なしで応答する。`ADMIN_PORT=` として管理 UI を無効に
# した構成では待ち受けが無いため、チェック自体を省略して成功扱いにする。空文字列を
# 無効の指定として扱うのは `config.admin_ui` と同じ意味論で、`-` の既定値展開に
# しているのは「未設定なら 8080」を再現するため。空白だけの値も `config.admin_ui` と
# 同じく無効として扱うため、クォートしない echo の語分割で前後の空白を落としてから
# 判定する（set -f はこの語分割がパス名展開を起こさないようにする）。
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD sh -c 'set -f; port=$(echo ${ADMIN_PORT-8080}); [ -z "$port" ] \
    || wget -q -O /dev/null "http://127.0.0.1:$port/healthz"'
# start.sh は REMSH_ENABLED を読んでから entrypoint.sh を実行する（README の
# 「docker compose」の節）。
ENTRYPOINT ["/app/start.sh"]
CMD ["run"]
