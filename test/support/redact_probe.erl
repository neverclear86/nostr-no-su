%% `log_redaction_test` が `nostr_no_su_ffi:redact_event/2` を項レベルで試す
%% ための支援。Gleam からは作れない Erlang の項（charlist、improper list、
%% map）をここで組み立て、filter の入出力を Gleam が比較できる形にして返す。
-module(redact_probe).
-export([redact/2, charlist/1, nested/1, improper/1, meta_intact/1,
         crashing/1, filter_count/0]).

%% msg に Msg、meta に make_ref() の目印を入れたイベントへ filter を適用し、
%% meta が変わっていないことを照合（変わっていれば badmatch で落ちる）して
%% から、置き換わった msg を返す。
redact(Msg, Secrets) ->
    Meta = #{sentinel => make_ref()},
    #{msg := Out, meta := Meta} =
        nostr_no_su_ffi:redact_event(#{msg => Msg, meta => Meta}, Secrets),
    Out.

%% "prefix s3cr3t suffix" の charlist。置き換え後もリストのままであることを
%% 確かめてから binary に戻して返す。
charlist(Secret) ->
    Out = redact("prefix " ++ binary_to_list(Secret) ++ " suffix", [Secret]),
    true = is_list(Out),
    iolist_to_binary(Out).

%% tuple・proper list・map の入れ子。map のキー側の値も置き換わることまで含む。
nested(Secret) ->
    redact(
        {Secret, [<<"a ", Secret/binary>>],
         #{<<"key-", Secret/binary>> => Secret}},
        [Secret]).

%% improper list。末尾の binary まで走査されることを {1 要素目, 2 要素目,
%% 末尾の項} で返す。
improper(Secret) ->
    Out = redact([<<"pre">>, Secret | <<"tail-", Secret/binary>>], [Secret]),
    [A, B | Tail] = Out,
    {A, B, Tail}.

%% pid や ref を含む meta が =:= で変わらず返るか。
meta_intact(Secret) ->
    Meta = #{pid => self(), sentinel => make_ref()},
    #{meta := Out} = nostr_no_su_ffi:redact_event(
        #{msg => Secret, meta => Meta}, [Secret]),
    Out =:= Meta.

%% filter が例外を起こす経路。install_log_redaction は空の値を落とすが、
%% 万一 filter に届いたとき binary:replace が badarg で落ちる。そのとき
%% 秘密を含む元の msg ではなく固定の文に置き換わることを、その binary を
%% 返して確かめる。
crashing(Secret) ->
    Event = #{msg => <<"token ", Secret/binary>>, meta => #{}},
    #{msg := {string, Out}} =
        nostr_no_su_ffi:redact_event(Event, [<<>>]),
    Out.

%% redact_secrets という id の primary filter の本数。0 か 1 のはず。
filter_count() ->
    #{filters := Filters} = logger:get_primary_config(),
    length([1 || {redact_secrets, _} <- Filters]).
