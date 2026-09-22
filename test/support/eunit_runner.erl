%% `gleam test` のエントリー（nostr_no_su_test:main/0）が呼ぶテストの実行器。
%%
%% gleeunit の main と同じく test/ 配下の全モジュールを eunit に渡し、同じ報告
%% （gleeunit_progress）と同じオプションを使うが、モジュールを複数のレーンで同時に
%% 走らせる点が違う。gleeunit は eunit のオプションを外から渡せず、モジュールを順に
%% 走らせる。「N ms の間に何も届かない」ことを確かめる検査が多いこのリポジトリでは、
%% 順に走らせると壁時間がその待ちの合計になる。
%%
%% eunit の `{inparallel, N, Tests}` は N 個ずつまとめて走らせ、N 個すべてが終わるまで
%% 次を始めない（eunit_proc の TODO にある通り）ので、長いモジュールが 1 つあると
%% 残りのスロットが遊ぶ。ここでは代わりにレーンを `Lanes` 本並べ、各レーンが空くたびに
%% キューから次のモジュールを取る（`{generator, Fun}` は eunit がそのレーンで順番が
%% 来たときに評価するので、取り出しはその時点になる）。
%%
%% gleeunit_progress は gleeunit の内部モジュールなので、gleeunit の版の更新で名前が
%% 変われば eunit が undef で止まる（黙って報告が消えることはない）。
-module(eunit_runner).
-export([run/2]).

%% test/ 配下の全モジュールを走らせ、失敗があれば終了コード 1 で VM を止める。
%% `Ordered` に挙げたモジュール（バイナリの名前）は 1 つのレーンでその順に走らせ、
%% 残りは空いたレーンが 1 つずつ取って走らせる。どのモジュールも、中のテストは順に
%% 走る。`Ordered` に無いモジュールを挙げたら起動時に落とす（名前の誤りで直列の保証が
%% 黙って消えないように）。
run(Ordered, Lanes) ->
    Modules = test_modules(),
    Sequential = [binary_to_atom(Name, utf8) || Name <- Ordered],
    case Sequential -- Modules of
        [] -> ok;
        Missing -> error({unknown_test_modules, Missing})
    end,
    %% 直列のグループを先頭に置く。壁時間はいちばん長い項目で決まるので、長い項目を
    %% 後回しにしない。
    Items = [{inorder, Sequential} | [{inorder, M} || M <- Modules -- Sequential]],
    Queue = start_queue(Items),
    Tests =
        {inparallel, [lane(Queue, Lane, length(Items)) || Lane <- lists:seq(1, Lanes)]},
    Options = [
        verbose,
        no_tty,
        {report, {gleeunit_progress, [{colored, true}]}},
        {scale_timeouts, 10}
    ],
    Covered = start_cover(),
    Code =
        case eunit:test(Tests, Options) of
            ok -> 0;
            _ -> 1
        end,
    report_cover(Covered),
    erlang:halt(Code).

%% 1 本のレーン。順番が来るたびにキューから 1 つ取って走らせる。取り出しの回数は
%% キューの長さで足りる（空のキューからは `[]` が返る）。eunit は generator を
%% 1 回のテストの実行で複数回評価する（グループの id を決める走査と実行）ので、
%% 取り出しは (レーン, 何番目) の鍵で覚えて、同じ鍵には同じ項目を返す。
lane(Queue, Lane, Count) ->
    {inorder,
     [{generator, fun() -> pull(Queue, {Lane, Slot}) end} || Slot <- lists:seq(1, Count)]}.

%% `Key` に配った項目を返す。初めての鍵ならキューの先頭を配り、空なら `[]`
%% （eunit にとって空のテスト）を配る。
pull(Queue, Key) ->
    Queue ! {pull, Key, self()},
    receive
        {Queue, Item} -> Item
    end.

%% 項目を鍵ごとに 1 つずつ配るキューのプロセス。
start_queue(Items) ->
    spawn_link(fun() -> queue_loop(Items, #{}) end).

queue_loop(Items, Assigned) ->
    receive
        {pull, Key, From} ->
            case Assigned of
                #{Key := Item} ->
                    From ! {self(), Item},
                    queue_loop(Items, Assigned);
                _ ->
                    {Item, Rest} =
                        case Items of
                            [] -> {[], []};
                            [Next | Others] -> {Next, Others}
                        end,
                    From ! {self(), Item},
                    queue_loop(Rest, Assigned#{Key => Item})
            end
    end.

%% test/ 配下の .gleam と .erl のモジュール名。gleeunit と同じ規則で、.gleam は
%% ディレクトリーの区切りを `@` にし、.erl はファイル名をそのまま使う。
test_modules() ->
    [module_name(Path) || Path <- filelib:wildcard("**/*.{erl,gleam}", "test")].

module_name(Path) ->
    Name =
        case filename:extension(Path) of
            ".gleam" -> string:replace(filename:rootname(Path), "/", "@", all);
            ".erl" -> filename:basename(Path, ".erl")
        end,
    list_to_atom(lists:flatten(Name)).

%% 環境変数 COVERAGE が設定されているときだけ、src/ のモジュールを cover で
%% instrument してその一覧を返す。テストの実行の前に instrument しなければ計測が
%% 始まらないので、eunit:test/2 の直前に呼ぶ。COVERAGE が無いときは false を返し、
%% instrument も集計も行わない（実行は今までどおり）。instrument に失敗した
%% モジュールがあれば error/1 で落とす（黙って対象が欠けないように）。
start_cover() ->
    case os:getenv("COVERAGE") of
        false ->
            false;
        _ ->
            case cover:start() of
                {ok, _} -> ok;
                StartError -> error({cover_start_failed, StartError})
            end,
            Modules = src_modules(),
            lists:foreach(
                fun(M) ->
                    case cover:compile_beam(M) of
                        {ok, _} -> ok;
                        CompileError -> error({cover_compile_failed, M, CompileError})
                    end
                end,
                Modules),
            Modules
    end.

%% start_cover/0 が instrument したモジュールのカバレッジを集計する。cover の
%% データは VM が止まると失われるので、erlang:halt/1 の前でなければ届かない。
%% モジュールごとの行と合計の行を build/coverage.txt に書き、合計の 1 行を
%% 標準出力にも出す。build/coverage.txt の書式（dev/check_coverage_badge.sh が
%% 読む契約）は 1 行 1 モジュールで「<モジュール名> <実行された行> <行の合計>」、
%% 最後に「total <実行された行> <行の合計>」。
report_cover(false) ->
    ok;
report_cover(Modules) ->
    Counts = [count_cover(M) || M <- Modules],
    {Cov, Total} =
        lists:foldl(
            fun({_M, C, T}, {AccC, AccT}) -> {AccC + C, AccT + T} end,
            {0, 0},
            Counts),
    Lines =
        [io_lib:format("~s ~b ~b~n", [M, C, T]) || {M, C, T} <- Counts]
        ++ [io_lib:format("total ~b ~b~n", [Cov, Total])],
    ok = file:write_file("build/coverage.txt", Lines),
    io:format("coverage: ~b/~b lines (~.1f%)~n", [Cov, Total, 100 * Cov / Total]),
    ok.

%% 1 モジュールの {モジュール名, 実行された行, 行の合計}。
count_cover(M) ->
    {ok, {M, {Cov, NotCov}}} = cover:analyse(M, coverage, module),
    {M, Cov, Cov + NotCov}.

%% src/ 配下の .gleam と .erl のモジュール名（計測の対象）。build の ebin には
%% test/ と dev/（admin_preview）の BEAM も混ざるので、ディレクトリーごと
%% instrument するのではなく src の走査から導く。名付けの規則は test/ と同じ。
src_modules() ->
    [module_name(Path) || Path <- filelib:wildcard("**/*.{erl,gleam}", "src")].
