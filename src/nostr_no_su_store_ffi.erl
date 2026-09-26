%% アカウントストア（bunker/account_store.gleam）が使う pgo と pog の呼び出しを包む FFI。
%% どちらも例外を値に写し、クエリーの引数が載りうる理由の項は捨てる。
-module(nostr_no_su_store_ffi).
-export([pool_transaction/3, execute_catching/2]).

%% プール Pool の接続 1 本で Fun をトランザクションとして実行する。Fun の中で同じ
%% プールへ送るクエリーは、pgo がプロセス辞書に置いたこの接続で実行される。Fun が
%% {error, _} を返したら例外で pgo に ROLLBACK させ、その値を {ok, _} で返す
%% （pgo の new_transaction は Fun が返れば値に関わらず COMMIT し、例外だけが
%% pgo の外から選べる ROLLBACK の手段であるため）。
%%
%% 期限 TimeoutMs はチェックアウトの要求から数える。pgo のプールは期限を過ぎた
%% チェックアウトの接続を閉じるので、トランザクションの中のすべてのクエリーと COMMIT が
%% この期限で打ち切られる。pog.transaction は期限を指定できず（pgo の既定の 5000ms に
%% なる）、中のクエリーには pog.timeout も効かないため、ここで指定する。
%%
%% 接続が閉じられた後の BEGIN の badmatch と COMMIT の case_clause（どちらも
%% {error, closed}）は、期限による打ち切りか途中の切断として interrupted にする。
%% それ以外の例外（プールが無いときの exit(noproc)、Fun の中の panic など）は failed に
%% する。どちらも理由の項は捨て、クエリーの引数や結果がクラッシュレポートにもログにも
%% 出ないようにする。
%% -> {ok, {ok, Result} | {error, Reason}} | {error, checkout_failed}
%%    | {error, interrupted} | {error, failed}
pool_transaction(Pool, TimeoutMs, Fun) ->
    try pgo:transaction(Pool, fun() ->
                                 case Fun() of
                                     {error, _} = Failed ->
                                         throw({nostr_no_su_rollback, Failed});
                                     Result -> {nostr_no_su_completed, Result}
                                 end
                             end,
                        #{pool_options => [{timeout, TimeoutMs}]}) of
        {nostr_no_su_completed, Result} -> {ok, Result};
        {error, _Reason} -> {error, checkout_failed}
    catch
        throw:{nostr_no_su_rollback, Failed} -> {ok, Failed};
        error:{badmatch, {error, closed}} -> {error, interrupted};
        error:{case_clause, {error, closed}} -> {error, interrupted};
        _:_ -> {error, failed}
    end.

%% pog:execute/2 を実行し、例外を値に写す。pog 4.1 の convert_error は closed 以外の
%% エラーの項（pgo_handler がそのまま返すソケットのエラーや、pgo_pool のチェックアウトが
%% 返す文字列の理由）を写す節を持たず function_clause を投げる。pgo_pool のチェックアウトは
%% プールのプロセスが無いと呼び出し側を exit させる。
%%
%% チェックアウトの exit はクエリーを送る前なので unavailable にする。それ以外の例外は
%% 送った後にも起きうるので raised にし、呼び出し側は書き込まれていることがあるものとして
%% 扱う。raised には送る前の function_clause（チェックアウトの文字列の理由）も含まれる。
%% 理由の項とフレームの引数にはクエリーの引数や行のバイト列が載りうるので捨て、クラスと
%% 発生箇所だけを残す（describe_raise/2）。
%% -> {ok, {ok, Returned} | {error, QueryError}} | {error, unavailable} | {error, {raised, Binary}}
execute_catching(Query, Connection) ->
    try pog:execute(Query, Connection) of
        Executed -> {ok, Executed}
    catch
        exit:{_, {pgo_pool, checkout, _}} -> {error, unavailable};
        Class:_:Stacktrace -> {error, {raised, describe_raise(Class, Stacktrace)}}
    end.

%% execute_catching/2 が捕まえた例外を「クラス in モジュール:関数/アリティ」の 1 行に
%% する。発生箇所はスタックトレースの最上位のフレームで、第 3 要素は
%% nostr_no_su_ffi:arity/1 でアリティに落とす。catch のパターンではスタックトレースを
%% 分解できないので、この関数の節で分ける。
describe_raise(Class, [{Module, Function, Arity, _} | _]) ->
    nostr_no_su_ffi:format_line("~0p in ~0p:~0p/~0p",
                                [Class, Module, Function, nostr_no_su_ffi:arity(Arity)]);
describe_raise(Class, _) ->
    nostr_no_su_ffi:format_line("~0p in an unknown location", [Class]).
