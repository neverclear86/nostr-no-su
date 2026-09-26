-module(nostr_no_su_ffi).
-export([
    ensure_ssl_started/0,
    configure_logger/0,
    flush_logger/0,
    install_log_redaction/1,
    redact_event/2,
    now_seconds/0,
    monotonic_ms/0,
    ec_point_from_priv/1,
    ecdh_x/2,
    mod_pow/3,
    chacha20/3,
    aes_256_gcm_seal/4,
    aes_256_gcm_open/5,
    read_file/1,
    start_dynamic_child/2,
    terminate_dynamic_child/2,
    describe_term/1,
    format_line/2,
    arity/1,
    reply_alias/1,
    parse_ip_address/1,
    qr_dark_modules/1
]).

%% stratus は wss:// 接続に ssl アプリケーションを必要とする。本体の依存
%% アプリケーション（pog）から推移的に起動されうるが、それに任せると依存の変化で
%% 症状の遠い wss:// の接続失敗として壊れるので、stratus が必要とする前提をここで
%% 明示する。冪等なので二重に起動されても害は無い。
ensure_ssl_started() ->
    {ok, _} = application:ensure_all_started(ssl),
    nil.

%% 既定のハンドラーの formatter を `<時刻 UTC> <水準> <本文>` の 1 行形式にし、
%% 流量制限と欠落を切る。`ok = ...` の照合により、どちらかが失敗すると起動が
%% 止まる。設定されないまま行が落ちる状態で動かさないためである。
%%
%% burst_limit_enable を切るだけでは、多数のプロセスが同時に出したときに
%% 待ち行列が drop_mode_qlen / flush_qlen を超えて行が落ちる。上限は同時に
%% 出しうるプロセスの数より十分大きい値にする必要があり、ここでは
%% 実質無制限（1000000）にする。sync_mode_qlen は既定の 10 のままなので、
%% 待ち行列が 10 を超えると呼び出し側は書き終えるまで待ち、`io.println`
%% （group leader への同期の要求）と同じ背圧が働く。
configure_logger() ->
    ok = logger:update_handler_config(
        default,
        formatter,
        {logger_formatter, #{
            single_line => true,
            template => [time, " ", level, " ", msg, "\n"],
            time_offset => "Z"
        }}
    ),
    ok = logger:update_handler_config(default, config, #{
        burst_limit_enable => false,
        drop_mode_qlen => 1000000,
        flush_qlen => 1000000
    }),
    nil.

%% 既定のハンドラーに溜まった行を書き終えるまで待つ。`halt` の直前に呼ぶ。
flush_logger() ->
    logger_std_h:filesync(default),
    nil.

%% Secrets（binary のリスト）を伏せる primary filter を入れ直す。同じ id を外して
%% から足すので、何度呼んでも filter は 1 本で、後の呼び出しの値に入れ替わる。
%% 空の binary は無視する（入れると全部の行が置き換わる）。値が 0 件なら外す
%% だけで、以後は伏せない。
%% -> nil
install_log_redaction(Secrets) ->
    Values = [S || S <- Secrets, S =/= <<>>],
    _ = logger:remove_primary_filter(redact_secrets),
    case Values of
        [] -> ok;
        _ ->
            ok = logger:add_primary_filter(
                redact_secrets, {fun ?MODULE:redact_event/2, Values})
    end,
    nil.

%% primary filter。イベントの `msg` だけを走査して登録した値を `[redacted]` に
%% 置き換え、`meta` は触らない（プロセス識別子・MFA・`report_cb` の関数しか
%% 入らず、秘密の値は入らない。走査すると関数を含む項の作り直しになる）。
%% `msg` を持たないイベントはそのまま返す。
%%
%% 一致は部分列にする。整形済みの文字列として届く行（例外を文字列にしてから
%% logger へ渡す経路）の中の値も置き換えられるためである。
%%
%% 走査全体を try で包む。primary filter が例外を出すと logger がその filter を
%% 外し、以後のイベントは生のまま流れる（伏せたはずの秘密が出る）。壊れた項でも
%% 秘密を出さない側に倒すため、例外なら本文を捨てる。install_log_redaction は
%% 空の binary を登録から除くので、通常の経路でこの分岐に達することは無い。
redact_event(#{msg := Msg} = Event, Values) ->
    try Event#{msg := redact_term(Msg, Values)}
    catch _:_ -> Event#{msg := {string, <<"[log redacted: formatting failed]">>}}
    end;
redact_event(Event, _Values) ->
    Event.

%% 項の中の binary と charlist に現れた値を置き換える。binary は部分列として、
%% charlist は binary に変換できたとき（要素が全て 0〜255 の整数の proper list）
%% だけ置き換えてリスト形に戻す。255 を超えるコードポイントを含むリストは
%% charlist としては走査せず、要素ごとの走査に落ちる（文字列としては置き換わら
%% ない）。tuple と map は要素ごとに、リストは cons セルごとに走査し、improper
%% list の末尾の項も走査する。それ以外の項はそのまま返す。
redact_term(Binary, Values) when is_binary(Binary) ->
    replace_secrets(Binary, Values);
redact_term(List, Values) when is_list(List) ->
    case charlist_bytes(List, <<>>) of
        {ok, Bytes} -> binary_to_list(replace_secrets(Bytes, Values));
        error -> redact_cons(List, Values)
    end;
redact_term(Tuple, Values) when is_tuple(Tuple) ->
    list_to_tuple([redact_term(E, Values) || E <- tuple_to_list(Tuple)]);
redact_term(Map, Values) when is_map(Map) ->
    maps:fold(
        fun(K, V, Acc) ->
            Acc#{redact_term(K, Values) => redact_term(V, Values)}
        end,
        #{},
        Map);
redact_term(Other, _Values) ->
    Other.

%% cons セルごとに走査する。improper list の末尾の項も `redact_term` に渡す。
redact_cons([Head | Tail], Values) ->
    [redact_term(Head, Values) | redact_cons(Tail, Values)];
redact_cons(Other, Values) ->
    redact_term(Other, Values).

%% 全要素が 0〜255 の整数の proper list なら {ok, Binary}、それ以外（途中に
%% 非整数や 255 を超えるコードポイントがある、proper list でない）は error。
%% pgo が `binary_to_list/1` で作る charlist（接続設定の値）に合わせる。
charlist_bytes([C | Rest], Acc) when is_integer(C), C >= 0, C =< 255 ->
    charlist_bytes(Rest, <<Acc/binary, C>>);
charlist_bytes([], Acc) ->
    {ok, Acc};
charlist_bytes(_, _) ->
    error.

%% 値ごとに全出現を `[redacted]` に置き換える。長い値から先に処理する。短い
%% 値を先に置き換えると、それが別の値の接頭辞であるとき、長い方はもう一致
%% せず末尾が平文のまま残るためである。
replace_secrets(Binary, Values) ->
    Sorted = lists:sort(fun(A, B) -> byte_size(A) >= byte_size(B) end, Values),
    lists:foldl(
        fun(Value, Acc) ->
            binary:replace(Acc, Value, <<"[redacted]">>, [global])
        end,
        Binary,
        Sorted).

%% 現在時刻の Unix タイムスタンプ（秒）。
now_seconds() ->
    erlang:system_time(second).

%% 単調に増える時刻（ミリ秒）。値そのものに意味は無く、差だけを使う。
monotonic_ms() ->
    erlang:monotonic_time(millisecond).

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

%% factory_supervisor（simple_one_for_one）の子を、Arg を引数に起動する。呼び出し
%% 先の factory が未登録だと supervisor:start_child/2 は呼び出し側を noproc で
%% exit させるため、try/catch で値に写す（relay_list.gleam のモジュール doc の
%% 「呼び出し先の factory がまだ登録されていないとき」を参照）。
%% {ok, Pid, Data} は子の start 関数（gleam@otp@factory_supervisor の
%% start_child_callback/2）が Result2 の Ok(Pid, Data) を 3 要素タプルとして
%% 返すことによる。
%% -> {ok, nil} | {error, ReasonBinary}
start_dynamic_child(Sup, Arg) ->
    try supervisor:start_child(Sup, [Arg]) of
        {ok, _Pid, _Data} -> {ok, nil};
        {ok, _Pid} -> {ok, nil};
        {error, Reason} -> {error, describe_term(Reason)}
    catch
        exit:Reason -> {error, describe_term(Reason)}
    end.

%% factory_supervisor の子を Pid で止める。simple_one_for_one の
%% terminate_child/2 は子を止めてから仕様を消し（再起動しない）、factory が
%% 未登録なら start_dynamic_child/2 と同じく noproc で exit するので、同じく
%% 値に写す。
%% -> {ok, nil} | {error, ReasonBinary}
terminate_dynamic_child(Sup, Pid) ->
    try supervisor:terminate_child(Sup, Pid) of
        ok -> {ok, nil};
        {error, Reason} -> {error, describe_term(Reason)}
    catch
        exit:Reason -> {error, describe_term(Reason)}
    end.

%% 任意の項を改行の無い 1 行の文字列（~0p）にする。失敗の理由や受け取った値を、
%% ログの 1 行や理由の文字列にそのまま見せるために使う。
describe_term(Term) ->
    format_line("~0p", [Term]).

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

%% Address を IPv4 か IPv6 のアドレスとして読み、Gleam の nostrconnect.IpAddress の
%% 形（{ipv4, …} / {ipv6, …}）で返す。inet:parse_address は 127.1 のような省略形も
%% 読む。読めなければ {error, nil}。config は読めたかどうかだけを見る。
parse_ip_address(Address) ->
    case inet:parse_address(unicode:characters_to_list(Address)) of
        {ok, {A, B, C, D}} -> {ok, {ipv4, A, B, C, D}};
        {ok, {A, B, C, D, E, F, G, H}} -> {ok, {ipv6, A, B, C, D, E, F, G, H}};
        {error, _} -> {error, nil}
    end.

%% スタックトレースの第 3 要素はアリティとは限らず、例外が呼び出しそのもので
%% 起きたとき（undef / function_clause / BIF の badarg）は引数リストになる。
%% handle_event/1 は erlang:apply/3 で呼ぶため、そのままだと最上位フレームに
%% イベント map が丸ごと入る。
%% 非 ASCII の content は生のバイト列に展開されるのでさらに膨らむ。
%% nostr_no_su_store_ffi と nostr_no_su_plugin_ffi からも呼ぶので export する。
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

%% 改行を入れずに 1 行へ整形する。characters_to_binary/1 は 255 を超える
%% コードポイントを含む整形結果でも落ちない。
%% nostr_no_su_store_ffi と nostr_no_su_plugin_ffi からも呼ぶので export する。
format_line(Format, Args) ->
    unicode:characters_to_binary(io_lib:format(Format, Args)).

%% Text を誤り訂正レベル L・byte モードで QR コードに符号化し、静寂域を含む一辺の
%% モジュール数と、暗モジュールの座標の一覧を返す。nitro_qrcode:choose_version/4 は
%% 版 40 に収まらない入力で function_clause を投げるので try で捕まえる。
qr_dark_modules(Text) ->
    Bin = unicode:characters_to_binary(Text),
    try nitro_qrcode:encode(Bin, 'L') of
        {qrcode, _Version, _Ecc, Dim, Data} -> {ok, {Dim, dark_modules(Data, Dim, 0, [])}}
    catch
        _:_ -> {error, nil}
    end.

%% Data をビットごとに読み、暗モジュール（ビットが立っている位置）の座標を
%% 逆順に積む。X は列、Y は行で、どちらも Dim で割った余りと商から求める。
dark_modules(<<Bit:1, Rest/bits>>, Dim, I, Acc) ->
    Acc0 =
        case Bit of
            1 -> [{I rem Dim, I div Dim} | Acc];
            0 -> Acc
        end,
    dark_modules(Rest, Dim, I + 1, Acc0);
dark_modules(<<>>, _Dim, _I, Acc) ->
    lists:reverse(Acc).
