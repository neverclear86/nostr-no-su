%% handle_event/1 と handle_event/2 の両方を持つプラグインの fixture。
%% 本体が /2 を優先することの検証に使う。/1 が呼ばれたら例外になる。
-module(plugin_with_both_handlers).
-export([plugin_api_version/0, plugin_name/0, handle_event/1, handle_event/2]).

plugin_api_version() -> 1.

plugin_name() -> <<"plugin_with_both_handlers">>.

%% 本体が /2 を優先する限り呼ばれない。
handle_event(_Event) -> erlang:error(handle_event_1_should_not_be_called).

handle_event(_Event, _Config) -> ok.
