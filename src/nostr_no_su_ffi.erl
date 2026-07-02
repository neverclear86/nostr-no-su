-module(nostr_no_su_ffi).
-export([ensure_ssl_started/0]).

%% The ssl application is not started automatically by `gleam run` or the
%% erlang-shipment entrypoint, but stratus needs it for wss:// connections.
ensure_ssl_started() ->
    {ok, _} = application:ensure_all_started(ssl),
    nil.
