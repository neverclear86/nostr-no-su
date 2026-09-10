%% 設定を受け付けないプラグインの fixture。plugin_children/1 が {error, Reason}
%% を返す経路と、理由が binary でない場合の扱いを確かめるために使う。
%%
%% plugin_children/0 も持っているが、こちらが呼ばれたら例外になる。本体が /1 を
%% 優先することの検証で、/0 が呼ばれた場合は "rejected" ではなく "crashed" に
%% なるため、ログ行だけで両者を区別できる。
-module(plugin_rejecting_config).
-export([plugin_api_version/0, plugin_name/0]).
-export([plugin_children/0, plugin_children/1, handle_event/1]).

plugin_api_version() -> 1.

plugin_name() -> <<"plugin_rejecting_config">>.

%% 本体が /1 を優先する限り呼ばれない。
plugin_children() -> erlang:error(plugin_children_0_should_not_be_called).

%% reason => atom の設定を与えると、理由が binary でない {error, Reason} を返す。
plugin_children(#{<<"reason">> := <<"atom">>}) -> {error, not_a_binary};
plugin_children(_Config) -> {error, <<"path is required">>}.

handle_event(_Event) -> ok.
