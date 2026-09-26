//// 応答の配送の純粋な部品。バンカーの接続の範囲（`RelayScope`）、応答を出すリレーの
//// 選び方、リレーの URL ごとのセッションの署名者、発行した応答への OK の追跡、
//// リレーの AUTH に返すイベントの署名を持つ。プロセスも時計も持たず、時刻は呼び出し
//// 側が Unix 秒で渡す。

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import nostr_no_su/bunker/account.{type Account}
import nostr_no_su/bunker/engine
import nostr_no_su/log
import nostr_no_su/nostr/event.{type Event}
import nostr_no_su/relay_client.{type Acknowledgement}

/// OK を待つ期間（秒）。OK は通常すぐ返るので、発行からこの秒数で返らない OK は
/// 返らないとみなす（値は判定の取りこぼしと保持量の兼ね合いで選んだ）。
const acknowledgement_timeout_seconds = 60

/// バンカーの接続が受け持つ範囲。
pub type RelayScope {
  /// 基本のバンカーリレー（`relay_list` のバンカーの用途の項目）の接続。全署名者の
  /// `#p` を購読し、全アカウントで AUTH し、すべての応答を出す。
  BaseRelay
  /// 基本のバンカーリレーに無い、セッションのリレー（接続の前の取り置きを含む）の
  /// 接続。その URL を持つセッションと取り置きの署名者だけで購読と AUTH を行い、
  /// そのセッションへの応答だけを出す。
  SessionRelay
}

/// OK を待っている応答の一覧。キーは応答 id。
pub opaque type Deliveries {
  Deliveries(Dict(String, Delivery))
}

/// 発行した応答 1 件の追跡。`client` は宛先のクライアント pubkey、`awaiting` は
/// まだ OK を返していないリレーの URL、`rejections` は `#(relay_url, reason)` を
/// 届いた逆順に積んだ拒否、`published_at` は発行時刻（秒）。
type Delivery {
  Delivery(
    client: String,
    awaiting: Set(String),
    rejections: List(#(String, String)),
    published_at: Int,
  )
}

/// 何も待っていない一覧。
pub fn new_deliveries() -> Deliveries {
  Deliveries(dict.new())
}

/// 応答を `relay_urls` に発行したことを記録する。記録の前に、発行から
/// `acknowledgement_timeout_seconds` 以上経った項目を捨てる。
pub fn track(
  deliveries: Deliveries,
  response: Event,
  relay_urls: List(String),
  now: Int,
) -> Deliveries {
  let Deliveries(entries) = deliveries
  let fresh =
    dict.filter(entries, fn(_id, delivery) {
      delivery.published_at + acknowledgement_timeout_seconds > now
    })
  Deliveries(dict.insert(
    fresh,
    response.id,
    Delivery(
      client: recipient(response),
      awaiting: set.from_list(relay_urls),
      rejections: [],
      published_at: now,
    ),
  ))
}

/// OK 1 件を反映し、送った先の全リレーが拒否し終えたら出すログ行を返す。id が
/// 一覧に無ければ（掃除済み、監視と無関係の OK）そのまま返す。受理は項目を消す。
/// 拒否は未応答からそのリレーを外して積み、未応答が空になった時点で項目を消して
/// ログ行を返す。すでに未応答に無いリレーからの拒否（同じリレーからの 2 度目）は
/// 数えない。
pub fn acknowledge(
  deliveries: Deliveries,
  relay_url: String,
  ack: Acknowledgement,
) -> #(Deliveries, Option(String)) {
  let Deliveries(entries) = deliveries
  case dict.get(entries, ack.event_id), ack.accepted {
    Error(Nil), _ -> #(deliveries, None)
    Ok(_delivery), True -> #(
      Deliveries(dict.delete(entries, ack.event_id)),
      None,
    )
    Ok(delivery), False ->
      case set.contains(delivery.awaiting, relay_url) {
        False -> #(deliveries, None)
        True -> {
          let remaining = set.delete(delivery.awaiting, relay_url)
          let updated =
            Delivery(..delivery, awaiting: remaining, rejections: [
              #(relay_url, ack.message),
              ..delivery.rejections
            ])
          case set.is_empty(remaining) {
            False -> #(
              Deliveries(dict.insert(entries, ack.event_id, updated)),
              None,
            )
            True -> #(
              Deliveries(dict.delete(entries, ack.event_id)),
              Some(rejected_line(ack.event_id, updated)),
            )
          }
        }
      }
  }
}

/// 応答の宛先のクライアント pubkey。最初の `["p", pubkey, ..]` タグから取り、
/// 無ければ `unknown`。
pub fn recipient(response: Event) -> String {
  case engine.p_tag_pubkeys(response.tags) {
    [pubkey, ..] -> pubkey
    [] -> "unknown"
  }
}

/// 全リレーに拒否された応答の行。拒否は届いた順に並べる。
fn rejected_line(id: String, delivery: Delivery) -> String {
  let reasons =
    delivery.rejections
    |> list.reverse
    |> list.map(fn(rejection) {
      let #(relay_url, reason) = rejection
      log.relay_label(relay_url) <> ": " <> reason
    })
    |> string.join("; ")
  "response "
  <> id
  <> " to "
  <> delivery.client
  <> " was rejected by every relay: "
  <> reasons
}

/// （署名者, リレーの一覧）の組から、リレーの URL ごとにその URL を持つセッションの
/// 署名者を重複なしの昇順で並べた写像を作る。リレーの無いセッションは何も足さない。
/// URL は文字列のまま比べる。
pub fn session_relay_signers(
  sessions: List(#(String, List(String))),
) -> Dict(String, List(String)) {
  sessions
  |> list.fold(dict.new(), fn(acc, session) {
    let #(signer, relays) = session
    use acc, relay_url <- list.fold(relays, acc)
    dict.upsert(acc, relay_url, fn(current) {
      [signer, ..option.unwrap(current, [])]
    })
  })
  |> dict.map_values(fn(_relay_url, signers) {
    signers |> list.unique |> list.sort(string.compare)
  })
}

/// 応答 1 件を出すリレーの URL を `publishers` の順に選ぶ。`BaseRelay` はすべて、
/// `SessionRelay` は応答先のセッションのリレー（`session_relays`）にあるものだけを
/// 選ぶ。
pub fn response_relays(
  publishers: List(#(String, RelayScope)),
  session_relays: List(String),
) -> List(String) {
  use #(relay_url, scope) <- list.filter_map(publishers)
  case scope, list.contains(session_relays, relay_url) {
    BaseRelay, _ | SessionRelay, True -> Ok(relay_url)
    SessionRelay, False -> Error(Nil)
  }
}

/// アカウントごとに、リレーの AUTH に返す kind 22242 を組み立てて署名する。
/// 署名に失敗したアカウントがあれば理由を返す。
pub fn authentication_events(
  accounts: List(Account),
  relay_url: String,
  challenge: String,
  now: Int,
) -> Result(List(Event), String) {
  use signer <- list.try_map(accounts)
  engine.sign_as(
    signer,
    event.auth_kind,
    [["relay", relay_url], ["challenge", challenge]],
    "",
    now,
  )
  |> result.replace_error("failed to sign authentication event")
}
