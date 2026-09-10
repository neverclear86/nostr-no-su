%% 本体の境界へ渡す OTP の子仕様 map と、Gleam から組み立てられない項。
%%
%% 子仕様のキーは atom でなければならない（本体の plugin_children が
%% atom:create/1 で引く）ため、map の組み立てはこちらに置く。
-module(event_logger_ffi).
-export([child_specs/2, error_tuple/1, identity/1, ensure_pgo_started/0]).

%% 接続プールと保存アクターの子仕様。プール名と Config は呼び出し側が 1 度だけ
%% 作ったものを引数に焼き込む（再起動でも同じ引数で呼ばれるので名前が安定する）。
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
%% Gleam の Ok(List) は {ok, List} になってしまい、素のリストを期待する本体には
%% 渡せないため、成功も失敗も Dynamic として組み立てる。
error_tuple(Reason) -> {error, Reason}.

%% 項をそのまま返す。atom を登録名（gleam_erlang の Name）として扱うためだけに
%% 使う。Name は外部型で、実体は登録名の atom である。
identity(Term) -> Term.

%% pgo のアプリケーションを起動する。プラグインの同梱アプリは本体が起動しない
%% ため、ここで起動しないと pgo_type_server が pg_types のモジュール一覧を
%% 引けずに badmatch で即死し、pgo_pool ごと落ちる（README の該当節を参照）。
%% 冪等なので子の再起動のたびに呼ばれても害はない。
ensure_pgo_started() ->
    {ok, _Started} = application:ensure_all_started(pgo),
    nil.
