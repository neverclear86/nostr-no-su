%% 公開鍵ごとの取得の並行化と打ち切り、更新の送信（kind 0 の組み立てとイベントの
%% 送信）、Gleam 側に日時の依存を足さないための時刻の整形。
-module(profile_ffi).
-export([fetch_profiles/1, fetch_profiles/2, merge_content/2, publish_profile/2,
         ok_atom/0, error_tuple/1, format_timestamp/1]).

%% すべての取得を打ち切る総上限（ミリ秒）。fetch_event 1 回は、リレーへの問い合わせの
%% 3.2 秒に加えてバンカーとリレーの一覧への問い合わせを含み、それらが応答しないときは
%% 5 秒・15 秒まで延びる（docs/plugin-api.md 第 14.8 節）。plugin_page_content 1 回の
%% 期限は既定 5 秒（同文書第 13.1 節）なので、逐次ではアカウント 1 件でもページが
%% 503 になりうる。並行にし、この上限で打ち切って失敗を alert に落とすことで、
%% アカウントの件数にもリレーの応答にもよらず 5 秒の内側でページを返す。
%% 更新の送信の直前に取り直すときは、同じ呼び出しの中で送信も行うため、呼び出し側が
%% 短い上限を渡す（profile:action_fetch_timeout_ms/0）。
-define(FETCH_ALL_TIMEOUT_MS, 4000).

%% 公開鍵の順に並んだ取得の結果のリスト。総上限は ?FETCH_ALL_TIMEOUT_MS。
fetch_profiles(Pubkeys) ->
    fetch_profiles(Pubkeys, ?FETCH_ALL_TIMEOUT_MS).

%% 公開鍵の順に並んだ取得の結果のリスト。公開鍵ごとに spawn_monitor でワーカーを
%% 起こし、総上限まで待って集める。上限に達した分は打ち切って失敗として扱う。
fetch_profiles(Pubkeys, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    Workers = [{spawn_monitor(fun() -> run_worker(P) end), P} || P <- Pubkeys],
    [collect(Ref, Pid, Deadline) || {{Pid, Ref}, _P} <- Workers].

%% ワーカー本体。fetch_one/1 が例外を投げたら、DOWN の理由をスタックトレース抜きの
%% Class と Reason だけにして collect/3 に渡す（そのまま届くと ~p で数百文字に
%% なりうる）。
run_worker(Pubkey) ->
    try fetch_one(Pubkey) of
        Result -> exit({fetched, Result})
    catch
        Class:Reason:Stack -> exit({Class, Reason, Stack})
    end.

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
        {'DOWN', Ref, process, _Pid, {Class, Reason, _Stack}} ->
            error_result(
                list_to_binary(io_lib:format("crashed (~0p:~0p)", [Class, Reason]))
            );
        {'DOWN', Ref, process, _Pid, Other} ->
            error_result(list_to_binary(io_lib:format("crashed (~p)", [Other])))
    after Remaining ->
        exit(Pid, kill),
        erlang:demonitor(Ref, [flush]),
        error_result(<<"the profile fetch did not finish in time">>)
    end.

%% kind 0 の content（JSON の binary）に Fields の項目を差し替えた JSON の binary を
%% 返す。未知のキーはそのまま残す。空の値（<<>>）のキーは消す（項目の削除）。
%% Content が JSON のオブジェクトとして読めない・例外を投げるときは空の map から
%% 組み立てる。
merge_content(Content, Fields) ->
    Merged = lists:foldl(fun({Key, Value}, Acc) ->
        case Value of
            <<>> -> maps:remove(Key, Acc);
            _ -> Acc#{Key => Value}
        end
    end, decode_object(Content), Fields),
    iolist_to_binary(json:encode(Merged)).

%% Content を JSON のオブジェクトとして読む。読めない・例外を投げるときは空の map。
decode_object(Content) ->
    try json:decode(Content) of
        Map when is_map(Map) -> Map;
        _NotAnObject -> #{}
    catch
        _:_ -> #{}
    end.

%% 登録アカウントの名義で kind 0 を送る。本体がこの口を持たないとき（古い本体、
%% docs/plugin-api.md 第 14.5 節）の undef も捕まえて理由に変える。
publish_profile(Pubkey, Content) ->
    try
        case nostr_no_su@plugin_api:publish_event(
            Pubkey, #{<<"kind">> => 0, <<"tags">> => [], <<"content">> => Content}) of
            {ok, _Event} ->
                #{<<"status">> => <<"ok">>, <<"reason">> => <<>>};
            {error, Reason} ->
                #{<<"status">> => <<"error">>, <<"reason">> => Reason}
        end
    catch
        error:undef ->
            #{<<"status">> => <<"error">>,
              <<"reason">> => <<"the plugin API is not installed">>}
    end.

%% Gleam の Ok(Nil) に潰す atom。event_logger_ffi:ok_atom/0 と同じ役割。
ok_atom() -> ok.

%% 設定・送信を拒否する戻り値。event_logger_ffi:error_tuple/1 と同じ役割。
error_tuple(Reason) -> {error, Reason}.

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
