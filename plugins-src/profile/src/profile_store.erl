%% 直前の更新の送信の結果を、アカウント（公開鍵）ごとに 1 回の描画まで保持する
%% gen_server。保持は揮発で、DB へは書かない。`take/1` は取り出しと同時に削除する
%% ので、成功・失敗の alert は次にそのページを開いたときの 1 回しか出ない。
%%
%% 保持する map のキーは `status`（`<<"ok">>` / `<<"error">>`）・`message`（表示する
%% 英語の 1 文）・`values`（送信に失敗したときだけ、フォームへ戻す 8 項目の map）
%% である。組み立ては profile.gleam が行う。
-module(profile_store).
-behaviour(gen_server).
-export([start_link/0, put/2, take/1, child_specs/0]).
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

%% 子仕様。event_logger_ffi:child_specs/2 と同じ形。
child_specs() ->
    [#{id => <<"result_store">>,
       start => {profile_store, start_link, []},
       restart => permanent,
       shutdown => 5000,
       type => worker}].

init([]) ->
    {ok, #{}}.

handle_call({put, Pubkey, Result}, _From, State) ->
    {reply, ok, State#{Pubkey => Result}};
handle_call({take, Pubkey}, _From, State) ->
    case maps:take(Pubkey, State) of
        {Result, NewState} -> {reply, Result, NewState};
        error -> {reply, none, State}
    end.

handle_cast(_Msg, State) ->
    {noreply, State}.
