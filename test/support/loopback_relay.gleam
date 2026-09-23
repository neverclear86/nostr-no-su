//// `127.0.0.1` の OS が割り当てたポートで待ち受ける、テスト用の WebSocket の
//// リレー。`relay_client_test`、`plugin_api_test`、`avatars_test` が、クライアントが送った
//// フレームを見るのに使う。

import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/string
import mist
import nostr_no_su/nostr/event.{type Event}
import nostr_no_su/plugin_api

/// `127.0.0.1` の OS が割り当てたポートで待ち受けるテスト用の WebSocket サーバー。
pub type Relay {
  Relay(server: Pid, url: String)
}

/// `127.0.0.1` の OS が割り当てたポートで WebSocket サーバーを立てる。接続を
/// 受け入れるたびに `on_connect` を、テキストフレームを受け取るたびに `on_text` を
/// 呼ぶ。
pub fn start_relay_with(
  on_connect: fn() -> Nil,
  on_text: fn(mist.WebsocketConnection, String) -> Nil,
) -> Relay {
  let ports = process.new_subject()
  let assert Ok(started) =
    mist.new(fn(request) {
      mist.websocket(
        request: request,
        handler: fn(state, received, connection) {
          case received {
            mist.Text(text) -> on_text(connection, text)
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

/// `127.0.0.1` の OS が割り当てたポートで WebSocket サーバーを立てる。受け取った
/// テキストフレームをテストへ転送する。
pub fn start_relay(frames: Subject(String)) -> Relay {
  start_relay_with(fn() { Nil }, fn(_connection, text) {
    process.send(frames, text)
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
  start_relay_with(
    fn() { process.send(connections, Nil) },
    fn(connection, text) {
      process.send(frames, text)
      case string.starts_with(text, "[\"REQ\"") {
        True -> {
          list.each(events, fn(stored) {
            let _ =
              mist.send_text_frame(
                connection,
                json.preprocessed_array([
                  json.string("EVENT"),
                  json.string(plugin_api.fetch_subscription_id),
                  event.to_json(stored),
                ])
                  |> json.to_string,
              )
            Nil
          })
          let _ =
            mist.send_text_frame(
              connection,
              json.preprocessed_array([
                json.string("EOSE"),
                json.string(plugin_api.fetch_subscription_id),
              ])
                |> json.to_string,
            )
          Nil
        }
        False -> Nil
      }
    },
  )
}
