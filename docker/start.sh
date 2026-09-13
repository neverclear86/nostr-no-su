#!/bin/sh
# コンテナーの ENTRYPOINT。REMSH_ENABLED を読んで分散の引数を足してから、
# gleam export erlang-shipment が生成する /app/entrypoint.sh を exec する。
# `start.sh remsh` で本体の BEAM ノードに入る（docker compose exec から使う）。
#
# ノード名を `nostr_no_su@localhost` に固定しているのは、ホスト名（コンテナー
# ID）だと remsh が Could not connect になるため。/etc/hosts のコンテナー ID は
# コンテナーのネットワークのアドレスを指すが、分散は 127.0.0.1 にしか bind していない。
#
# cookie を ~/.erlang.cookie に置かないのは、HOME=/home/nostr が存在せず
# /home は root 所有、かつルートが read_only で書けないため。/tmp の下に
# 起動ごとの乱数で作り、umask 077 で 0600 にする。
set -eu
cookie_file=/tmp/nostr-no-su-remsh.cookie
node=nostr_no_su@localhost
interface='{127,0,0,1}'

if [ "${1-}" = remsh ]; then
  [ -r "$cookie_file" ] || { echo '[start] cannot remsh: REMSH_ENABLED is not true' >&2; exit 1; }
  exec env -u ERL_FLAGS erl -sname "remsh$$@localhost" -hidden \
    -setcookie "$(cat "$cookie_file")" -kernel inet_dist_use_interface "$interface" -remsh "$node"
fi

case "${REMSH_ENABLED:-false}" in
false) ;;
true)
  (umask 077 && head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$cookie_file")
  export ERL_EPMD_ADDRESS=127.0.0.1
  export ERL_FLAGS="${ERL_FLAGS-} -sname $node -setcookie $(cat "$cookie_file") -kernel inet_dist_use_interface $interface"
  ;;
*)
  echo "[start] cannot start: REMSH_ENABLED must be true or false, got \"$REMSH_ENABLED\"" >&2
  exit 1
  ;;
esac
exec /app/entrypoint.sh "$@"
