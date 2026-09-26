%% 直前の更新の送信の結果と、取得した kind 0 のキャッシュを、アカウント（公開鍵）
%% ごとに持つ gen_server。保持は揮発で、DB へは書かない。
%%
%% 送信の結果は `put/2` で置き、`take/1` で取り出すと同時に削除するので、成功・
%% 失敗の alert は次にそのページを開いたときの 1 回しか出ない。保持する map の
%% キーは `status`（`<<"ok">>` / `<<"error">>`）と、送信に失敗したときだけの
%% `reason`（失敗の理由の英語の 1 文）・`values`（フォームへ戻す 8 項目の map）
%% である。表示の文言は持たず、描画の時に profile/page.gleam が表示の言語で組む。
%% 組み立ては profile.gleam が行う。
%%
%% キャッシュは `cache_put/3` で有効期限つきで置き、`cache_get/1` で期限内のもの
%% だけを読む（読んでも消さない）。置く値は profile/page.gleam の `Fetched` で、
%% このモジュールは中身を見ない。期限は単調時計（erlang:monotonic_time/1）で
%% 測る。
-module(profile_store).
-behaviour(gen_server).
-export([start_link/0, put/2, take/1, cache_put/3, cache_get/1, child_specs/0]).
-export([init/1, handle_call/3, handle_cast/2]).

%% 呼び出しの期限（ミリ秒）。plugin_page_content / plugin_page_action 1 回の期限
%% （既定 5 秒、docs/plugin-api.md 第 13.1 節）に収めるため、同文書第 13.4 節の
%% 定めどおり問い合わせ側にも期限を付ける。
-define(CALL_TIMEOUT_MS, 1000).

start_link() ->
    gen_server:start_link({local, profile_store}, ?MODULE, [], []).

%% 公開鍵 1 件の結果を保持する。宛先が居ないときと期限超過は ok を返す（送信その
%% ものはすでに済んでいるので、保持だけに失敗しても送信は失敗にしない）。
put(Pubkey, Result) ->
    try
        gen_server:call(profile_store, {put, Pubkey, Result}, ?CALL_TIMEOUT_MS)
    catch
        exit:_ -> ok
    end.

%% 公開鍵 1 件の結果を取り出し、同時に削除する。無ければ none。宛先が居ないとき
%% と期限超過も none にする。
take(Pubkey) ->
    try
        gen_server:call(profile_store, {take, Pubkey}, ?CALL_TIMEOUT_MS)
    catch
        exit:_ -> none
    end.

%% 公開鍵 1 件の取得の結果を、今から TtlMs ミリ秒の間キャッシュする。同じ公開鍵の
%% 古い値は置き換え、期限の過ぎた他の値はここで捨てる。宛先が居ないときと期限
%% 超過は ok を返す（キャッシュは表示を速くするだけなので、置けなくても呼び出し
%% 側は続ける）。
cache_put(Pubkey, Profile, TtlMs) ->
    try
        gen_server:call(profile_store, {cache_put, Pubkey, Profile, TtlMs},
                        ?CALL_TIMEOUT_MS)
    catch
        exit:_ -> ok
    end.

%% Pubkeys と同じ順に、期限内のキャッシュがあれば {some, Profile}、無ければ none
%% を並べたリスト（Gleam の Option）。宛先が居ないときと期限超過はすべて none
%% にする（リレーから取り直すことになる）。
cache_get(Pubkeys) ->
    try
        gen_server:call(profile_store, {cache_get, Pubkeys}, ?CALL_TIMEOUT_MS)
    catch
        exit:_ -> [none || _ <- Pubkeys]
    end.

%% 子仕様。event_logger_ffi:child_specs/2 と同じ形。
child_specs() ->
    [#{id => <<"profile_store">>,
       start => {profile_store, start_link, []},
       restart => permanent,
       shutdown => 5000,
       type => worker}].

%% 状態は送信の結果（results）とキャッシュ（profiles。値は {Profile, ExpiresAt}）
%% の 2 つの map。
init([]) ->
    {ok, #{results => #{}, profiles => #{}}}.

handle_call({put, Pubkey, Result}, _From, State) ->
    #{results := Results} = State,
    {reply, ok, State#{results => Results#{Pubkey => Result}}};
handle_call({take, Pubkey}, _From, State) ->
    #{results := Results} = State,
    case maps:take(Pubkey, Results) of
        {Result, NewResults} ->
            {reply, Result, State#{results => NewResults}};
        error ->
            {reply, none, State}
    end;
handle_call({cache_put, Pubkey, Profile, TtlMs}, _From, State) ->
    #{profiles := Profiles} = State,
    Now = erlang:monotonic_time(millisecond),
    Live = maps:filter(fun(_Pubkey, {_Profile, ExpiresAt}) -> ExpiresAt > Now end,
                       Profiles),
    {reply, ok, State#{profiles => Live#{Pubkey => {Profile, Now + TtlMs}}}};
handle_call({cache_get, Pubkeys}, _From, State) ->
    #{profiles := Profiles} = State,
    Now = erlang:monotonic_time(millisecond),
    Reply = [case maps:find(Pubkey, Profiles) of
                 {ok, {Profile, ExpiresAt}} when ExpiresAt > Now -> {some, Profile};
                 _ -> none
             end || Pubkey <- Pubkeys],
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.
