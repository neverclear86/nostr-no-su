%% ページとフォームの送信を両方持つ fixture。plugin_pages/1、plugin_page_content/2、
%% plugin_page_action/3 を持ち、送られた値と設定 map
%% （Accounts を含む）が届くことの検証に使う。
%%
%% Values に <<"reject">> があればその値を理由に拒否し（{error, Reason}）、
%% <<"bad-return">> があれば ok でも {error, _} でもない値を返す。それ以外は
%% 受け取った Key・Values・Config を persistent_term に退避して ok を返す。
-module(plugin_with_action).
-export([plugin_api_version/0, plugin_name/0, handle_event/1]).
-export([plugin_pages/1, plugin_page_content/2, plugin_page_action/3]).

plugin_api_version() -> 1.

plugin_name() -> <<"plugin_with_action">>.

handle_event(_Event) -> ok.

plugin_pages(_Config) ->
    [#{<<"key">> => <<"settings">>, <<"title">> => <<"Settings">>}].

plugin_page_content(_Key, _Config) ->
    #{<<"sections">> => []}.

plugin_page_action(Key, Values = #{<<"reject">> := Reason}, Config) ->
    persistent_term:put(?MODULE, {Key, Values, Config}),
    {error, Reason};
plugin_page_action(Key, Values = #{<<"bad-return">> := _}, Config) ->
    persistent_term:put(?MODULE, {Key, Values, Config}),
    nope;
plugin_page_action(Key, Values, Config) ->
    persistent_term:put(?MODULE, {Key, Values, Config}),
    ok.
