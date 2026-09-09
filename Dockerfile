FROM ghcr.io/gleam-lang/gleam:v1.17.0-erlang-alpine AS build
COPY . /build/
RUN cd /build \
  && gleam deps download \
  && gleam export erlang-shipment \
  && mv build/erlang-shipment /app \
  && rm -r /build

# BEAM ファイルをコンパイルしたときと同じ OTP で動かすため、実行ステージにも
# 同じイメージを使う。
FROM ghcr.io/gleam-lang/gleam:v1.17.0-erlang-alpine
# wss:// のときにリレーの TLS 証明書を検証するため CA 証明書が要る。healthcheck の
# wget は busybox のものを使うので追加の導入は不要。
RUN apk add --no-cache ca-certificates \
  && adduser -D -H nostr
WORKDIR /app
COPY --from=build --chown=nostr:nostr /app /app
# 秘密鍵を環境変数で受け取るプロセスなので、root では動かさない。
USER nostr
# 管理 UI の /healthz は認証なしで応答する。`ADMIN_PORT=` として管理 UI を無効に
# した構成では待ち受けが無く、この healthcheck は必ず失敗する（README を参照）。
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD wget -q -O /dev/null "http://127.0.0.1:${ADMIN_PORT:-8080}/healthz"
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["run"]
