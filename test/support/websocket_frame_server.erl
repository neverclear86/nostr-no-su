%% relay_client_test と plugin_api_test が、接続の閉じ方を確かめるための
%% fixture。WebSocket のハンドシェイクを済ませ、受けたフレームの opcode と
%% マスクを外した中身を OnFrame へ渡す。テキストのフレーム（opcode 1）には
%% Reply が返す各テキストを送り返す。mist の偽リレーは close フレームと
%% TCP の切断を区別できないので、こちらでフレームをそのまま見る。
-module(websocket_frame_server).
-export([listen/2]).

%% 127.0.0.1 の OS が割り当てたポートで待ち受け、そのポート番号を返す。
%% 接続を受けるたびにハンドシェイクとフレームのやり取りをするプロセスを育てる。
listen(OnFrame, Reply) ->
    {ok, Listen} =
        gen_tcp:listen(0, [binary, {active, false}, {ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Listen),
    spawn(fun() -> accept_loop(Listen, OnFrame, Reply) end),
    Port.

%% 接続を受け続け、1 本ごとに serve/3 のプロセスへソケットを渡す。
accept_loop(Listen, OnFrame, Reply) ->
    case gen_tcp:accept(Listen) of
        {ok, Socket} ->
            Handler = spawn(fun() -> serve(OnFrame, Reply) end),
            ok = gen_tcp:controlling_process(Socket, Handler),
            Handler ! {socket, Socket},
            accept_loop(Listen, OnFrame, Reply);
        {error, _} ->
            ok
    end.

%% ハンドシェイクを済ませてからフレームを読む。要求が読めなければ閉じる。
serve(OnFrame, Reply) ->
    receive {socket, Socket} -> ok end,
    case read_request(Socket, <<>>) of
        {ok, Request} ->
            ok = gen_tcp:send(Socket, handshake_response(Request)),
            read_frames(Socket, OnFrame, Reply, <<>>);
        {error, _} ->
            gen_tcp:close(Socket)
    end.

%% 要求を \r\n\r\n まで読む。5 秒届かなければあきらめる。
read_request(Socket, Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        {_, _} -> {ok, Acc};
        nomatch ->
            case gen_tcp:recv(Socket, 0, 5000) of
                {ok, Data} -> read_request(Socket, <<Acc/binary, Data/binary>>);
                {error, Reason} -> {error, Reason}
            end
    end.

%% 101 の応答。sec-websocket-key の値に決まった GUID を継いだ SHA-1 を
%% base64 で返す。ヘッダー名は小文字にして比べる。
handshake_response(Request) ->
    Key = websocket_key(Request),
    Accept = base64:encode(
        crypto:hash(sha, <<Key/binary, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11">>)),
    ["HTTP/1.1 101 Switching Protocols\r\n",
     "upgrade: websocket\r\n",
     "connection: upgrade\r\n",
     "sec-websocket-accept: ", Accept, "\r\n\r\n"].

%% 要求のヘッダー行から sec-websocket-key の値を取る。
websocket_key(Request) ->
    Lines = binary:split(Request, <<"\r\n">>, [global]),
    [Key] =
        [string:trim(Value) || Line <- Lines,
                              [Name, Value] <- [binary:split(Line, <<":">>)],
                              string:lowercase(string:trim(Name))
                                  =:= <<"sec-websocket-key">>],
    Key.

%% バッファの先頭からフレームを 1 件ずつ取り、OnFrame へ渡す。テキストの
%% フレームには Reply が返す各テキストを送り返す。受信が 5 秒途絶えるか
%% 相手が閉じたらソケットを閉じる。close フレームへの応答は返さない
%% （閉じる側は応答を待たない）。
read_frames(Socket, OnFrame, Reply, Buffer) ->
    case take_frame(Buffer) of
        {ok, Opcode, Payload, Rest} ->
            OnFrame(Opcode, Payload),
            case Opcode of
                1 -> send_texts(Socket, Reply(Payload));
                _ -> ok
            end,
            read_frames(Socket, OnFrame, Reply, Rest);
        more ->
            case gen_tcp:recv(Socket, 0, 5000) of
                {ok, Data} ->
                    read_frames(Socket, OnFrame, Reply,
                                <<Buffer/binary, Data/binary>>);
                {error, _} -> gen_tcp:close(Socket)
            end
    end.

%% バッファの先頭のフレームを 1 件取る。クライアントのフレームは必ず
%% マスク付き（MASK ビットが 1）。足りなければ more。
take_frame(<<_Fin:1, _Rsv:3, Opcode:4, 1:1, Len:7, Rest/binary>>) ->
    case read_length(Len, Rest) of
        {ok, Length, AfterLength} ->
            case AfterLength of
                <<Mask:4/binary, Data/binary>>
                  when byte_size(Data) >= Length ->
                    <<Payload:Length/binary, Tail/binary>> = Data,
                    {ok, Opcode, unmask(Payload, Mask), Tail};
                _ -> more
            end;
        more -> more
    end;
take_frame(_) -> more.

%% ペイロード長の 3 形。126 は続く 16 ビット、127 は続く 64 ビットが長さ。
read_length(126, Rest) ->
    case Rest of
        <<Len:16, Tail/binary>> -> {ok, Len, Tail};
        _ -> more
    end;
read_length(127, Rest) ->
    case Rest of
        <<Len:64, Tail/binary>> -> {ok, Len, Tail};
        _ -> more
    end;
read_length(Len, Rest) -> {ok, Len, Rest}.

%% 4 オクテットの鍵を先頭から繰り返して XOR し、マスクを外す。
unmask(Payload, Mask) -> unmask(Payload, Mask, 0, <<>>).
unmask(<<>>, _Mask, _Index, Acc) -> Acc;
unmask(<<Byte, Rest/binary>>, Mask, Index, Acc) ->
    Key = binary:at(Mask, Index rem 4),
    unmask(Rest, Mask, Index + 1, <<Acc/binary, (Byte bxor Key)>>).

%% 各テキストを FIN 付き・マスク無しのテキストのフレームで送り返す。
%% 126 バイト未満の長さだけに対応する（送り返すのは短い応答だけ）。
send_texts(_Socket, []) -> ok;
send_texts(Socket, [Text | Rest]) when byte_size(Text) < 126 ->
    ok = gen_tcp:send(Socket, <<16#81, (byte_size(Text)), Text/binary>>),
    send_texts(Socket, Rest).
