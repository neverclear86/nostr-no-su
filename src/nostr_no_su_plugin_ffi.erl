-module(nostr_no_su_plugin_ffi).
-export([
    ensure_module_loaded_within/2,
    call_export_within/4,
    list_dir/1,
    add_code_path/1,
    is_on_code_path/1,
    module_application/1,
    application_version/1,
    message_queue_len/0,
    run_isolated/1,
    describe_exit/1,
    start_child/3
]).

%% モジュールをコードパスから読み込む。`erlang:function_exported/3` は未読み込み
%% のモジュールに対して常に false を返すため、エクスポートの検証はこれを通した
%% 後に行う必要がある。失敗理由（nofile / badfile / embedded など）は atom なの
%% で、そのまま人が読める文字列にする。
%% -> {ok, nil} | {error, ReasonBinary}
ensure_module_loaded(Module) ->
    case code:ensure_loaded(Module) of
        {module, _} -> {ok, nil};
        {error, Reason} -> {error, atom_to_binary(Reason)}
    end.

%% ensure_module_loaded/1 を使い捨てのプロセスで呼び、TimeoutMs で打ち切る。
%% `-on_load` が戻らないモジュールは code:ensure_loaded/1 が戻らないので、
%% メタデータの呼び出しと同じ期限で打ち切る。
%%
%% 打ち切っても `-on_load` を走らせているプロセスは生き続けるが、他のモジュールの
%% 読み込みは妨げない。同じモジュールを読み直すと再び timed_out になる。
%% -> {ok, nil} | {error, {crashed, ReasonBinary}} | {error, timed_out}
ensure_module_loaded_within(Module, TimeoutMs) ->
    run_within(fun() -> ensure_module_loaded(Module) end, TimeoutMs).

%% エクスポートを呼び、例外を「クラス:理由」の 1 行の文字列にして値で返す。
%% 呼び出し元は call_export_within/4 と start_child/3 である。start_child/3 は
%% スーパーバイザーの起動時と再起動時に、子仕様の start（plugin_children/0,1 が
%% 申告した MFA）をスーパーバイザーのプロセスで呼ぶ。
%% イベント処理関数は run_isolated/1 で動かし、ここは通さない。
%% 理由はログの 1 行に収めたいので、改行を入れない ~0p で整形する。
%% -> {ok, Value} | {error, ReasonBinary}
call_export(Module, Function, Args) ->
    try erlang:apply(Module, Function, Args) of
        Value -> {ok, Value}
    catch
        Class:Reason ->
            {error, nostr_no_su_ffi:format_line("~0p:~0p", [Class, Reason])}
    end.

%% プラグインのエクスポートを使い捨てのプロセスで呼び、TimeoutMs で打ち切る。
%% 読み込み時のメタデータ（plugin_api_version/0、plugin_min_host_version/0、
%% plugin_required_versions/0、plugin_name/0、plugin_children/0,1、
%% plugin_pages/0,1,2）は本体の main プロセスが起動時に同期に呼び、管理 UI の
%% ページ（plugin_page_content/1,2,3、plugin_page_action/2,3）は要求を処理する
%% プロセスが実行時に呼ぶ。どちらも、戻らないプラグインに呼び出し側を止めさせない。
%%
%% 子仕様の start には使わない。start はスーパーバイザーのプロセスで呼び、子と
%% リンクさせる必要がある（check_linked/1）。
%% -> {ok, Value} | {error, {crashed, ReasonBinary}} | {error, timed_out}
call_export_within(Module, Function, Args, TimeoutMs) ->
    run_within(fun() -> call_export(Module, Function, Args) end, TimeoutMs).

%% 生成と監視は run_isolated/1 と同じ理由で spawn_monitor/1 により不可分に行う。
%% 結果は終了理由に載せて DOWN で受け取る。exit/1 の終了は error report を出さず、
%% 別のメッセージも送らないので、打ち切りの後に遅れた応答がメールボックスに残らない。
%% 打ち切りでは kill の後に flush 付きで demonitor し、DOWN も残さない。
%%
%% 印の無い DOWN は、プラグインが exit(self(), kill) を呼んだか、リンクした
%% プロセスの死に巻き込まれた場合で、その終了理由を crashed の理由にする。
%%
%% 使い捨てのプロセスの終了理由は normal ではない（打ち切りでは kill）ので、
%% 呼び出しの中でリンクして起こしたプロセスは、exit を trap していなければ一緒に
%% 終わる。これは意図した挙動で、exit(normal) に変えるとリンクしたプロセスが残る。
%% Fun は {ok, Value} | {error, ReasonBinary} を返すこと。
%% -> {ok, Value} | {error, {crashed, ReasonBinary}} | {error, timed_out}
run_within(Fun, TimeoutMs) ->
    {Pid, Ref} = erlang:spawn_monitor(fun() ->
        exit({nostr_no_su_export_result, Fun()})
    end),
    receive
        {'DOWN', Ref, process, Pid, {nostr_no_su_export_result, {ok, Value}}} ->
            {ok, Value};
        {'DOWN', Ref, process, Pid, {nostr_no_su_export_result, {error, Reason}}} ->
            {error, {crashed, Reason}};
        {'DOWN', Ref, process, Pid, Reason} ->
            {error, {crashed, nostr_no_su_ffi:describe_term(Reason)}}
    after TimeoutMs ->
        exit(Pid, kill),
        erlang:demonitor(Ref, [flush]),
        {error, timed_out}
    end.

%% プラグインが申告した子仕様の start（MFA）を呼ぶ。例外の捕捉と理由の整形は
%% call_export/3 に任せ、ここは戻り値の形の検査だけを行う。
%%
%% スーパーバイザーのプロセス上で実行されるため、MFA は必ずリンクを張る関数
%% （*_start_link）でなければならない。リンクを張らない子は監視されず、落ちても
%% 誰も気付かないまま登録名だけを握り続ける。黙った監視漏れにしないため、
%% リンク集合を確かめて、入っていなければその場で kill して失敗にする。
%%
%% ignore は Gleam 側が Pid を要求するため未対応。Gleam で書いたプラグインが
%% 返しがちな {ok, {started, Pid, Data}}（Gleam の Result のランタイム表現）も
%% ここで弾かれる。
%% -> {ok, Pid} | {error, ReasonBinary}
start_child(Module, Function, Args) ->
    case call_export(Module, Function, Args) of
        {ok, {ok, Pid}} when is_pid(Pid) -> check_linked(Pid);
        {ok, {ok, Pid, _Info}} when is_pid(Pid) -> check_linked(Pid);
        {ok, {error, Reason}} -> {error, nostr_no_su_ffi:describe_term(Reason)};
        {ok, Other} -> {error, nostr_no_su_ffi:format_line("unexpected start return ~0p", [Other])};
        {error, Reason} -> {error, Reason}
    end.

%% 起動した子が自分（スーパーバイザー）にリンクしているか。していなければ孤児に
%% なるので kill してから失敗を返す。
%%
%% **「リンクに居ない」だけで失敗にしてはならない。** 子が死ぬとリンクは解除され
%% るので、init は通ったが直後に落ちた子（handle_continue で DB へ繋げず落ちる、
%% など）は、正しく *_start_link を使っていてもリンク集合から消えている。そう
%% 扱うと (1) 理由の文字列が嘘になり、(2) 本来は再起動される普通のクラッシュが
%% 起動失敗に化けて、そのプラグインの子が丸ごと諦められる（本体の再起動まで
%% 戻らない）。一時的な起動順の問題が恒久的な劣化に変わってしまう。
%%
%% そこで **生きていて、かつリンクに居ない**ときだけ失敗にする。既に死んでいる
%% 子は EXIT がスーパーバイザーのメールボックスに届いているので、通常の再起動
%% 経路に任せる。
%%
%% 残る穴: リンクを張らずに既に死んでいる子は素通りする。OTP が死んだ Pid を
%% 握ったままになるが、EXIT が来ないだけで害は限定的であり、稀である。
check_linked(Pid) ->
    {links, Links} = erlang:process_info(self(), links),
    case lists:member(Pid, Links) of
        true ->
            {ok, Pid};
        false ->
            case is_process_alive(Pid) of
                %% リンクを張らずに生きている = 本当の監視漏れ。
                true ->
                    exit(Pid, kill),
                    {error, <<"start function did not link the child (use a *_start_link function)">>};
                %% リンクは張られたが既に死んだ。再起動は OTP に任せる。
                false ->
                    {ok, Pid}
            end
    end.

%% ディレクトリーの中身。file:list_dir/1 は binary のパス（Gleam の String）を
%% そのまま受け付け、charlist のリストを返す。非 UTF-8 のファイル名は
%% list_dir/1 自身が落とすので（list_dir_all/1 を使わない限り）、ここで濾す
%% 必要はない。
%% -> {ok, [BinaryName]} | {error, ReasonBinary}
list_dir(Path) ->
    case file:list_dir(Path) of
        {ok, Names} -> {ok, [unicode:characters_to_binary(N) || N <- Names]};
        {error, Reason} -> {error, atom_to_binary(Reason)}
    end.

%% ディレクトリーをコードパスの末尾に足す。末尾に足すのは、本体と先に読み込まれた
%% プラグインが常に優先されるようにするため。code:add_pathz/1 は charlist しか
%% 受け付けず、binary を渡すと function_clause で落ちる。native な名前
%% エンコーディングは utf8 なので、変換には binary_to_list/1 ではなく
%% unicode:characters_to_list/1 を使う（前者は非 ASCII のパスを壊す）。
%% -> {ok, nil} | {error, ReasonBinary}
add_code_path(Path) ->
    case code:add_pathz(unicode:characters_to_list(Path)) of
        true -> {ok, nil};
        {error, Reason} -> {error, atom_to_binary(Reason)}
    end.

%% モジュールが既にコードパス上にあるか。code:which/1 は non_existing のほかに
%% preloaded / cover_compiled といった atom も返しうるため、パスは返さず真偽だけ
%% を返す。呼び出し側が知りたいのは「本体か先のプラグインが既に提供しているか」
%% だけである。
is_on_code_path(Module) ->
    code:which(Module) =/= non_existing.

%% モジュールとして使われる BEAM が属するアプリケーションの名前と版。
%% `code:add_pathz/1` は末尾追加なので、`code:which/1` は実際にそのモジュール名で
%% 呼び出したときに使われる勝った側の BEAM を指す。返すのは常にその BEAM が置かれた
%% ebin にある `.app` で、呼び出し元がコードパスへ追加する順序（本体→影の判定の
%% 対象）とは独立である。
%% ebin に `.app` がちょうど 1 つに決まらない（0 個・複数個）、または `.app` が
%% 読めなければ Error。`preloaded` / `cover_compiled` / `non_existing` も Error。
%% -> {ok, {AppBinary, VsnBinary}} | {error, nil}
module_application(Module) ->
    case code:which(Module) of
        Path when is_list(Path) ->
            Dir = filename:dirname(Path),
            case filelib:wildcard("*.app", Dir) of
                [AppFile] -> read_app_file(filename:join(Dir, AppFile));
                _ -> {error, nil}
            end;
        _ ->
            {error, nil}
    end.

%% コードパス上で最初に見つかるアプリケーションの版。`code:where_is_file/1` は
%% `code:add_pathz/1` が足した順（先勝ち）でコードパスを辿るため、実行時に実際に
%% 使われる版と一致する。見つからなければ Error。
%% -> {ok, VsnBinary} | {error, nil}
application_version(App) ->
    case code:where_is_file(unicode:characters_to_list(App) ++ ".app") of
        non_existing ->
            {error, nil};
        Path ->
            case read_app_file(Path) of
                {ok, {_App, Vsn}} -> {ok, Vsn};
                {error, nil} -> {error, nil}
            end
    end.

%% `.app` ファイルを直読みして {AppName, Vsn} を得る。`application:get_key/2` を
%% 使わないのは、ロード済みのアプリケーションにしか答えないため。素の VM では
%% 本体の依存の一部と、他のプラグインが同梱したアプリはロードされていない。
%% `.app` の直読みはロード状態に依存せず、本体・プラグインのどちらが提供元でも
%% 同じ経路で版が出る。
%%
%% `.app` は本体が書いたものとは限らず、プラグインが同梱したものや、影の判定で
%% たまたま踏んだ他バンドルのものもここへ来る。形が崩れていても本体の起動を
%% 止めてはならないため、例外は投げず、読めない・形が違う・vsn が無い（または
%% 文字として整形できない）ときはすべて Error にする。
%% 不正な vsn では unicode:characters_to_binary/1 が {error, _, _} を返すことも
%% badarg を投げることもあるので、戻り値の検査と try の両方で塞ぐ。
%% -> {ok, {AppBinary, VsnBinary}} | {error, nil}
read_app_file(Path) ->
    try
        case file:consult(Path) of
            {ok, [{application, App, Props}]} when is_atom(App), is_list(Props) ->
                case proplists:get_value(vsn, Props) of
                    Vsn when is_list(Vsn) ->
                        case unicode:characters_to_binary(Vsn) of
                            Bin when is_binary(Bin) -> {ok, {atom_to_binary(App), Bin}};
                            _ -> {error, nil}
                        end;
                    _ ->
                        {error, nil}
                end;
            _ ->
                {error, nil}
        end
    catch
        _:_ -> {error, nil}
    end.

%% 自プロセスの未処理メッセージ数。プラグインのランナーが、遅いプラグインの
%% メールボックスが際限なく伸びるのを止めるために見る。self() に対する
%% process_info/2 は undefined を返さないため、パターンマッチで取り出す。
message_queue_len() ->
    {message_queue_len, Len} = erlang:process_info(self(), message_queue_len),
    Len.

%% プラグインの handle_event/1 を使い捨てのプロセスで動かし、{Pid, MonitorRef}
%% を返す。spawn と monitor を分けてはならない。ワーカーが monitor の前に終わる
%% と erlang:monitor/2 が即座に理由 noproc の DOWN を送り、正常な実行を失敗と
%% 誤判定する。spawn_monitor/1 はこれを不可分に行う。
%%
%% ワーカーの中で例外を捕まえるのは、隔離のためではなく終了理由を短くするため
%% である。DOWN の理由は既定では {Reason, Stacktrace} で、そのまま文字列にすると
%% 数百文字になり、ログ 1 行にもダッシュボードのセルにも収まらない。さらに DOWN
%% の理由からは例外クラスが失われる（error と exit を区別できない）。ここで
%% クラスと理由を call_export/3 と同じ ~0p の 1 行にし、スタックトレースは別枠で
%% 渡す。捕捉を外しても隔離は成立する（プロセスが分かれていることが隔離の本体）。
%%
%% 捕捉するので BEAM の標準 error report は出ない。スタックトレースは本体側が
%% 長さを切って 1 行ログに出す。
%%
%% スタックトレースは MFA だけに落とす。フレームには {file, 絶対パス} が付いて
%% おり、1 フレームで 200 文字近くを食うため、そのまま整形すると上限のほとんどが
%% パスで埋まる。失敗箇所の特定には MFA で足りる。第 3 要素は arity/1 でアリティ
%% に正規化する（nostr_no_su_ffi:arity/1 を参照）。
run_isolated(Fun) ->
    erlang:spawn_monitor(fun() ->
        try Fun() of
            _ -> ok
        catch
            Class:Reason:Stack ->
                exit(
                    {nostr_no_su_plugin_failure,
                        nostr_no_su_ffi:format_line("~0p:~0p", [Class, Reason]),
                        nostr_no_su_ffi:describe_term(
                            [{M, F, nostr_no_su_ffi:arity(A)} || {M, F, A, _} <- Stack]
                        )}
                )
        end
    end).

%% DOWN の理由を、短い 1 行の理由と（あれば）スタックトレースに分ける。
%% run_isolated/1 が付けた形だけを特別扱いし、それ以外（外部からの exit など）は
%% そのまま 1 行にする。戻り値は Gleam の #(String, Option(String))。
describe_exit({nostr_no_su_plugin_failure, Reason, Stack}) -> {Reason, {some, Stack}};
describe_exit(Reason) -> {nostr_no_su_ffi:describe_term(Reason), none}.
