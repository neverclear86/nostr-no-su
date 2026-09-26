//// 監視の用途のリレーへの使い捨ての取得の問い合わせ。リレー 1 本ごとに接続を開いて REQ を 1 件
//// 送り、EOSE か期限まで集めて閉じる。集めたイベントから作者ごとの最新の 1 件も選ぶ。
//// 失敗の理由の文字列は、監視の用途のリレーへの送信の失敗にも同じものを使うので公開する。

import gleam/erlang/process.{type Name, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import nostr_no_su/nostr/event.{type Event}
import nostr_no_su/nostr/filter.{type Filter, Filter}
import nostr_no_su/relay_client
import nostr_no_su/relay_list
import nostr_no_su/task

/// 接続を開いてから応答を集め終えるまでの時間の上限（ミリ秒）。`relay_client` の
/// `connect_timeout_ms`（3000ms）を含む。リレー 1 本ごとに並行に開くので本数には
/// 比例しない。`plugin_page_content` の 1 回の期限（5 秒）に収まるよう、
/// `close_timeout_ms` と `gather_margin_ms` を足しても 5 秒を割る値にする。
const fetch_timeout_ms = 3000

/// 集め終えた使い捨ての接続に購読の CLOSE と close フレームを送らせてから、
/// そのプロセスが止まるのを待つ時間の上限（ミリ秒）。過ぎたら kill する
/// （`relay_client.disconnect`）。取得の期限にはこの時間を足す。
const close_timeout_ms = 100

/// `fetch_timeout_ms` と `close_timeout_ms` に足す余裕。問い合わせを行う使い捨て
/// プロセスの結果を取りこぼさないためのもの。
const gather_margin_ms = 200

/// 監視の用途のリレーが一覧に無いときの理由。
pub const no_monitor_relay_registered = "no monitor relay is registered"

/// 監視の用途のリレーはあるが、送信では生きたソケットに 1 本も渡せず、取得では
/// 1 本とも接続できず、または期限までに応答しなかったときの理由。
pub const no_monitor_relay_connected = "no monitor relay is connected"

/// リレーの一覧を持つアクターが応答しないときの理由。
pub const relay_list_not_responding = "the relay list is not responding"

/// 使い捨ての接続の上だけで使う購読 id。
pub const fetch_subscription_id = "nostr-no-su-plugin-fetch"

/// 監視の用途のリレー 1 本ごとに `query` を 1 回、`task.map_within` で並行に行い、
/// 共通の期限まで待つ。一覧が引けなければ `relay_list_not_responding`、監視の
/// 用途のリレーが無ければ `no_monitor_relay_registered`、1 本も応答しなかった
/// （`relay_client.start` が失敗した本と、期限までに EOSE が届かなかった本を
/// 数える）なら `no_monitor_relay_connected` を返す。成功のときは、応答した本の
/// イベントをリレーの一覧の順に、同じリレーの中では届いた順に並べて返す。
pub fn ask_monitor_relays(
  relay_list_name: Name(relay_list.Msg),
  authors: List(String),
  kind: Int,
) -> Result(List(Event), String) {
  use entries <- result.try(
    relay_list.entries(relay_list_name)
    |> result.replace_error(relay_list_not_responding),
  )
  case relay_list.urls(entries, relay_list.Monitor) {
    [] -> Error(no_monitor_relay_registered)
    urls -> {
      let deadline = task.deadline_in(fetch_timeout_ms)
      let await_deadline =
        task.deadline_in(fetch_timeout_ms + close_timeout_ms + gather_margin_ms)
      let outcomes =
        task.map_within(urls, await_deadline, query(_, authors, kind, deadline))
        |> list.map(result.flatten)
      case result.values(outcomes) {
        [] -> Error(no_monitor_relay_connected)
        found -> Ok(list.flatten(found))
      }
    }
  }
}

/// `created_at` が最大の 1 件。同じ `created_at` が複数あるときは `events` で先に
/// 現れたものを返す（厳密な `>` の比較）。`events` の並びはリレーの一覧の順で、
/// 同じリレーの中では届いた順であることが前提（`ask_monitor_relays` と `query`
/// が保つ。`newest_by` は作者で絞るだけで並びを変えない）。
pub fn newest(events: List(Event)) -> Option(Event) {
  list.fold(events, None, fn(current: Option(Event), candidate: Event) {
    case current {
      None -> Some(candidate)
      Some(kept) if candidate.created_at > kept.created_at -> Some(candidate)
      Some(_) -> current
    }
  })
}

/// `events` のうち作者が `author` のものの `newest`。
pub fn newest_by(events: List(Event), author: String) -> Option(Event) {
  newest(list.filter(events, fn(candidate) { candidate.pubkey == author }))
}

/// `authors` の名義で書かれた `kind` のイベントを求める REQ のフィルター。
/// `limit` は `authors` の件数で、1 件の取得では 1 になる。replaceable の kind
/// ではリレーが作者ごとに最新の 1 件だけを持つので、作者ごとの最新がすべて返る。
fn fetch_filter(authors: List(String), kind: Int) -> Filter {
  Filter(
    ..filter.new(),
    authors: Some(authors),
    kinds: Some([kind]),
    limit: Some(list.length(authors)),
  )
}

/// 監視の用途のリレー 1 本への使い捨ての問い合わせ。接続を開き、`authors` の
/// 名義の `kind` のイベントを求める REQ（`fetch_filter`）を 1 件送り、`Ended`
/// （EOSE）を受けるか期限に達するまで集め、`relay_client.disconnect` で購読の
/// CLOSE と close フレームを送って接続を閉じる（`close_timeout_ms` までに止まら
/// なければ kill する）。届くイベントは `handle_incoming` が作者が `authors` に
/// あり `kind` が一致するものだけを `Found` にする。`collect` が `Ended` を受けずに
/// 期限に達したときは、集めたイベントを捨てて `Error(Nil)` を返す（保存済みの
/// イベントの直後に EOSE が届くので、期限までに EOSE が無い本は応答しなかった本
/// として数える）。
/// `relay_client.start` が失敗したときも `Error(Nil)`。
fn query(
  url: String,
  authors: List(String),
  kind: Int,
  deadline: task.Deadline,
) -> Result(List(Event), Nil) {
  // `stratus.start` は呼び出し元（この使い捨てプロセス）にリンクするので、EOSE の
  // 直後にリレーがソケットを閉じると道連れで落ち、集めたイベントごと失われる。
  // `relay_connection.gleam` が同じ理由で exit を trap している。trap した exit の
  // メッセージは下の `process.receive` に一致しないので、そのまま放置する。
  process.trap_exits(True)
  let reply = process.new_subject()
  use client <- result.try(
    relay_client.start(
      url,
      relay_client.Handlers(
        subscriptions: fn() {
          Ok([#(fetch_subscription_id, fetch_filter(authors, kind))])
        },
        handle_incoming: handle_incoming(_, authors, kind, reply),
        handle_ok: fn(_ack) { Nil },
        authenticator: None,
      ),
      relay_client.default_timing,
    )
    |> result.replace_error(Nil),
  )
  let collected = collect(reply, deadline, [])
  relay_client.disconnect(client, close_timeout_ms)
  collected
}

/// `query` の `handle_incoming`。届いたイベントのうち、作者が問い合わせた
/// `authors` にあり、`kind` が一致するものだけを `Found` として `reply` に送る。
/// 一致しないイベントは捨てる（リレーが返すイベントは REQ のフィルターと一致
/// するとは限らない）。EOSE は `Ended` を送る。
pub fn handle_incoming(
  received: relay_client.Received,
  authors: List(String),
  kind: Int,
  reply: Subject(Incoming),
) -> Nil {
  case received {
    relay_client.ReceivedEvent(subscription_id: _, event: verified) -> {
      let candidate = event.verified_event(verified)
      case list.contains(authors, candidate.pubkey) && candidate.kind == kind {
        True -> process.send(reply, Found(candidate))
        False -> Nil
      }
    }
    relay_client.ReceivedEose(subscription_id: _) -> process.send(reply, Ended)
  }
}

/// `query` の中の合図。`handle_incoming` が `reply` に送り、`collect` が受け取る。
pub type Incoming {
  Found(event: Event)
  Ended
}

/// `reply` から `Ended` を受けるか期限に達するまで受け取り続ける。`Ended` を受けた
/// ときだけ、届いた順に並べた `found` を `Ok` で返す。期限に達したときは `found` を
/// 捨てて `Error(Nil)` を返す。
fn collect(
  reply: Subject(Incoming),
  deadline: task.Deadline,
  found: List(Event),
) -> Result(List(Event), Nil) {
  case task.receive(reply, deadline) {
    Ok(Found(found_event)) -> collect(reply, deadline, [found_event, ..found])
    Ok(Ended) -> Ok(list.reverse(found))
    Error(Nil) -> Error(Nil)
  }
}
