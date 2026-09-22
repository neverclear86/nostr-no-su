%% relay_client_test が、WebSocket でない応答を返すリレーを再現するための
%% fixture。決まったバイト列を返すだけの TCP の待ち受けを立てる。
-module(plain_tcp_server).
-export([listen/2]).

%% 127.0.0.1 の OS が割り当てたポートで待ち受け、そのポート番号を返す。
%% 接続を受けるたびに OnAccept() を呼び、Response を送るプロセスを育てる。
listen(Response, OnAccept) ->
    {ok, Listen} =
        gen_tcp:listen(0, [binary, {active, false}, {ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Listen),
    spawn(fun() -> accept_loop(Listen, Response, OnAccept) end),
    Port.

%% 接続を受け続け、1 本ごとに serve/1 のプロセスへソケットを渡す。
accept_loop(Listen, Response, OnAccept) ->
    case gen_tcp:accept(Listen) of
        {ok, Socket} ->
            Handler = spawn(fun() -> serve(Response) end),
            ok = gen_tcp:controlling_process(Socket, Handler),
            Handler ! {socket, Socket},
            OnAccept(),
            accept_loop(Listen, Response, OnAccept);
        {error, _} ->
            ok
    end.

%% 渡されたソケットに Response を送り、相手が閉じるまで保つ。
serve(Response) ->
    receive {socket, Socket} -> ok end,
    ok = gen_tcp:send(Socket, Response),
    drain(Socket).

%% 受けたバイトを捨て、相手が閉じるか 5 秒黙ったらソケットを閉じる。
%% すぐに閉じると、クライアントは本文を待たずに SocketClosed で失敗する。
drain(Socket) ->
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, _} -> drain(Socket);
        {error, _} -> gen_tcp:close(Socket)
    end.
