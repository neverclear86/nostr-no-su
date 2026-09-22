%% 公開鍵ごとの取得の並行化と打ち切り、Gleam 側に日時の依存を足さないための
%% 時刻の整形。
-module(profile_ffi).
-export([fetch_profiles/1, format_timestamp/1]).

%% すべての取得を打ち切る総上限（ミリ秒）。fetch_event 1 回は、リレーへの問い合わせの
%% 3.2 秒に加えてバンカーとリレーの一覧への問い合わせを含み、それらが応答しないときは
%% 5 秒・15 秒まで延びる（docs/plugin-api.md 第 14.8 節）。plugin_page_content 1 回の
%% 期限は既定 5 秒（同文書第 13.1 節）なので、逐次ではアカウント 1 件でもページが
%% 503 になりうる。並行にし、この上限で打ち切って失敗を alert に落とすことで、
%% アカウントの件数にもリレーの応答にもよらず 5 秒の内側でページを返す。
-define(FETCH_ALL_TIMEOUT_MS, 4000).

%% 公開鍵の順に並んだ取得の結果のリスト。公開鍵ごとに spawn_monitor でワーカーを
%% 起こし、総上限まで待って集める。上限に達した分は打ち切って失敗として扱う。
fetch_profiles(Pubkeys) ->
    Deadline = erlang:monotonic_time(millisecond) + ?FETCH_ALL_TIMEOUT_MS,
    Workers = [{spawn_monitor(fun() -> exit({fetched, fetch_one(P)}) end), P} || P <- Pubkeys],
    [collect(Ref, Pid, Deadline) || {{Pid, Ref}, _P} <- Workers].

%% 公開鍵 1 件の取得。status / content / created_at / reason（すべて binary キー）
%% の map にする。
fetch_one(Pubkey) ->
    case nostr_no_su@plugin_api:fetch_event(Pubkey, 0) of
        {ok, none} ->
            #{<<"status">> => <<"not_found">>, <<"content">> => <<>>,
              <<"created_at">> => 0, <<"reason">> => <<>>};
        {ok, #{<<"content">> := Content, <<"created_at">> := CreatedAt}} ->
            #{<<"status">> => <<"found">>, <<"content">> => Content,
              <<"created_at">> => CreatedAt, <<"reason">> => <<>>};
        {error, Reason} ->
            error_result(Reason)
    end.

%% 失敗の map。
error_result(Reason) ->
    #{<<"status">> => <<"error">>, <<"content">> => <<>>,
      <<"created_at">> => 0, <<"reason">> => Reason}.

%% ワーカー 1 件の結果を待つ。残り時間を使い切ったら kill して打ち切りの理由を返す。
%% demonitor(Ref, [flush]) で、打ち切ったワーカーの遅れて届く DOWN を捨て、以後も
%% 届かないようにする（呼び出し元は使い捨てのプロセスなので、残っても次の呼び出しの
%% メールボックスを汚さないが、明示的に片付ける）。ワーカーは spawn_monitor で
%% 起こすので、このプロセスに DOWN 以外のメッセージは届かない。
collect(Ref, Pid, Deadline) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {'DOWN', Ref, process, _Pid, {fetched, Result}} ->
            Result;
        {'DOWN', Ref, process, _Pid, Other} ->
            error_result(list_to_binary(io_lib:format("crashed (~p)", [Other])))
    after Remaining ->
        exit(Pid, kill),
        erlang:demonitor(Ref, [flush]),
        error_result(<<"the profile fetch did not finish in time">>)
    end.

%% Unix 秒を UTC の RFC 3339 の binary にする。別プロジェクトのためモジュールを
%% 共有できず、event_logger_ffi:format_timestamp/1 と同じ実装を写した。リレー由来の
%% 秒が calendar の範囲外だと badarg になるので、その場合は秒をそのまま文字にする。
format_timestamp(Seconds) ->
    try
        list_to_binary(
            calendar:system_time_to_rfc3339(Seconds, [{unit, second}, {offset, "Z"}]))
    catch
        error:_ -> integer_to_binary(Seconds)
    end.
