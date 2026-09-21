%% `log_redaction_test` が pgo の接続プロセスを実際に落とすためのシム。
%% PoolName を '$ancestors' に含む pgo_connection を短い期限で poll して 1 件に
%% 絞り、未処理の cast を送ってクラッシュレポートを起こす。'$ancestors' で絞る
%% のは、並列に走る他のテストの本物のプールの接続プロセスが同時に居るためで、
%% 絞らないと別のレーンの接続を落とす。
-module(pgo_fixture).
-export([crash_connection/1]).

%% -> {ok, Pid} | {error, nil}
crash_connection(PoolName) ->
    crash_connection(PoolName, 100).

crash_connection(_PoolName, 0) ->
    {error, nil};
crash_connection(PoolName, Left) ->
    case connection(PoolName) of
        {ok, Pid} ->
            gen_statem:cast(Pid, definitely_unhandled),
            {ok, Pid};
        error ->
            timer:sleep(10),
            crash_connection(PoolName, Left - 1)
    end.

%% PoolName を '$ancestors' に含む pgo_connection がちょうど 1 件なら返す。
connection(PoolName) ->
    case [Pid || Pid <- processes(), is_connection(Pid, PoolName)] of
        [Pid] -> {ok, Pid};
        _ -> error
    end.

is_connection(Pid, PoolName) ->
    case process_info(Pid, dictionary) of
        {dictionary, Dict} ->
            proplists:get_value('$initial_call', Dict)
                =:= {pgo_connection, init, 1}
            andalso lists:member(
                PoolName, proplists:get_value('$ancestors', Dict, []));
        _ ->
            false
    end.
