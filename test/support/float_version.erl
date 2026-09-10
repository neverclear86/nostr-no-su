%% plugin_api_version/0 が整数でない値を返す fixture。Gleam では `-> Int` の
%% 関数から Float を返せないため、Erlang で書いている。
-module(float_version).
-export([plugin_api_version/0, plugin_name/0, handle_event/1]).

plugin_api_version() -> 1.0.
plugin_name() -> <<"float_version">>.
handle_event(_Event) -> ok.
