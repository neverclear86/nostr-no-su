FROM ghcr.io/gleam-lang/gleam:v1.17.0-erlang-alpine AS build
COPY . /build/
RUN cd /build \
  && gleam deps download \
  && gleam export erlang-shipment \
  && mv build/erlang-shipment /app \
  && rm -r /build

# The same image is reused for the runtime stage so the OTP version always
# matches the one the BEAM files were compiled with.
FROM ghcr.io/gleam-lang/gleam:v1.17.0-erlang-alpine
# CA certificates are required to verify the relay's TLS certificate (wss://).
RUN apk add --no-cache ca-certificates
WORKDIR /app
COPY --from=build /app /app
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["run"]
