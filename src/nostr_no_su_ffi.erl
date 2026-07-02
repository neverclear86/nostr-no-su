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

%% The ssl application is not started automatically by `gleam run` or the
%% erlang-shipment entrypoint, but stratus needs it for wss:// connections.
ensure_ssl_started() ->
    {ok, _} = application:ensure_all_started(ssl),
    nil.

now_seconds() ->
    erlang:system_time(second).

%% d*G via OpenSSL. The caller MUST check 1 =< d < n first: priv = 0 does not
%% raise here, it silently returns a degenerate {<<0>>, _} point.
%% -> {ok, {XBin32, YBin32}} | {error, nil}
ec_point_from_priv(Priv) ->
    try
        {<<4, X:32/binary, Y:32/binary>>, _} =
            crypto:generate_key(ecdh, secp256k1, Priv),
        {ok, {X, Y}}
    catch
        _:_ -> {error, nil}
    end.

%% x-coordinate of d*P, with P as a 33-byte compressed point (02/03 || X).
%% Off-curve points raise internally and become {error, nil}.
ecdh_x(CompressedPub, Priv) ->
    try
        {ok, crypto:compute_key(ecdh, CompressedPub, Priv, secp256k1)}
    catch
        _:_ -> {error, nil}
    end.

%% Integer modular exponentiation. crypto:mod_pow returns a variable-length
%% unsigned big-endian binary (<<>> for 0); decode_unsigned(<<>>) =:= 0.
mod_pow(Base, Exp, Mod) ->
    binary:decode_unsigned(crypto:mod_pow(Base, Exp, Mod)).

%% RFC 8439 ChaCha20 with block counter 0 and a 12-byte nonce. OTP's IV layout
%% is <<Counter:32/little, Nonce:12/binary>>. As an XOR stream cipher the same
%% call both encrypts and decrypts.
chacha20(Key, Nonce12, Data) ->
    crypto:crypto_one_time(chacha20, Key, <<0:32, Nonce12/binary>>, Data, true).

int_from_bytes(Bin) ->
    binary:decode_unsigned(Bin).
