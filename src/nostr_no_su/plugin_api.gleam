//// プラグインが呼ぶ本体側の口。プラグイン API v1 の任意エクスポート（本体が
//// プラグインを呼ぶ側）とは向きが逆で、ここはプラグインが本体を呼ぶ。仕様は
//// `docs/plugin-api.md` 第 14 章。

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Name, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import nostr_no_su/bunker
import nostr_no_su/nostr/event.{type Event}
import nostr_no_su/nostr/filter.{type Filter, Filter}
import nostr_no_su/relay_client
import nostr_no_su/relay_connection
import nostr_no_su/relay_list
import nostr_no_su/task
import nostr_no_su/time

/// リレーへ送信を依頼してから応答を集める時間の上限（ミリ秒）。送信は全接続へ
/// 同時に依頼するので、リレーの本数には比例しない。
const publish_timeout_ms = 1000

/// 接続を開いてから応答を集め終えるまでの時間の上限（ミリ秒）。`relay_client` の
/// `connect_timeout_ms`（3000ms）を含む。リレー 1 本ごとに並行に開くので本数には
/// 比例しない。`plugin_page_content` の 1 回の期限（5 秒）に収まるよう、
/// `close_timeout_ms` と `gather_margin_ms` を足しても 5 秒を割る値にする。
const fetch_timeout_ms = 3000

/// 集め終えた使い捨ての接続に購読の CLOSE と close フレームを送らせてから、
/// そのプロセスが止まるのを待つ時間の上限（ミリ秒）。過ぎたら kill する
/// （`relay_client.disconnect`）。取得の期限にはこの時間を足す。
const close_timeout_ms = 100

/// `publish_timeout_ms` と `fetch_timeout_ms` に足す余裕。集計を行う使い捨て
/// プロセスの結果を取りこぼさないためのもの。
const gather_margin_ms = 200

/// `install` が置いていないときの理由。
const not_installed = "the plugin API is not installed"

/// `pubkey` が文字列でないときの理由。
const pubkey_not_a_string = "pubkey must be a String"

/// `kind` が整数でないときの理由。
const kind_not_an_int = "kind must be an Int"

/// `pubkeys` が文字列のリストでないときの理由。
const pubkeys_not_a_list = "pubkeys must be a List of Strings"

/// 監視の用途のリレーが一覧に無いときの理由。
const no_monitor_relay_registered = "no monitor relay is registered"

/// 監視の用途のリレーはあるが、送信では生きたソケットに 1 本も渡せず、取得では
/// 1 本とも接続できず、または期限までに応答しなかったときの理由。
const no_monitor_relay_connected = "no monitor relay is connected"

/// 使い捨ての接続の上だけで使う購読 id。`fetch_events_sends_one_req_per_relay_test`
/// が偽のリレーの EOSE と期待する REQ を組むため公開する。
pub const fetch_subscription_id = "nostr-no-su-plugin-fetch"

/// リレーの一覧を持つアクターが応答しないときの理由。
const relay_list_not_responding = "the relay list is not responding"

/// `install` が persistent_term に置く固定キー。
fn installed_key() -> Atom {
  atom.create("nostr_no_su_plugin_api")
}

/// `install` が置く、この口が呼ぶ 2 つのアクターの名前。
type Installed {
  Installed(bunker: Name(bunker.Msg), relay_list: Name(relay_list.Msg))
}

/// バンカーと一覧の名前を persistent_term の固定キーに置く。本番の入口
/// （`nostr_no_su.main`）だけが呼ぶ。VM ごとに 1 度。
pub fn install(
  bunker: Name(bunker.Msg),
  relay_list: Name(relay_list.Msg),
) -> Nil {
  persistent_term_put(installed_key(), Ok(Installed(bunker:, relay_list:)))
  Nil
}

/// `install` が置いた名前。置いていなければ `Error(Nil)`。既定値を渡すので
/// キーが無いときに `badarg` で落ちない。
fn installed() -> Result(Installed, Nil) {
  persistent_term_get(installed_key(), Error(Nil))
}

/// `pubkey` の名義で `draft`（`kind` / `tags` / `content` を持つ binary キーの
/// map）を署名し、そのアカウントの監視の用途のリレーへ送る。`created_at` は
/// ここで入れる。戻り値は `{ok, EventMap}`（`event.to_map` の形）か
/// `{error, Reason}`。詳細は `docs/plugin-api.md` 第 14 章。
pub fn publish_event(
  pubkey: Dynamic,
  draft: Dynamic,
) -> Result(Dynamic, String) {
  case installed() {
    Error(Nil) -> Error(not_installed)
    Ok(Installed(bunker:, relay_list:)) ->
      publish_with(bunker, relay_list, pubkey, draft)
  }
}

/// `pubkey` の名義で書かれた `kind` のイベントのうち `created_at` が最新の 1 件を、
/// 監視の用途のリレーへ問い合わせて返す。問い合わせた `pubkey` と `kind` の両方に
/// 一致するイベントだけを候補にする。戻り値は `{ok, EventMap}`（`event.to_map`
/// の形）、1 件も無ければ `{ok, none}`、失敗は `{error, Reason}`。詳細は
/// `docs/plugin-api.md` 第 14 章。
pub fn fetch_event(pubkey: Dynamic, kind: Dynamic) -> Result(Dynamic, String) {
  case installed() {
    Error(Nil) -> Error(not_installed)
    Ok(Installed(bunker:, relay_list:)) ->
      fetch_with(bunker, relay_list, pubkey, kind)
  }
}

/// `pubkeys` の各公開鍵の名義で書かれた `kind` のイベントのうち `created_at` が
/// 最新の 1 件を、監視の用途のリレー 1 本につき REQ 1 件で問い合わせて返す。
/// 戻り値は `pubkeys` と同じ順の結果のリストを持つ `{ok, Results}` で、各要素は
/// `fetch_event` の戻り値と同じ形（未登録の公開鍵は `{error, Reason}`）。
/// 公開鍵によらない失敗は `{error, Reason}`。詳細は `docs/plugin-api.md` 第 14 章。
pub fn fetch_events(
  pubkeys: Dynamic,
  kind: Dynamic,
) -> Result(List(Result(Dynamic, String)), String) {
  case installed() {
    Error(Nil) -> Error(not_installed)
    Ok(Installed(bunker:, relay_list:)) ->
      fetch_events_with(bunker, relay_list, pubkeys, kind)
  }
}

/// `publish_event` の中身。名前を引数で受けるのでテストは `install` を経ずに
/// 直接叩ける。手順は (1) `pubkey` を文字列として読む、(2) `draft` を
/// デコードする、(3) バンカーに署名させる、(4) リレーの一覧を引く、(5) 監視の
/// 用途の接続が無ければ理由を返す、(6) 全接続へ同時に送って渡せた本数を数える、
/// (7) 0 本なら理由を返し、1 本以上なら署名済みイベントの map を返す。
pub fn publish_with(
  bunker_name: Name(bunker.Msg),
  relay_list_name: Name(relay_list.Msg),
  pubkey: Dynamic,
  draft: Dynamic,
) -> Result(Dynamic, String) {
  use pubkey <- result.try(
    decode.run(pubkey, decode.string)
    |> result.replace_error(pubkey_not_a_string),
  )
  use #(kind, tags, content) <- result.try(
    decode.run(draft, draft_decoder())
    |> result.map_error(event.describe_decode_errors),
  )
  use signed <- result.try(bunker.sign_event(
    bunker_name,
    pubkey,
    kind,
    tags,
    content,
  ))
  use entries <- result.try(
    relay_list.entries(relay_list_name)
    |> result.replace_error(relay_list_not_responding),
  )
  case relay_list.connections(entries, relay_list.Monitor) {
    [] -> Error(no_monitor_relay_registered)
    connections ->
      case broadcast(connections, signed) {
        0 -> Error(no_monitor_relay_connected)
        _ -> Ok(event.to_map(signed))
      }
  }
}

/// `fetch_event` の中身。名前を引数で受けるのでテストは `install` を経ずに直接
/// 叩ける。手順は (1) `pubkey` を文字列として読む（失敗は `pubkey_not_a_string`）、
/// (2) `kind` を整数として読む（失敗は `kind_not_an_int`）、(3) `bunker.check_account`
/// で登録を確かめる、(4) `ask_monitor_relays` で `pubkey` だけを作者に問い合わせる、
/// (5) 集めたイベントを `newest` に渡し、`fetched` の形で `Ok` にする。
pub fn fetch_with(
  bunker_name: Name(bunker.Msg),
  relay_list_name: Name(relay_list.Msg),
  pubkey: Dynamic,
  kind: Dynamic,
) -> Result(Dynamic, String) {
  use pubkey <- result.try(
    decode.run(pubkey, decode.string)
    |> result.replace_error(pubkey_not_a_string),
  )
  use kind <- result.try(
    decode.run(kind, decode.int)
    |> result.replace_error(kind_not_an_int),
  )
  use _ <- result.try(bunker.check_account(bunker_name, pubkey))
  use found <- result.try(ask_monitor_relays(relay_list_name, [pubkey], kind))
  Ok(fetched(newest(found)))
}

/// `fetch_events` の中身。名前を引数で受けるのでテストは `install` を経ずに直接
/// 叩ける。手順は (1) `pubkeys` を文字列のリストとして読む（失敗は
/// `pubkeys_not_a_list`）、(2) `kind` を整数として読む（失敗は
/// `kind_not_an_int`）、(3) `bunker.check_accounts` で登録を確かめる（読み込み前と
/// バンカーの無応答は全体の失敗）、(4) 登録済みの公開鍵を重複を除いて `pubkeys`
/// の順に並べ、1 件も無ければ問い合わせない、(5) 1 件以上なら
/// `ask_monitor_relays` でまとめて問い合わせる、(6) 公開鍵ごとに、未登録なら
/// 確認の理由を `Error` に、登録済みなら作者がその公開鍵のイベントを `newest`
/// に渡して `fetched` の形を `Ok` にし、`pubkeys` の順に並べる。
pub fn fetch_events_with(
  bunker_name: Name(bunker.Msg),
  relay_list_name: Name(relay_list.Msg),
  pubkeys: Dynamic,
  kind: Dynamic,
) -> Result(List(Result(Dynamic, String)), String) {
  use pubkeys <- result.try(
    decode.run(pubkeys, decode.list(decode.string))
    |> result.replace_error(pubkeys_not_a_list),
  )
  use kind <- result.try(
    decode.run(kind, decode.int)
    |> result.replace_error(kind_not_an_int),
  )
  use registrations <- result.try(bunker.check_accounts(bunker_name, pubkeys))
  let checks = list.zip(pubkeys, registrations)
  let authors =
    checks
    |> list.filter_map(fn(pair) {
      case pair {
        #(pubkey, Ok(Nil)) -> Ok(pubkey)
        #(_pubkey, Error(_reason)) -> Error(Nil)
      }
    })
    |> list.unique
  use found <- result.try(case authors {
    [] -> Ok([])
    _ -> ask_monitor_relays(relay_list_name, authors, kind)
  })
  Ok(
    list.map(checks, fn(pair) {
      case pair {
        #(pubkey, Ok(Nil)) ->
          Ok(
            fetched(
              newest(
                list.filter(found, fn(candidate) { candidate.pubkey == pubkey }),
              ),
            ),
          )
        #(_pubkey, Error(reason)) -> Error(reason)
      }
    }),
  )
}

/// 監視の用途のリレー 1 本ごとに `query` を 1 回、`task.start` で並行に行い、
/// 共通の期限まで待つ。一覧が引けなければ `relay_list_not_responding`、監視の
/// 用途のリレーが無ければ `no_monitor_relay_registered`、1 本も応答しなかった
/// （`relay_client.start` が失敗した本と、期限までに EOSE が届かなかった本を
/// 数える）なら `no_monitor_relay_connected` を返す。成功のときは、応答した本の
/// イベントをリレーの一覧の順に、同じリレーの中では届いた順に並べて返す。
fn ask_monitor_relays(
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
        list.map(urls, fn(url) {
          task.start(fn() { query(url, authors, kind, deadline) })
        })
        |> list.map(task.await(_, await_deadline))
        |> list.map(result.flatten)
      case result.values(outcomes) {
        [] -> Error(no_monitor_relay_connected)
        found -> Ok(list.flatten(found))
      }
    }
  }
}

/// `newest` の結果をプラグインへ返す値にする。見つかれば `event.to_map` の形、
/// 無ければ `none` の atom。
fn fetched(found: Option(Event)) -> Dynamic {
  case found {
    Some(found_event) -> event.to_map(found_event)
    None -> atom.to_dynamic(atom.create("none"))
  }
}

/// `created_at` が最大の 1 件。同じ `created_at` が複数あるときは `events` で先に
/// 現れたものを返す（厳密な `>` の比較）。`events` の並びはリレーの一覧の順で、
/// 同じリレーの中では届いた順であることが前提（`ask_monitor_relays` と `query`
/// が保つ。`fetch_events_with` は作者で絞るだけで並びを変えない）。
/// `newest_picks_the_greatest_created_at_test` が参照するため公開する。
pub fn newest(events: List(Event)) -> Option(Event) {
  list.fold(events, None, fn(current: Option(Event), candidate: Event) {
    case current {
      None -> Some(candidate)
      Some(kept) if candidate.created_at > kept.created_at -> Some(candidate)
      Some(_) -> current
    }
  })
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
      fn() { Ok([#(fetch_subscription_id, fetch_filter(authors, kind))]) },
      handle_incoming(_, authors, kind, reply),
      fn(_ack) { Nil },
      None,
      relay_client.subscription_retry_delay,
      relay_client.keepalive_interval_ms,
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
/// するとは限らない）。EOSE は `Ended` を送る。取得の照合のテストが `reply` を
/// 読んで確かめるため公開する。
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
/// `handle_incoming` のテストが参照するため公開する。
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
  let task.Deadline(at_ms:) = deadline
  case process.receive(reply, int.max(0, at_ms - time.monotonic_ms())) {
    Ok(Found(found_event)) -> collect(reply, deadline, [found_event, ..found])
    Ok(Ended) -> Ok(list.reverse(found))
    Error(Nil) -> Error(Nil)
  }
}

/// `kind` / `tags` / `content` を読む。失敗は `event.describe_decode_errors` で
/// 1 行にする（呼び出し側が行う）。
fn draft_decoder() -> decode.Decoder(#(Int, List(List(String)), String)) {
  use kind <- decode.field("kind", decode.int)
  use tags <- decode.field("tags", decode.list(decode.list(decode.string)))
  use content <- decode.field("content", decode.string)
  decode.success(#(kind, tags, content))
}

/// `signed` を `connections` の全接続へ同時に送り、生きたソケットに渡せた本数
/// を返す。返信先の subject は使い捨てプロセスの中で作り、期限の後に届く
/// 応答が呼び出し元のプロセスに残らないようにする。
fn broadcast(connections: List(relay_list.Connection), signed: Event) -> Int {
  task.start(fn() {
    let reply = process.new_subject()
    let asked =
      list.count(connections, fn(connection) {
        relay_connection.publish(connection.name, signed, reply)
      })
    gather(reply, asked, task.deadline_in(publish_timeout_ms))
  })
  |> task.await(task.deadline_in(publish_timeout_ms + gather_margin_ms))
  |> result.unwrap(0)
}

/// `reply` から応答を `remaining` 件受け取るか期限に達するまで待ち、受け取った
/// 中の `True` の数を返す。
fn gather(
  reply: Subject(Bool),
  remaining: Int,
  deadline: task.Deadline,
) -> Int {
  case remaining <= 0 {
    True -> 0
    False -> {
      let task.Deadline(at_ms:) = deadline
      case process.receive(reply, int.max(0, at_ms - time.monotonic_ms())) {
        Ok(True) -> 1 + gather(reply, remaining - 1, deadline)
        Ok(False) -> gather(reply, remaining - 1, deadline)
        Error(Nil) -> 0
      }
    }
  }
}

/// `persistent_term:put/2` の型を付けた薄いラッパー。
@external(erlang, "persistent_term", "put")
fn persistent_term_put(key: Atom, value: a) -> Atom

/// `persistent_term:get/2` の型を付けた薄いラッパー。既定値の版を使うので、
/// キーが無いときも `badarg` で落ちない。
@external(erlang, "persistent_term", "get")
fn persistent_term_get(key: Atom, default: a) -> a
