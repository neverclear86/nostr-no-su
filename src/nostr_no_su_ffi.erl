-module(nostr_no_su_ffi).
-export([
    ensure_ssl_started/0,
    now_seconds/0,
    ec_point_from_priv/1,
    ecdh_x/2,
    mod_pow/3,
    chacha20/3,
    int_from_bytes/1
]).

%% ssl アプリケーションは `gleam run` や erlang-shipment のエントリポイントでは
%% 自動起動されないが、stratus は wss:// 接続にこれを必要とする。
ensure_ssl_started() ->
    {ok, _} = application:ensure_all_started(ssl),
    nil.

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

%% ブロックカウンタ 0 と 12 バイト nonce による RFC 8439 の ChaCha20。OTP の IV
%% レイアウトは <<Counter:32/little, Nonce:12/binary>>。XOR ストリーム暗号なので
%% 同じ呼び出しで暗号化と復号の両方を行える。
chacha20(Key, Nonce12, Data) ->
    crypto:crypto_one_time(chacha20, Key, <<0:32, Nonce12/binary>>, Data, true).

int_from_bytes(Bin) ->
    binary:decode_unsigned(Bin).
