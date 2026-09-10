%% プラグインローダーの動作確認に使う最小のプラグイン。**外から持ち込む側の例**
%% であり、本体のソースツリー（src/ と test/）には入らないので、コードパスを
%% 足さなければ読み込めない。
%%
%% test/support/minimal_plugin.erl とは役割が違う。あちらは仕様書に載せる最小
%% 実装例で、gleam が本体の ebin に混ぜてコンパイルするため最初からコードパス上に
%% ある（ローダーの検証には使えない）。
%%
%% ビルド方法と置き方は同じディレクトリーの README.md を参照すること。
-module(file_logger).
-export([plugin_api_version/0, plugin_name/0, handle_event/1]).

%% プラグインディレクトリーは読み取り専用でマウントするため、出力先はそこには
%% 置けない。コンテナーの /tmp は実行ユーザー（uid 1000）が書ける。
-define(DEFAULT_PATH, "/tmp/nostr-no-su-events.log").

plugin_api_version() -> 1.

plugin_name() -> <<"file_logger">>.

%% イベント 1 件を 1 行で追記する。知らないキーは無視するため、必要な 3 つだけを
%% 部分マッチで取り出す。
handle_event(#{<<"id">> := Id, <<"kind">> := Kind, <<"content">> := Content}) ->
    Line = io_lib:format("~ts ~p ~ts~n", [Id, Kind, Content]),
    file:write_file(path(), Line, [append]).

%% 出力先。プラグインごとの設定を渡す仕組みがまだ無いので、暫定的に環境変数で
%% 受ける。プラグイン設定の口ができたらそちらへ移す。
path() ->
    case os:getenv("FILE_LOGGER_PATH") of
        false -> ?DEFAULT_PATH;
        "" -> ?DEFAULT_PATH;
        Path -> Path
    end.
