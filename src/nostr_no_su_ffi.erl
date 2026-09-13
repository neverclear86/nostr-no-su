-module(nostr_no_su_ffi).
-export([
    ensure_ssl_started/0,
    now_seconds/0,
    ec_point_from_priv/1,
    ecdh_x/2,
    mod_pow/3,
    chacha20/3,
    aes_256_gcm_seal/4,
    aes_256_gcm_open/5,
    int_from_bytes/1,
    ensure_module_loaded/1,
    call_export_within/4,
    list_dir/1,
    read_file/1,
    is_directory/1,
    absolute_path/1,
    add_code_path/1,
    is_on_code_path/1,
    module_application/1,
    application_version/1,
    message_queue_len/0,
    run_isolated/1,
    describe_exit/1,
    start_child/3,
    describe_term/1,
    reply_alias/1,
    pool_transaction/3,
    execute_catching/2
]).

%% stratus は wss:// 接続に ssl アプリケーションを必要とする。本体の依存
%% アプリケーション（pog）から推移的に起動されうるが、それに任せると依存の変化で
%% 症状の遠い wss:// の接続失敗として壊れるので、stratus が必要とする前提をここで
%% 明示する。冪等なので二重に起動されても害は無い。
ensure_ssl_started() ->
    {ok, _} = application:ensure_all_started(ssl),
    nil.

%% 現在時刻の Unix タイムスタンプ（秒）。
now_seconds() ->
    erlang:system_time(second).

%% OpenSSL による d*G。呼び出し側は事前に 1 =< d < n を必ず検査すること。
%% priv = 0 でも例外にはならず、退化した {<<0>>, _} の点を黙って返す。
%% -> {ok, {XBin32, YBin32}} | {error, nil}
ec_point_from_priv(Priv) ->
    try
        {<<4, X:32/binary, Y:32/binary>>, _} =
            crypto:generate_key(ecdh, secp256k1, Priv),
        {ok, {X, Y}}
    catch
        _:_ -> {error, nil}
    end.

%% d*P の x 座標。P は 33 バイトの圧縮点（02/03 || X）で与える。
%% 曲線上にない点は内部で例外となり {error, nil} になる。
ecdh_x(CompressedPub, Priv) ->
    try
        {ok, crypto:compute_key(ecdh, CompressedPub, Priv, secp256k1)}
    catch
        _:_ -> {error, nil}
    end.

%% 整数の冪剰余。crypto:mod_pow は可変長の符号なしビッグエンディアンのバイナリ
%% を返し（0 のときは <<>>）、decode_unsigned(<<>>) =:= 0 となる。
mod_pow(Base, Exp, Mod) ->
    binary:decode_unsigned(crypto:mod_pow(Base, Exp, Mod)).

%% ブロックカウンター 0 と 12 バイト nonce による RFC 8439 の ChaCha20。OTP の IV
%% レイアウトは <<Counter:32/little, Nonce:12/binary>>。XOR ストリーム暗号なので
%% 同じ呼び出しで暗号化と復号の両方を行える。
chacha20(Key, Nonce12, Data) ->
    crypto:crypto_one_time(chacha20, Key, <<0:32, Nonce12/binary>>, Data, true).

%% AES-256-GCM による暗号化。
%%
%% 例外は再送出せず {error, nil} に写す。鍵長や nonce 長の誤りで投げられる
%% badarg の error_info とスタックトレースには、鍵・平文・AAD のバイト列が引数と
%% してそのまま載り、アクターのクラッシュレポートに出てしまうため。
%% -> {ok, {Cipher, Tag}} | {error, nil}
aes_256_gcm_seal(Key, Nonce, Plain, Aad) ->
    try
        {ok, crypto:crypto_one_time_aead(aes_256_gcm, Key, Nonce, Plain, Aad, true)}
    catch
        _:_ -> {error, nil}
    end.

%% AES-256-GCM による復号。
%%
%% OTP は 16 バイトより短いタグでも復号に成功するので、ガードで 16 バイトを要求
%% する。タグの不一致は例外ではなく atom の error で返る。例外は seal と同じ理由で
%% 再送出しない。
%% -> {ok, Plain} | {error, nil}
aes_256_gcm_open(Key, Nonce, Cipher, Aad, Tag) when byte_size(Tag) =:= 16 ->
    try crypto:crypto_one_time_aead(aes_256_gcm, Key, Nonce, Cipher, Aad, Tag, false) of
        error -> {error, nil};
        Plain -> {ok, Plain}
    catch
        _:_ -> {error, nil}
    end;
aes_256_gcm_open(_Key, _Nonce, _Cipher, _Aad, _Tag) ->
    {error, nil}.

%% バイト列を符号なしビッグエンディアンの整数として読む。
int_from_bytes(Bin) ->
    binary:decode_unsigned(Bin).

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

%% 子仕様の start（plugin_children/0 が申告した MFA）と call_export_within/4 の
%% 中で、例外を 1 行の理由にするために使う。壊れたモジュールが本体の起動を
%% 止めないよう、例外を捕捉して文字列にする。
%% 子仕様の start は起動時（plugin_children/0 の解決時）とスーパーバイザーに
%% よる再起動時に呼ばれる。どちらの場合も例外を捕まえるのは隔離のためではなく、
%% 理由を 1 行に整えるためである。
%% イベントの配送（handle_event/1）には使わない。障害の隔離は専用プロセスの
%% 導入で行う方針で、ここで握り潰すとクラッシュが黙って消えるため。
%% 理由はログの 1 行に収めたいので、改行を入れない ~0p で整形する。
%% -> {ok, Value} | {error, ReasonBinary}
call_export(Module, Function, Args) ->
    try erlang:apply(Module, Function, Args) of
        Value -> {ok, Value}
    catch
        Class:Reason ->
            {error, format_line("~0p:~0p", [Class, Reason])}
    end.

%% プラグインのメタデータ用のエクスポート（plugin_api_version/0、plugin_name/0、
%% plugin_children/0,1）を使い捨てのプロセスで呼び、TimeoutMs で打ち切る。本体の
%% main プロセスが起動時に同期に呼ぶので、戻らないプラグインが起動を止めないように
%% する。
%%
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
%%
%% 子仕様の start には使わない。start はスーパーバイザーのプロセスで呼び、子と
%% リンクさせる必要がある（check_linked/1）。
%% -> {ok, Value} | {error, {crashed, ReasonBinary}} | {error, timed_out}
call_export_within(Module, Function, Args, TimeoutMs) ->
    {Pid, Ref} = erlang:spawn_monitor(fun() ->
        exit({nostr_no_su_export_result, call_export(Module, Function, Args)})
    end),
    receive
        {'DOWN', Ref, process, Pid, {nostr_no_su_export_result, {ok, Value}}} ->
            {ok, Value};
        {'DOWN', Ref, process, Pid, {nostr_no_su_export_result, {error, Reason}}} ->
            {error, {crashed, Reason}};
        {'DOWN', Ref, process, Pid, Reason} ->
            {error, {crashed, format_line("~0p", [Reason])}}
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
        {ok, {error, Reason}} -> {error, format_line("~0p", [Reason])};
        {ok, Other} -> {error, format_line("unexpected start return ~0p", [Other])};
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

%% 任意の項を 1 行の文字列にする。子仕様の理由の文字列で、受け取った値をそのまま
%% 見せるために使う（dynamic.classify では brutal_kill と permanent の区別が
%% 付かず、作者の役に立たない）。
describe_term(Term) ->
    format_line("~0p", [Term]).

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

%% パスがディレクトリーかどうか。binary をそのまま渡せる。
is_directory(Path) ->
    filelib:is_dir(Path).

%% ファイルの中身を UTF-8 の binary（Gleam の String）で返す。失敗理由は
%% enoent などの文字列、UTF-8 でなければ not valid UTF-8。秘密を読むのに
%% 使うので、内容を理由に入れない。
%% -> {ok, Binary} | {error, ReasonBinary}
read_file(Path) ->
    case file:read_file(Path) of
        {error, Reason} ->
            {error, atom_to_binary(Reason)};
        {ok, Bin} ->
            case unicode:characters_to_binary(Bin) of
                Bin -> {ok, Bin};
                _ -> {error, <<"not valid UTF-8">>}
            end
    end.

%% 相対パスを絶対パスにする。プラグインディレクトリーを最初に 1 度だけ正規化し、
%% ログ行とコードパスへ登録する内容が相対・絶対で食い違わないようにするために
%% 使う。binary を渡せば binary が返るので変換は要らない。
absolute_path(Path) ->
    filename:absname(Path).

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
%% `App` が atom で `Props` が list であることをガードで確かめたうえで
%% `proplists:get_value/2` を呼ぶ（`function_clause` を避ける）。`atom_to_binary/1`
%% は atom であれば必ず成功するが、`vsn` の値は不正な整数（コードポイントの範囲外
%% や負値）を含むリストでも `is_list/1` は真になるため、`unicode:characters_to_binary/1`
%% の戻り値が binary であることまで確かめる（不正な入力は `{error, Bin, Rest}` を
%% 返す場合と `badarg` の例外を投げる場合があり、`try` はその両方を一度に塞ぐ）。
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
%% 誤判定する（10,000 回に 1 回程度発生する）。spawn_monitor/1 はこれを不可分に
%% 行う。
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
%% に正規化する（下記）。
run_isolated(Fun) ->
    erlang:spawn_monitor(fun() ->
        try Fun() of
            _ -> ok
        catch
            Class:Reason:Stack ->
                exit(
                    {nostr_no_su_plugin_failure, format_line("~0p:~0p", [Class, Reason]),
                        format_line("~0p", [[{M, F, arity(A)} || {M, F, A, _} <- Stack]])}
                )
        end
    end).

%% DOWN の理由を、短い 1 行の理由と（あれば）スタックトレースに分ける。
%% run_isolated/1 が付けた形だけを特別扱いし、それ以外（外部からの exit など）は
%% そのまま 1 行にする。戻り値は Gleam の #(String, Option(String))。
describe_exit({nostr_no_su_plugin_failure, Reason, Stack}) -> {Reason, {some, Stack}};
describe_exit(Reason) -> {format_line("~0p", [Reason]), none}.

%% スタックトレースの第 3 要素はアリティとは限らず、例外が呼び出しそのもので
%% 起きたとき（undef / function_clause / BIF の badarg）は引数リストになる。
%% handle_event/1 は erlang:apply/3 で呼ぶため、そのままだと最上位フレームに
%% イベント map が丸ごと入る（実測 594 バイト。アリティに落とせば 88 バイト）。
%% 非 ASCII の content は生のバイト列に展開されるのでさらに膨らむ。
arity(A) when is_list(A) -> length(A);
arity(A) -> A.

%% named.call の返信先。宛先を監視する monitor を alias として作り、その参照を
%% owner と tag に持つ subject を返す。gen:do_call と同じ仕組みで、demonitor の後や
%% DOWN の後に alias へ届いた応答はランタイムが捨てる。reply_demonitor により、
%% 応答を 1 件受け取った時点で監視も alias も外れる。
%% subject は gleam_erlang の公開関数で作り、Subject の実行時表現に依存しない。
%% -> {Monitor, Subject}
reply_alias(Pid) ->
    Alias = erlang:monitor(process, Pid, [{alias, reply_demonitor}]),
    {Alias, 'gleam@erlang@process':unsafely_create_subject(Alias, Alias)}.

%% プール Pool の接続 1 本で Fun をトランザクションとして実行する。Fun の中で同じ
%% プールへ送るクエリーは、pgo がプロセス辞書に置いたこの接続で実行される。Fun が
%% {error, _} を返したら例外で pgo に ROLLBACK させ、その値を {ok, _} で返す
%% （pgo の new_transaction は Fun が返れば値に関わらず COMMIT し、例外だけが
%% pgo の外から選べる ROLLBACK の手段であるため）。
%%
%% 期限 TimeoutMs はチェックアウトの要求から数える。pgo のプールは期限を過ぎた
%% チェックアウトの接続を閉じるので、トランザクションの中のすべてのクエリーと COMMIT が
%% この期限で打ち切られる。pog.transaction は期限を指定できず（pgo の既定の 5000ms に
%% なる）、中のクエリーには pog.timeout も効かないため、ここで指定する。
%%
%% 接続が閉じられた後の BEGIN の badmatch と COMMIT の case_clause（どちらも
%% {error, closed}）は、期限による打ち切りか途中の切断として interrupted にする。
%% それ以外の例外（プールが無いときの exit(noproc)、Fun の中の panic など）は failed に
%% する。どちらも理由の項は捨て、クエリーの引数や結果がクラッシュレポートにもログにも
%% 出ないようにする。
%% -> {ok, {ok, Result} | {error, Reason}} | {error, checkout_failed}
%%    | {error, interrupted} | {error, failed}
pool_transaction(Pool, TimeoutMs, Fun) ->
    try pgo:transaction(Pool, fun() ->
                                 case Fun() of
                                     {error, _} = Failed ->
                                         throw({nostr_no_su_rollback, Failed});
                                     Result -> {nostr_no_su_completed, Result}
                                 end
                             end,
                        #{pool_options => [{timeout, TimeoutMs}]}) of
        {nostr_no_su_completed, Result} -> {ok, Result};
        {error, _Reason} -> {error, checkout_failed}
    catch
        throw:{nostr_no_su_rollback, Failed} -> {ok, Failed};
        error:{badmatch, {error, closed}} -> {error, interrupted};
        error:{case_clause, {error, closed}} -> {error, interrupted};
        _:_ -> {error, failed}
    end.

%% pog:execute/2 を実行し、例外を値に写す。pog 4.1 の convert_error は closed 以外の
%% エラーの項（pgo_handler がそのまま返すソケットのエラーや、pgo_pool のチェックアウトが
%% 返す文字列の理由）を写す節を持たず function_clause を投げる。pgo_pool のチェックアウトは
%% プールのプロセスが無いと呼び出し側を exit させる。
%%
%% チェックアウトの exit はクエリーを送る前なので unavailable にする。それ以外の例外は
%% 送った後にも起きうるので raised にし、呼び出し側は書き込まれていることがあるものとして
%% 扱う。raised には送る前の function_clause（チェックアウトの文字列の理由）も含まれる。
%% 理由の項とフレームの引数にはクエリーの引数や行のバイト列が載りうるので捨て、クラスと
%% 発生箇所だけを残す（describe_raise/2）。
%% -> {ok, {ok, Returned} | {error, QueryError}} | {error, unavailable} | {error, {raised, Binary}}
execute_catching(Query, Connection) ->
    try pog:execute(Query, Connection) of
        Executed -> {ok, Executed}
    catch
        exit:{_, {pgo_pool, checkout, _}} -> {error, unavailable};
        Class:_:Stacktrace -> {error, {raised, describe_raise(Class, Stacktrace)}}
    end.

%% execute_catching/2 が捕まえた例外を「クラス in モジュール:関数/アリティ」の 1 行に
%% する。発生箇所はスタックトレースの最上位のフレームで、第 3 要素は arity/1 でアリティに
%% 落とす。catch のパターンではスタックトレースを分解できないので、この関数の節で分ける。
describe_raise(Class, [{Module, Function, Arity, _} | _]) ->
    format_line("~0p in ~0p:~0p/~0p", [Class, Module, Function, arity(Arity)]);
describe_raise(Class, _) ->
    format_line("~0p in an unknown location", [Class]).

%% 改行を入れずに 1 行へ整形する。characters_to_binary/1 は 255 を超える
%% コードポイントを含む整形結果でも落ちない。
format_line(Format, Args) ->
    unicode:characters_to_binary(io_lib:format(Format, Args)).
