%% 本体の取得の口（fetch_events）の呼び出しと戻り値の変換、更新の送信（kind 0 の
%% 組み立てとイベントの送信）、Gleam 側に日時の依存を足さないための時刻の整形。
-module(profile_ffi).
-export([fetch_profiles/1, profiles_from_reply/2, merge_content/2,
         publish_profile/2, ok_atom/0, error_tuple/1, format_timestamp/1]).

%% 公開鍵の順に並んだ kind 0 の取得の結果のリスト。本体の fetch_events を 1 回だけ
%% 呼ぶので、リレー 1 本につき接続 1 本と REQ 1 件で全員を取る
%% （docs/plugin-api.md 第 14.10 節）。Pubkeys が空なら呼ばない。本体がこの口を
%% 持たないとき（古い本体、同文書第 14.5 節）の undef は publish_profile/2 と
%% 同じく捕まえて理由に変える。
fetch_profiles([]) ->
    [];
fetch_profiles(Pubkeys) ->
    Reply =
        try nostr_no_su@plugin_api:fetch_events(Pubkeys, 0)
        catch error:undef -> {error, <<"the plugin API is not installed">>}
        end,
    profiles_from_reply(Pubkeys, Reply).

%% fetch_events の戻り値を、Pubkeys と同じ順の結果の map（status / content /
%% created_at / reason。すべて binary キー）のリストにする。{ok, Results} は
%% 要素ごとに profile_result/1 で変換する。{error, Reason} は全員を同じ理由の
%% 失敗にする。それ以外（Results の件数が Pubkeys と違うものを含む）は全員を
%% the plugin API returned an unexpected value の失敗にする。
profiles_from_reply(Pubkeys, {ok, Results})
    when is_list(Results), length(Results) =:= length(Pubkeys) ->
    [profile_result(Result) || Result <- Results];
profiles_from_reply(Pubkeys, {error, Reason}) when is_binary(Reason) ->
    [error_result(Reason) || _ <- Pubkeys];
profiles_from_reply(Pubkeys, _Reply) ->
    [error_result(<<"the plugin API returned an unexpected value">>)
     || _ <- Pubkeys].

%% fetch_events の要素 1 件（fetch_event の戻り値と同じ形）を結果の map にする。
%% {ok, none} は not_found、content と created_at を持つ {ok, EventMap} は
%% found、{error, Reason} は error、それ以外は the plugin API returned an
%% unexpected value の error。
profile_result({ok, none}) ->
    #{<<"status">> => <<"not_found">>, <<"content">> => <<>>,
      <<"created_at">> => 0, <<"reason">> => <<>>};
profile_result({ok, #{<<"content">> := Content, <<"created_at">> := CreatedAt}}) ->
    #{<<"status">> => <<"found">>, <<"content">> => Content,
      <<"created_at">> => CreatedAt, <<"reason">> => <<>>};
profile_result({error, Reason}) ->
    error_result(Reason);
profile_result(_Result) ->
    error_result(<<"the plugin API returned an unexpected value">>).

%% 失敗の map。
error_result(Reason) ->
    #{<<"status">> => <<"error">>, <<"content">> => <<>>,
      <<"created_at">> => 0, <<"reason">> => Reason}.

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

%% 登録アカウントの名義で kind 0 を送る。戻り値は status / reason / created_at
%% （すべて binary キー）の map で、created_at は成功のとき本体が付けた値、失敗の
%% とき 0。本体がこの口を持たないとき（古い本体、docs/plugin-api.md 第 14.5 節）
%% の undef も捕まえて理由に変える。
publish_profile(Pubkey, Content) ->
    try
        case nostr_no_su@plugin_api:publish_event(
            Pubkey, #{<<"kind">> => 0, <<"tags">> => [], <<"content">> => Content}) of
            {ok, #{<<"created_at">> := CreatedAt}} ->
                #{<<"status">> => <<"ok">>, <<"reason">> => <<>>,
                  <<"created_at">> => CreatedAt};
            {error, Reason} ->
                #{<<"status">> => <<"error">>, <<"reason">> => Reason,
                  <<"created_at">> => 0}
        end
    catch
        error:undef ->
            #{<<"status">> => <<"error">>,
              <<"reason">> => <<"the plugin API is not installed">>,
              <<"created_at">> => 0}
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
