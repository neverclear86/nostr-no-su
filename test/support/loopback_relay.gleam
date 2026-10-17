//// `127.0.0.1` の OS が割り当てたポートで待ち受ける、テスト用の WebSocket の
//// リレー。クライアントが送ったテキストフレームを見る。リレーが返すフレームは、
//// 受けたテキストごとに `reply` の関数で決める。

import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/string
import mist
import nostr_no_su/nostr/event.{type Event}
import nostr_no_su/relay_fetch

/// `127.0.0.1` の OS が割り当てたポートで待ち受けるテスト用の WebSocket サーバー。
pub type Relay {
  Relay(server: Pid, url: String)
}

/// リレーが受けたテキストに返す 1 フレーム。
pub type ReplyFrame {
  SendText(String)
  SendBinary(BitArray)
}

/// `127.0.0.1` の OS が割り当てたポートで WebSocket サーバーを立てる。接続を
/// 受け入れるたびに `on_connect` を呼び、テキストフレームを受け取るたびに `reply` に
/// 渡して、返った順にフレームを送り返す。`reply` は受けたテキストをテストへ転送する
/// などの副作用を持ってよい。クライアントが先に切ることがあるので、送信の失敗は
/// 無視する。
pub fn start_relay_replying(
  on_connect: fn() -> Nil,
  reply: fn(String) -> List(ReplyFrame),
) -> Relay {
  let ports = process.new_subject()
  let assert Ok(started) =
    mist.new(fn(request) {
      mist.websocket(
        request: request,
        handler: fn(state, received, connection) {
          case received {
            mist.Text(text) ->
              list.each(reply(text), fn(frame) {
                let _ = case frame {
                  SendText(payload) -> mist.send_text_frame(connection, payload)
                  SendBinary(payload) ->
                    mist.send_binary_frame(connection, payload)
                }
                Nil
              })
            _ -> Nil
          }
          mist.continue(state)
        },
        on_init: fn(_connection) {
          on_connect()
          #(Nil, None)
        },
        on_close: fn(_state) { Nil },
      )
    })
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _scheme, _address) {
      process.send(ports, port)
    })
    |> mist.start
  let assert Ok(port) = process.receive(ports, 2000)
  Relay(server: started.pid, url: "ws://127.0.0.1:" <> int.to_string(port))
}

/// 受けたテキストが `prefix` で始まるときだけ `frames` を返し、ほかには何も返さない
/// `reply` の関数。
pub fn replies_to(prefix: String, frames: List(a)) -> fn(String) -> List(a) {
  fn(text) {
    case string.starts_with(text, prefix) {
      True -> frames
      False -> []
    }
  }
}

/// `127.0.0.1` の OS が割り当てたポートで WebSocket サーバーを立てる。受け取った
/// テキストフレームをテストへ転送する。
pub fn start_relay(frames: Subject(String)) -> Relay {
  start_relay_replying(fn() { Nil }, fn(text) {
    process.send(frames, text)
    []
  })
}

/// サーバーを親プロセスと同じ方法で止める。スーパーバイザーは親からの normal な
/// exit を順序立った停止に変えるので、kill と違ってクラッシュレポートを出さない。
pub fn stop_relay(relay: Relay) -> Nil {
  process.unlink(relay.server)
  process.send_exit(relay.server)
}

/// 取得の問い合わせに答えるループバックのリレー。接続ごとに `connections` へ
/// 送り、受けたテキストフレームを `frames` へ転送し、REQ には `events` を
/// `fetch_subscription_id` の EVENT で返してから EOSE を返す。
pub fn start_fetch_relay(
  frames: Subject(String),
  connections: Subject(Nil),
  events: List(Event),
) -> Relay {
  let stored_frames =
    list.map(events, fn(stored) {
      SendText(
        json.preprocessed_array([
          json.string("EVENT"),
          json.string(relay_fetch.fetch_subscription_id),
          event.to_json(stored),
        ])
        |> json.to_string,
      )
    })
  let eose =
    SendText(
      json.preprocessed_array([
        json.string("EOSE"),
        json.string(relay_fetch.fetch_subscription_id),
      ])
      |> json.to_string,
    )
  let answer = replies_to("[\"REQ\"", list.append(stored_frames, [eose]))
  start_relay_replying(fn() { process.send(connections, Nil) }, fn(text) {
    process.send(frames, text)
    answer(text)
  })
}
