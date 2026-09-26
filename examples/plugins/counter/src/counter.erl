%% 状態を持つプラグインの最小例。受信件数を gen_server で数えるだけで、
%% plugin_children/0 で自分の子プロセスを申告する。
-module(counter).
-behaviour(gen_server).
-export([plugin_api_version/0, plugin_name/0, plugin_children/0, handle_event/1]).
-export([start_link/0, init/1, handle_call/3, handle_cast/2]).

%% 登録名は VM 全体で一意でなければならない。プラグイン名を接頭辞にする。
-define(STORE, counter_store).

plugin_api_version() -> 1.
plugin_name() -> <<"counter">>.

%% 本体はこの map をそのままスーパービジョンツリーの子仕様に包む。名前は
%% start_link/0 の中で自分で登録する（本体は名前を作らず渡さない）。
plugin_children() ->
    [#{id => ?STORE,
       start => {?MODULE, start_link, []},
       restart => permanent,
       shutdown => 5000,
       type => worker}].

%% call を使うのは、store が居ないことをランナーに失敗として見せるため。
%% cast は宛先が居なくても成功するので、障害が黙って消える。
handle_event(#{<<"id">> := Id}) ->
    gen_server:call(?STORE, {seen, Id}).

start_link() -> gen_server:start_link({local, ?STORE}, ?MODULE, [], []).
init([]) -> {ok, 0}.
handle_call({seen, Id}, _From, Count) ->
    io:format("[counter] ~b events (last ~ts)~n", [Count + 1, Id]),
    {reply, ok, Count + 1}.
handle_cast(_Msg, Count) -> {noreply, Count}.
