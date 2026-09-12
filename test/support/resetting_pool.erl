%% account_store_test が `pog.execute` に例外を投げさせるための偽の接続プール。
%% pgo_pool:checkout/2 が送るチェックアウトの要求に {error, econnreset} で答える。
%% pog 4.1 の convert_error はこの項を写す節を持たないので、pog.execute は
%% function_clause を投げる。pgo_handler は gen_tcp の {error, Reason} をそのまま
%% 返すので、closed 以外のソケットのエラーでも同じ形の例外になる。本物のプールが
%% チェックアウトでこの項を返すことは無く、再現するのは例外の形だけである。
-module(resetting_pool).
-export([start/1]).

%% 偽のプールを起動して Name で登録し、その pid を返す。
start(Name) ->
    Pid = spawn(fun loop/0),
    true = register(Name, Pid),
    Pid.

%% チェックアウトの要求に答え続ける。
loop() ->
    receive
        {db_connection, {From, MRef}, {checkout, _Now, _Queue}} ->
            From ! {MRef, {error, econnreset}},
            loop()
    end.
