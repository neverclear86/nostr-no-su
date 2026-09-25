%% コードパスに無いアプリケーションを 2 つ要求するプラグインの fixture。
%% plugin_required_versions/0 の照合がアプリケーション名の順に進み、名前順で
%% 先の nns_missing_app_a を理由に出すことの検証に使う。
-module(plugin_requiring_missing_apps).
-export([plugin_api_version/0, plugin_name/0, handle_event/1]).
-export([plugin_required_versions/0]).

plugin_api_version() -> 1.

plugin_name() -> <<"plugin_requiring_missing_apps">>.

handle_event(_Event) -> ok.

plugin_required_versions() ->
    #{<<"nns_missing_app_b">> => <<"1.0.0">>, <<"nns_missing_app_a">> => <<"2.0.0">>}.
