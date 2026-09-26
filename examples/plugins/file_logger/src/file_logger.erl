%% プラグインローダーの動作確認に使う最小のプラグイン。**外から持ち込む側の例**
%% であり、本体のソースツリー（src/ と test/）には入らないので、コードパスを
%% 足さなければ読み込めない。
%%
%% test/support/minimal_plugin.erl とは役割が違う。あちらは仕様書に載せる最小
%% 実装例で、gleam が本体の ebin に混ぜてコンパイルするため最初からコードパス上に
%% ある（ローダーの検証には使えない）。
%%
%% プラグイン固有の設定（PLUGIN_FILE_LOGGER_*）を受け取る例でもある。
%%
%% ビルド方法と置き方は同じディレクトリーの README.md を参照すること。
-module(file_logger).
-export([plugin_api_version/0, plugin_name/0, plugin_children/1, handle_event/2]).

plugin_api_version() -> 1.

plugin_name() -> <<"file_logger">>.

%% 子プロセスは持たない。設定の検査だけを行うために plugin_children/1 を
%% エクスポートしている。設定が揃っていれば空のリストを返す。
%% 値が空文字列の環境変数は本体が落とすので、キーの有無だけを見ればよい。
plugin_children(#{<<"path">> := _Path}) -> [];
plugin_children(_Config) -> {error, <<"path is required">>}.

%% イベント 1 件を 1 行で追記する。知らないキーは無視するため、必要な 3 つだけを
%% 部分マッチで取り出す。出力先は設定 map の path で、既定値は持たない。
%%
%% 本体は handle_event/2 を優先する。設定が必須のプラグインは handle_event/1 を
%% 正しく書けない（設定が無いのだから既定値に落とすしかない）ので、v1 は
%% handle_event/1 と /2 のどちらか一方を必須としている。
handle_event(#{<<"id">> := Id, <<"kind">> := Kind, <<"content">> := Content},
             #{<<"path">> := Path}) ->
    Line = io_lib:format("~ts ~p ~ts~n", [Id, Kind, Content]),
    %% 失敗を例外にして本体に 1 件の失敗として数えさせる（戻り値は本体に無視される）。
    ok = file:write_file(Path, Line, [append]).
