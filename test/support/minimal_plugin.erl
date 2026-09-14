%% プラグイン API v1 の最小実装例。docs/plugin-api.md の第 10 章に載せたモジュールと、
%% このコメントを除いて同じ内容に保つ。本体の ebin に混ぜてコンパイルされるので
%% 最初からコードパス上にあり、test/plugin_test.gleam が読み込めることを確かめ、
%% test/plugin_loader_test.gleam が本体と同名のモジュールを拒否する例に使う。
-module(minimal_plugin).
-export([plugin_api_version/0, plugin_name/0, handle_event/1]).

plugin_api_version() -> 1.
plugin_name() -> <<"minimal_plugin">>.

handle_event(Event) ->
    #{<<"kind">> := Kind, <<"content">> := Content} = Event,
    io:format("~p ~ts~n", [Kind, Content]),
    ok.
