%% 本体の境界へ渡す OTP の子仕様 map と、Gleam から組み立てられない項。
%%
%% 子仕様のキーは atom でなければならない（本体の plugin_children が
%% atom:create/1 で引く）ため、map の組み立てはこちらに置く。
-module(event_logger_ffi).
-export([child_specs/2, error_tuple/1, ensure_pgo_started/0, ok_atom/0]).

%% 接続プールと保存アクターの子仕様。Config とプールの登録名は呼び出し側から受け取り、
%% MFA 引数に焼き込む。
%%
%% プールは pog:supervised/1 に合わせて type => supervisor にする。本体は
%% supervisor の子に有限の shutdown を許さないので infinity を書く。
%% restart => permanent は個々の子の話であり、プラグイン 1 つぶんの
%% サブスーパーバイザーが Temporary であることとは矛盾しない。
child_specs(PoolConfig, PoolName) ->
    [#{id => <<"pool">>,
       start => {event_logger, start_pool, [PoolConfig]},
       restart => permanent,
       shutdown => infinity,
       type => supervisor},
     #{id => <<"store">>,
       start => {event_logger, start_store, [PoolName]},
       restart => permanent,
       shutdown => 5000,
       type => worker}].

%% 設定を拒否する戻り値。本体はこれを見てこのプラグインだけを読み込まない。
error_tuple(Reason) -> {error, Reason}.

%% pgo とその依存アプリケーションを起動する。冪等。
ensure_pgo_started() ->
    {ok, _Started} = application:ensure_all_started(pgo),
    nil.

%% 実行の成功を表す戻り値。Gleam からは atom をそのまま Dynamic として返せないため、
%% ここで作る。
ok_atom() -> ok.
