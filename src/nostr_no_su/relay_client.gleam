import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/list
import gleam/result
import gleam/string
import nostr_no_su/log
import nostr_no_su/nostr/event
import nostr_no_su/nostr/filter.{type Filter}
import nostr_no_su/nostr/message
import stratus

pub type Msg {
  Subscribe
  Publish(event: event.Event)
}

/// 起動済みのリレークライアント。イベントの送信は `publish` を通じて行い、
/// その背後のプロセスを `relay_connection` が切断検知のために監視する。
pub type Client =
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
) -> Result(Client, String) {
  use req <- result.try(
    to_request(url)
    |> result.replace_error("invalid relay url: " <> url),
  )
  let prefix = log.relay_prefix(label(url))
  let builder =
    stratus.new(req, Nil)
    |> stratus.with_connect_timeout(connect_timeout_ms)
    |> stratus.on_message(fn(state, msg, conn) {
      case msg {
        stratus.User(Subscribe) -> {
          list.each(subscriptions(), fn(subscription) {
            message.Req(subscription.0, subscription.1)
            |> message.encode_client_message
            |> send_text(conn, prefix, "subscription " <> subscription.0, _)
          })
          stratus.continue(state)
        }
        stratus.User(Publish(published)) -> {
          message.Publish(published)
          |> message.encode_client_message
          |> send_text(conn, prefix, "event " <> published.id, _)
          stratus.continue(state)
        }
        stratus.Text(text) -> {
          handle_text(prefix, text, handle_event)
          stratus.continue(state)
        }
        stratus.Binary(_) -> stratus.continue(state)
      }
    })
    |> stratus.on_close(fn(_state, reason) {
      log.println(prefix, "connection closed: " <> string.inspect(reason))
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
pub fn publish(client: Client, published: event.Event) -> Nil {
  process.send(client, stratus.to_user_message(Publish(published)))
}

/// ソケットへ 1 件書き込む。書けなかった購読や応答はリレーから見れば存在しない
/// のと同じで、黙って捨てると原因を追えないため、何を送ろうとしたかを添えて
/// ログに残す。
fn send_text(
  connection: stratus.Connection,
  prefix: String,
  what: String,
  text: String,
) -> Nil {
  case stratus.send_text_message(connection, text) {
    Ok(Nil) -> Nil
    Error(reason) ->
      log.println(
        prefix,
        "failed to send " <> what <> ": " <> string.inspect(reason),
      )
  }
}

/// リレーメッセージを 1 件デコードする。検証済みイベントは `handle_event` へ
/// 渡し、それ以外は送信元のリレー名を添えてログ出力する。
fn handle_text(
  prefix: String,
  text: String,
  handle_event: fn(event.Event) -> Nil,
) -> Nil {
  case message.decode_relay_message(text) {
    Ok(message.RelayEvent(_, received)) ->
      case event.compute_id(received) == received.id {
        True -> handle_event(received)
        False ->
          log.println(prefix, "dropped event with invalid id: " <> received.id)
      }
    Ok(message.RelayEose(subscription)) ->
      log.println(prefix, "end of stored events for " <> subscription)
    Ok(message.RelayOk(id, False, reason)) ->
      log.println(prefix, "rejected event " <> id <> ": " <> reason)
    // 受理は発行 1 件につき 1 行増えるだけで何も伝えないため、出力しない。
    Ok(message.RelayOk(_id, True, _message)) -> Nil
    Ok(message.RelayNotice(text)) -> log.println(prefix, "notice: " <> text)
    Ok(message.RelayClosed(subscription, reason)) ->
      log.println(
        prefix,
        "subscription " <> subscription <> " closed: " <> reason,
      )
    Error(_) ->
      log.println(
        prefix,
        "unrecognised message: " <> string.slice(text, 0, 120),
      )
  }
}
