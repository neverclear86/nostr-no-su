%% relay_client_test が、平文の TCP に wss:// で繋いだときの TLS のアラートを
%% 再現するための fixture。TLS ではない応答を返すだけの待ち受けを立てる。
-module(plain_tcp_server).
-export([listen/0]).

%% 127.0.0.1 の OS が割り当てたポートで待ち受け、そのポート番号を返す。
%% 接続を 1 本だけ受けて TLS でない応答を返すプロセスを育てる。
listen() ->
    {ok, Listen} =
        gen_tcp:listen(0, [binary, {active, false}, {ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Listen),
    spawn(fun() -> serve(Listen) end),
    Port.

%% 接続を 1 本受け、TLS のレコードとして不正な HTTP の応答を返す。先頭の
%% 'H'（72）はレコードの型として不正なので、ssl:connect は
%% {tls_alert, {unexpected_message, ...}} で失敗する。相手が閉じるまで
%% 待ってからソケットと待ち受けを閉じる。
serve(Listen) ->
    {ok, Socket} = gen_tcp:accept(Listen),
    ok = gen_tcp:send(Socket, "HTTP/1.1 400 Bad Request\r\n\r\n"),
    _ = gen_tcp:recv(Socket, 0, 5000),
    ok = gen_tcp:close(Socket),
    ok = gen_tcp:close(Listen).
