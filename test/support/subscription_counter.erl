%% relay_client_test が、購読の定義のサンクが評価された回数を数えるための fixture。
%% サンクは stratus のプロセスの中で評価されるので、回数はそのプロセスの
%% プロセス辞書に持つ。Gleam には可変の変数が無く、別のアクターで数えると評価の
%% 経路に問い合わせが増えるため、ここで数える。
%% relay_connection_test が、接続の試行の回数を数えるのにも使う（接続関数は
%% 接続アクターのプロセスで呼ばれる）。
-module(subscription_counter).
-export([next/0]).

%% このプロセスでの評価の回数を 0 から数え、呼ぶ前の値を返す。
next() ->
    Count =
        case get(nostr_no_su_subscription_counter) of
            undefined -> 0;
            Value -> Value
        end,
    put(nostr_no_su_subscription_counter, Count + 1),
    Count.
