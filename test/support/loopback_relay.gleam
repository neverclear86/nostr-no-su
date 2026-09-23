//// `127.0.0.1` の OS が割り当てたポートで待ち受ける、テスト用の WebSocket の
//// リレー。`relay_client_test` と `plugin_api_test` が、クライアントが送った
//// フレームを見るのに使う。

import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/option.{None}
import mist

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
