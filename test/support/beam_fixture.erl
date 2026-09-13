%% ローダーのテストが使う BEAM を、その場でコンパイルして用意するためのシム。
%% charlist を要求する API だけをここに置き、置き場所や名前の決定は Gleam 側で
%% 行う。
-module(beam_fixture).
-export([compile_to/2, loaded_app_version/1]).

%% .erl ファイルを指定ディレクトリーへコンパイルする。compile:file/2 はファイル名
%% も outdir も charlist しか受け付けないため、Gleam の String（binary）をここで
%% 変換する。native な名前エンコーディングは utf8 なので binary_to_list ではなく
%% unicode:characters_to_list を使う。失敗理由にはソースのパスが埋まるため、
%% binary 化にも unicode 版を使う（list_to_binary は非 ASCII のパスで badarg）。
%% -> {ok, nil} | {error, ReasonBinary}
compile_to(Source, OutDir) ->
    Options = [{outdir, unicode:characters_to_list(OutDir)}, return_errors],
    case compile:file(unicode:characters_to_list(Source), Options) of
        {ok, _Module} -> {ok, nil};
        Other -> {error, unicode:characters_to_binary(io_lib:format("~0p", [Other]))}
    end.

%% ロード済みアプリケーションの版。被検コード（`.app` の直読み）とは別の経路
%% （`application:get_key/2`）で期待値を得るために使う。App はロード済みで
%% あることをテスト側が保証する。
%% -> VsnBinary
loaded_app_version(App) ->
    {ok, Vsn} = application:get_key(binary_to_atom(App), vsn),
    unicode:characters_to_binary(Vsn).
