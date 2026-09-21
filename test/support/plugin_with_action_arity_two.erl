%% plugin_page_action/2 だけを持つ fixture（/3 は持たない）。本体が /3 の代わりに
%% /2 を呼び、設定 map（Accounts を含む）を渡さないことの検証に使う。
-module(plugin_with_action_arity_two).
-export([plugin_api_version/0, plugin_name/0, handle_event/1]).
-export([plugin_pages/1, plugin_page_content/2, plugin_page_action/2]).

plugin_api_version() -> 1.

plugin_name() -> <<"plugin_with_action_arity_two">>.

handle_event(_Event) -> ok.

plugin_pages(_Config) ->
    [#{<<"key">> => <<"settings">>, <<"title">> => <<"Settings">>}].

plugin_page_content(_Key, _Config) ->
    #{<<"sections">> => []}.

plugin_page_action(Key, Values) ->
    persistent_term:put(?MODULE, {Key, Values}),
    ok.
