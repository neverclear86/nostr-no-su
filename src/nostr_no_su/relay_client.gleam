import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import nostr_no_su/nostr/event
import nostr_no_su/nostr/filter.{type Filter}
import nostr_no_su/nostr/message
import stratus

pub type Msg {
  Subscribe
  Publish(event: event.Event)
}

/// 起動済みの接続。操作は `publish` を通じて行い、その背後のプロセスを
/// `relay_connection` が切断検知のために監視する。
pub type Connection =
  Subject(stratus.InternalMessage(Msg))

/// 開くべき購読を生成するサンク。接続・再接続のたびに再評価するため、時刻に
/// 依存するフィルター（`since` など）が常に最新に保たれる。
pub type Subscriptions =
  fn() -> List(#(String, Filter))

/// ハンドシェイクに許す時間。`start` は呼び出し元を最大でこの時間（さらに
/// stratus が上乗せする 100ms）ブロックする。呼び出し元はスーパーバイザー配下の
/// アクターであり、ブロック中はスーパーバイザーの停止要求に応答できないため、
/// この値はワーカーの停止タイムアウト 5000ms（`relay_connection.supervised` を
/// 参照）より小さくしておく必要がある。さもないと、応答しないリレーを待っている
/// 接続の停止が強制 kill で終わる。
const connect_timeout_ms = 3000

/// リレー URL を stratus が期待する http(s) リクエストに変換する。gleam_http は
/// http(s) スキームしかパースせず、stratus は Https を wss/TLS に対応付ける。
pub fn to_request(url: String) -> Result(Request(String), Nil) {
  case string.split_once(url, "://") {
    Ok(#("wss", rest)) -> request.to("https://" <> rest)
    Ok(#("ws", rest)) -> request.to("http://" <> rest)
    _ -> request.to(url)
  }
}

/// スキームを取り除いたリレー URL。複数の接続が開いているときに、ログ行がどの
/// リレーのものか示すために使う。
pub fn label(url: String) -> String {
  case string.split_once(url, "://") {
    Ok(#(_scheme, rest)) -> rest
    Error(_) -> url
  }
}

/// 指定のリレーに接続し、指定の購読を開き、検証済みイベントを `handle_event`
/// へ渡す。接続アクターは呼び出し元にリンクされるため呼び出し元と一緒に死に、
/// exit を trap している呼び出し元にはその死がメッセージとして届く。
pub fn start(
  url: String,
  subscriptions: Subscriptions,
  handle_event: fn(event.Event) -> Nil,
) -> Result(Connection, String) {
  use req <- result.try(
    to_request(url)
    |> result.replace_error("invalid relay url: " <> url),
  )
  let relay = label(url)
  let builder =
    stratus.new(req, Nil)
    |> stratus.with_connect_timeout(connect_timeout_ms)
    |> stratus.on_message(fn(state, msg, conn) {
      case msg {
        stratus.User(Subscribe) -> {
          list.each(subscriptions(), fn(subscription) {
            let text =
              message.encode_client_message(message.Req(
                subscription.0,
                subscription.1,
              ))
            let _ = stratus.send_text_message(conn, text)
          })
          stratus.continue(state)
        }
        stratus.User(Publish(published)) -> {
          let text = message.encode_client_message(message.Publish(published))
          let _ = stratus.send_text_message(conn, text)
          stratus.continue(state)
        }
        stratus.Text(text) -> {
          handle_text(relay, text, handle_event)
          stratus.continue(state)
        }
        stratus.Binary(_) -> stratus.continue(state)
      }
    })
    |> stratus.on_close(fn(_state, reason) {
      io.println(
        "[relay " <> relay <> "] connection closed: " <> string.inspect(reason),
      )
    })

  case stratus.start(builder) {
    Ok(started) -> {
      process.send(started.data, stratus.to_user_message(Subscribe))
      Ok(started.data)
    }
    Error(error) -> Error(string.inspect(error))
  }
}

/// 接続に対し、そのソケットからイベントを送信するよう依頼する。
pub fn publish(connection: Connection, published: event.Event) -> Nil {
  process.send(connection, stratus.to_user_message(Publish(published)))
}

/// リレーメッセージを 1 件デコードする。検証済みイベントは `handle_event` へ
/// 渡し、それ以外は送信元のリレー名を添えてログ出力する。
fn handle_text(
  relay: String,
  text: String,
  handle_event: fn(event.Event) -> Nil,
) -> Nil {
  case message.decode_relay_message(text) {
    Ok(message.RelayEvent(_, received)) ->
      case event.compute_id(received) == received.id {
        True -> handle_event(received)
        False ->
          io.println(
            "[relay "
            <> relay
            <> "] dropped event with invalid id: "
            <> received.id,
          )
      }
    Ok(message.RelayEose(subscription)) ->
      io.println(
        "[relay " <> relay <> "] end of stored events for " <> subscription,
      )
    Ok(message.RelayOk(id, False, reason)) ->
      io.println(
        "[relay " <> relay <> "] rejected event " <> id <> ": " <> reason,
      )
    Ok(other) -> io.println("[relay " <> relay <> "] " <> string.inspect(other))
    Error(_) ->
      io.println(
        "[relay "
        <> relay
        <> "] unrecognised message: "
        <> string.slice(text, 0, 120),
      )
  }
}
