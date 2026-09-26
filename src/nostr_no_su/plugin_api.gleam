//// プラグインが呼ぶ本体側の口。プラグイン API v1 の任意エクスポート（本体が
//// プラグインを呼ぶ側）とは向きが逆で、ここはプラグインが本体を呼ぶ。仕様は
//// `docs/plugin-api.md` 第 14 章。

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Name, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import nostr_no_su/bunker
import nostr_no_su/nostr/event.{type Event}
import nostr_no_su/persistent_term
import nostr_no_su/relay_connection
import nostr_no_su/relay_fetch
import nostr_no_su/relay_list
import nostr_no_su/task

/// リレーへ送信を依頼してから応答を集める時間の上限（ミリ秒）。送信は全接続へ
/// 同時に依頼するので、リレーの本数には比例しない。
const publish_timeout_ms = 1000

/// `publish_timeout_ms` に足す余裕。集計を行う使い捨てプロセスの結果を取りこぼさない
/// ためのもの。
const gather_margin_ms = 200

/// `install` が置いていないときの理由。
const not_installed = "the plugin API is not installed"

/// `pubkey` が文字列でないときの理由。
const pubkey_not_a_string = "pubkey must be a String"

/// `kind` が整数でないときの理由。
const kind_not_an_int = "kind must be an Int"

/// `pubkeys` が文字列のリストでないときの理由。
const pubkeys_not_a_list = "pubkeys must be a List of Strings"

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
  persistent_term.put(installed_key(), Ok(Installed(bunker:, relay_list:)))
  Nil
}

/// `install` が置いた名前。置いていなければ `not_installed` を理由に返す。既定値を渡すので
/// キーが無いときに `badarg` で落ちない。
fn installed() -> Result(Installed, String) {
  persistent_term.get(installed_key(), Error(not_installed))
}

/// `pubkey` の名義で `draft`（`kind` / `tags` / `content` を持つ binary キーの
/// map）を署名し、そのアカウントの監視の用途のリレーへ送る。`created_at` は
/// ここで入れる。戻り値は `{ok, EventMap}`（`event.to_map` の形）か
/// `{error, Reason}`。詳細は `docs/plugin-api.md` 第 14 章。
pub fn publish_event(
  pubkey: Dynamic,
  draft: Dynamic,
) -> Result(Dynamic, String) {
  use Installed(bunker:, relay_list:) <- result.try(installed())
  publish_with(bunker, relay_list, pubkey, draft)
}

/// `pubkey` の名義で書かれた `kind` のイベントのうち `created_at` が最新の 1 件を、
/// 監視の用途のリレーへ問い合わせて返す。問い合わせた `pubkey` と `kind` の両方に
/// 一致するイベントだけを候補にする。戻り値は `{ok, EventMap}`（`event.to_map`
/// の形）、1 件も無ければ `{ok, none}`、失敗は `{error, Reason}`。詳細は
/// `docs/plugin-api.md` 第 14 章。
pub fn fetch_event(pubkey: Dynamic, kind: Dynamic) -> Result(Dynamic, String) {
  use Installed(bunker:, relay_list:) <- result.try(installed())
  fetch_with(bunker, relay_list, pubkey, kind)
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
  use Installed(bunker:, relay_list:) <- result.try(installed())
  fetch_events_with(bunker, relay_list, pubkeys, kind)
}

/// `publish_event` の中身で、`install` が置いた名前の代わりにバンカーと一覧の名前を引数で受ける。
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
    |> result.replace_error(relay_fetch.relay_list_not_responding),
  )
  case relay_list.connections(entries, relay_list.Monitor) {
    [] -> Error(relay_fetch.no_monitor_relay_registered)
    connections ->
      case broadcast(connections, signed) {
        0 -> Error(relay_fetch.no_monitor_relay_connected)
        _ -> Ok(event.to_map(signed))
      }
  }
}

/// `fetch_event` の中身で、`install` が置いた名前の代わりにバンカーと一覧の名前を引数で受ける。
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
  use results <- result.try(fetch_latest(
    bunker_name,
    relay_list_name,
    [pubkey],
    kind,
  ))
  // fetch_latest は pubkeys 1 件につき結果を 1 件返す
  let assert [found] = results
  found
}

/// `fetch_events` の中身で、`install` が置いた名前の代わりにバンカーと一覧の名前を引数で受ける。
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
  fetch_latest(bunker_name, relay_list_name, pubkeys, kind)
}

/// `fetch_with` と `fetch_events_with` の共通の中身。`kind` を整数として読み（失敗は
/// `kind_not_an_int`）、`pubkeys` の登録を確かめ、登録済みの公開鍵だけを重複を除いて
/// まとめて問い合わせる。結果は `pubkeys` と同じ順・同じ件数で、未登録の公開鍵は確認の
/// 理由、登録済みの公開鍵は最新の 1 件を `fetched` の形で持つ。
fn fetch_latest(
  bunker_name: Name(bunker.Msg),
  relay_list_name: Name(relay_list.Msg),
  pubkeys: List(String),
  kind: Dynamic,
) -> Result(List(Result(Dynamic, String)), String) {
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
    _ -> relay_fetch.ask_monitor_relays(relay_list_name, authors, kind)
  })
  Ok(
    list.map(checks, fn(pair) {
      case pair {
        #(pubkey, Ok(Nil)) -> Ok(fetched(relay_fetch.newest_by(found, pubkey)))
        #(_pubkey, Error(reason)) -> Error(reason)
      }
    }),
  )
}

/// `relay_fetch.newest` の結果をプラグインへ返す値にする。見つかれば `event.to_map` の形、
/// 無ければ `none` の atom。
fn fetched(found: Option(Event)) -> Dynamic {
  case found {
    Some(found_event) -> event.to_map(found_event)
    None -> atom.to_dynamic(atom.create("none"))
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
      case task.receive(reply, deadline) {
        Ok(True) -> 1 + gather(reply, remaining - 1, deadline)
        Ok(False) -> gather(reply, remaining - 1, deadline)
        Error(Nil) -> 0
      }
    }
  }
}
