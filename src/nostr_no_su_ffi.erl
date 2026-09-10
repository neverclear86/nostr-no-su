-module(nostr_no_su_ffi).
-export([
    ensure_ssl_started/0,
    now_seconds/0,
    ec_point_from_priv/1,
    ecdh_x/2,
    mod_pow/3,
    chacha20/3,
    int_from_bytes/1,
    ensure_module_loaded/1,
    call_export/3
]).

%% ssl アプリケーションは `gleam run` や erlang-shipment のエントリポイントでは
%% 自動起動されないが、stratus は wss:// 接続にこれを必要とする。
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

%% プラグインのメタデータ取得（plugin_api_version/0 と plugin_name/0）専用の
%% 呼び出し。壊れたモジュールが本体の起動を止めないよう、例外を捕捉して文字列
%% にする。イベントの配送（handle_event/1）には使わない。障害の隔離は専用プロ
%% セスの導入で行う方針で、ここで握り潰すとクラッシュが黙って消えるため。
%% 理由はログの 1 行に収めたいので、改行を入れない ~0p で整形する。
%% -> {ok, Value} | {error, ReasonBinary}
call_export(Module, Function, Args) ->
    try erlang:apply(Module, Function, Args) of
        Value -> {ok, Value}
    catch
        Class:Reason ->
            {error, list_to_binary(io_lib:format("~0p:~0p", [Class, Reason]))}
    end.
