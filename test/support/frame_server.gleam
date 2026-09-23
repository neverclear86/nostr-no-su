//// 受けた WebSocket のフレームをテストへ転送する偽リレー
//// （`websocket_frame_server.erl`）の口。mist の偽リレーは close フレームと
//// TCP の切断を区別できないので、接続の閉じ方を確かめるテストはこちらを使う。

import gleam/erlang/process.{type Subject}
import gleam/int

/// 偽リレーが受けたフレーム 1 件。`payload` はマスクを外した中身。
pub type Frame {
  Frame(opcode: Int, payload: BitArray)
}

/// `127.0.0.1` の OS が割り当てたポートで偽リレーを立て、`ws://` の URL を
/// 返す。受けたフレームを 1 件ずつ `frames` へ送り、テキストのフレームには
/// `reply` が返すテキストを順に送り返す。
pub fn start(
  frames: Subject(Frame),
  reply: fn(String) -> List(String),
) -> String {
  let port =
    listen(
      fn(opcode, payload) { process.send(frames, Frame(opcode, payload)) },
      reply,
    )
  "ws://127.0.0.1:" <> int.to_string(port)
}

/// `websocket_frame_server:listen/2`。受けたフレームごとに `on_frame` を呼び、
/// ポート番号を返す。
@external(erlang, "websocket_frame_server", "listen")
fn listen(
  on_frame: fn(Int, BitArray) -> Nil,
  reply: fn(String) -> List(String),
) -> Int
