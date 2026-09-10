%% プラグインが申告する子仕様（OTP の map）と、その start が呼ぶ関数の fixture。
%% 子仕様は Erlang の map なので、Gleam 側で組み立てず、本番のプラグインと同じ形
%% でここから返す。
%%
%% 登録名はテストごとに一意でなければならない（BEAM の登録名は VM 全体で共有で、
%% gleam test は 1 つの VM で全テストを走らせる）。名前の生成は Gleam 側で行い、
%% ここは受け取った名前を使うだけにする。
-module(child_fixture).
-export([
    spec/2,
    bad_spec/1,
    start_link_store/1,
    start_link_flaky/0,
    start_link_failing/0,
    start_link_ignoring/0,
    start_unlinked/1,
    start_gleam_style/0,
    start_link_dying/0,
    bump/1,
    count/1,
    whereis_name/1,
    is_registered/1,
    kill_registered/1,
    childspec/2
]).

%% 検証を通る子仕様。Kind ごとに、検証したい 1 か所だけを既定から変える。
spec(minimal, Name) ->
    #{id => Name, start => {?MODULE, start_link_store, [Name]}};
spec(store, Name) ->
    #{
        id => Name,
        start => {?MODULE, start_link_store, [Name]},
        restart => permanent,
        shutdown => 5000,
        type => worker
    };
%% 起動には成功して直後に異常終了する子。**即 exit にしてはならない。**
%% spawn_link の直後に落ちると、スケジューリング次第で start_child/3 の
%% リンク検査の時点で既に死んでおり、どの経路を検証しているかがランごとに変わる。
spec(flaky, Name) ->
    #{id => Name, start => {?MODULE, start_link_flaky, []}};
spec(supervisor, Name) ->
    #{id => Name, start => {?MODULE, start_link_store, [Name]}, type => supervisor};
spec(supervisor_infinity, Name) ->
    #{
        id => Name,
        start => {?MODULE, start_link_store, [Name]},
        type => supervisor,
        shutdown => infinity
    };
spec(infinity, Name) ->
    #{id => Name, start => {?MODULE, start_link_store, [Name]}, shutdown => infinity};
spec(shutdown_100, Name) ->
    #{id => Name, start => {?MODULE, start_link_store, [Name]}, shutdown => 100};
spec(transient, Name) ->
    #{id => Name, start => {?MODULE, start_link_store, [Name]}, restart => transient};
spec(temporary, Name) ->
    #{id => Name, start => {?MODULE, start_link_store, [Name]}, restart => temporary};
spec(binary_id, Name) ->
    #{id => atom_to_binary(Name), start => {?MODULE, start_link_store, [Name]}};
spec(failing, Name) ->
    #{id => Name, start => {?MODULE, start_link_failing, []}};
spec(ignoring, Name) ->
    #{id => Name, start => {?MODULE, start_link_ignoring, []}};
spec(unlinked, Name) ->
    #{id => Name, start => {?MODULE, start_unlinked, [Name]}};
spec(gleam_style, Name) ->
    #{id => Name, start => {?MODULE, start_gleam_style, []}};
spec(dying, Name) ->
    #{id => Name, start => {?MODULE, start_link_dying, []}};
spec(crashing, Name) ->
    #{id => Name, start => {?MODULE, no_such_function, []}}.

%% 検証で弾かれる子仕様。
bad_spec(no_id) ->
    #{start => {?MODULE, start_link_failing, []}};
bad_spec(no_start) ->
    #{id => store};
bad_spec(bad_start) ->
    #{id => store, start => not_a_tuple};
bad_spec(brutal_kill) ->
    #{id => store, start => {?MODULE, start_link_failing, []}, shutdown => brutal_kill};
bad_spec(bad_restart) ->
    #{id => store, start => {?MODULE, start_link_failing, []}, restart => whenever};
%% 負の整数は infinity の内部表現と衝突するため拒否される。
bad_spec(negative_shutdown) ->
    #{id => store, start => {?MODULE, start_link_failing, []}, shutdown => -1};
bad_spec(bad_type) ->
    #{id => store, start => {?MODULE, start_link_failing, []}, type => daemon};
bad_spec(supervisor_shutdown) ->
    #{
        id => store,
        start => {?MODULE, start_link_failing, []},
        type => supervisor,
        shutdown => 5000
    };
%% id も start も壊れている。報告されるのは最初に検査する id の理由だけ。
bad_spec(everything) ->
    #{restart => whenever}.

%% 受信件数を数えるだけの子。登録名は自分で登録する（本体は名前を作らず渡さない）。
%% 名前が既に使われていれば register/2 が badarg で落ち、その理由が子ごとの
%% 1 行ログに出る。
start_link_store(Name) ->
    Pid = spawn_link(fun() -> store_loop(0) end),
    register(Name, Pid),
    {ok, Pid}.

store_loop(Count) ->
    receive
        {bump, From, Ref} ->
            From ! {Ref, ok},
            store_loop(Count + 1);
        {count, From, Ref} ->
            From ! {Ref, Count},
            store_loop(Count)
    end.

%% 起動には成功し、数 ms 後に異常終了する子。
start_link_flaky() ->
    {ok, spawn_link(fun() -> timer:sleep(5), exit(flaky_boom) end)}.

%% 起動に失敗する子。
start_link_failing() ->
    {error, nope}.

%% ignore を返す子。Gleam 側は Pid を要求するため未対応で、理由を出して弾かれる。
start_link_ignoring() ->
    ignore.

%% リンクを張らない子。監視漏れなので start_child/3 が kill して失敗にする。
%% kill されたことをテストから確かめられるよう、登録名だけは付ける。
start_unlinked(Name) ->
    Pid = spawn(fun() -> timer:sleep(60000) end),
    register(Name, Pid),
    {ok, Pid}.

%% Gleam の `Ok(actor.Started(..))` のランタイム表現。{ok, Pid} ではないので弾かれる。
start_gleam_style() ->
    {ok, {started, self(), nil}}.

%% 起動（リンク）には成功し、戻る前に死んでいる子。init は通ったが直後に落ちた
%% 子と同じ形で、リンク検査の時点では既にリンクが解除されている。呼び出し側には
%% リンク経由で EXIT が届くため、テストは先に exit を trap しておくこと。
start_link_dying() ->
    Parent = self(),
    Ref = make_ref(),
    Pid = spawn_link(fun() ->
        Parent ! {Ref, ready},
        exit(dying_boom)
    end),
    receive
        {Ref, ready} -> ok
    end,
    %% 死んだことを確かめてから戻る。ここを待たないと、リンク検査の時点で子が
    %% まだ生きているかどうかがランごとに変わる。
    await_dead(Pid),
    {ok, Pid}.

await_dead(Pid) ->
    case is_process_alive(Pid) of
        false -> ok;
        true ->
            timer:sleep(1),
            await_dead(Pid)
    end.

%% bump/count は宛先が居なければ badarg で落ちる（gen_server:cast と違い、障害が
%% 黙って消えない）。
bump(Name) ->
    request(Name, bump).

count(Name) ->
    request(Name, count).

request(Name, Tag) ->
    Ref = make_ref(),
    Name ! {Tag, self(), Ref},
    receive
        {Ref, Reply} -> Reply
    after 2000 -> erlang:error(timeout)
    end.

%% 登録名が指すプロセスを強制終了する。テストが子の再起動を観測するために使う。
kill_registered(Name) ->
    exit(erlang:whereis(Name), kill),
    nil.

%% 登録名が指すプロセス（未登録なら undefined）。
whereis_name(Name) ->
    erlang:whereis(Name).

%% 登録名が使われているか。
is_registered(Name) ->
    erlang:whereis(Name) =/= undefined.

%% OTP 側に実際に登録された子仕様。supervision.timeout(_, -1) が OTP の
%% shutdown => infinity になることを確かめるために使う。
childspec(Sup, Id) ->
    {ok, Spec} = supervisor:get_childspec(Sup, Id),
    Spec.
