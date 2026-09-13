FROM ghcr.io/gleam-lang/gleam:v1.17.0-erlang-alpine AS build
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
  && mv build/erlang-shipment /app

# BEAM ファイルをコンパイルしたときと同じ OTP で動かすため、実行ステージにも
# 同じイメージを使う。
FROM ghcr.io/gleam-lang/gleam:v1.17.0-erlang-alpine
# wss:// のときにリレーの TLS 証明書を検証するため CA 証明書が要る。healthcheck の
# wget は busybox のものを使うので追加の導入は不要。
RUN apk add --no-cache ca-certificates \
  && adduser -D -H nostr
WORKDIR /app
COPY --from=build --chown=nostr:nostr /app /app
# 秘密鍵を暗号化するマスターキーを環境変数かファイルで受け取り、復号した秘密鍵を
# メモリに持つプロセスなので、root では動かさない。
USER nostr
# 管理 UI の /healthz は認証なしで応答する。`ADMIN_PORT=` として管理 UI を無効に
# した構成では待ち受けが無いため、チェック自体を省略して成功扱いにする。空文字列を
# 無効の指定として扱うのは `config.admin_ui` と同じ意味論で、`-` の既定値展開に
# しているのは「未設定なら 8080」を再現するため。
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD sh -c 'port="${ADMIN_PORT-8080}"; [ -z "$port" ] \
    || wget -q -O /dev/null "http://127.0.0.1:$port/healthz"'
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["run"]
