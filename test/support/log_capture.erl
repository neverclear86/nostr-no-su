%% `log_redaction_test` と `admin_auth_test` が OTP logger を通る行を捕まえるための logger ハンドラー。
%% 本番と同じ formatter の設定（`configure_logger` の template）で 1 行に整形し、
%% ets の表に積む。ハンドラーの `log/2` はログを出したプロセスの上で呼ばれる
%% ため、表は public にする。
-module(log_capture).
-export([install/0, lines/1, remove/1]).
-export([log/2]).

%% 一意な id のハンドラーと行を積む表を作り、{Id, Table} を返す。
install() ->
    Id = list_to_atom(
        "log_capture_" ++ integer_to_list(erlang:unique_integer([positive]))),
    Table = ets:new(?MODULE, [ordered_set, public]),
    ok = logger:add_handler(Id, ?MODULE, #{table => Table}),
    {Id, Table}.

%% 捕まえた行を積んだ順に返す。連番のカウンター行（キーが整数でない）は除く。
lines({_Id, Table}) ->
    [Line || {Seq, Line} <- ets:tab2list(Table), is_integer(Seq)].

%% ハンドラーと表を消す。
remove({Id, Table}) ->
    _ = logger:remove_handler(Id),
    true = ets:delete(Table),
    nil.

%% logger のハンドラーの callback。`configure_logger` と同じ formatter の設定で
%% 1 行にして、連番を付けて表へ積む。
log(Event, #{table := Table}) ->
    Line = unicode:characters_to_binary(
        logger_formatter:format(Event, #{
            single_line => true,
            template => [time, " ", level, " ", msg, "\n"],
            time_offset => "Z"
        })),
    Seq = ets:update_counter(Table, seq, {2, 1}, {seq, 0}),
    ets:insert(Table, {Seq, Line}),
    ok.
