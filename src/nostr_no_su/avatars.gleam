//// 管理 UI のアカウントのアイコンに使う、署名者ごとの kind 0 の `picture` の URL のキャッシュ。
//// 画像は取らず、検査済みの `https:` の URL だけを持つ。描画のたびに、未取得か取り直す時刻の来た
//// 署名者を取得中として次に取り直す時刻を押してから、監視の用途のリレーへまとめて問い合わせ、
//// `wait_ms` まで待つ。間に合わなかった結果も次の描画のために入れる。取得に失敗した署名者は前の
//// URL を残し、`retry_ms` の後に取り直す。状態はメモリーだけで、再起動すると空から取り直す。

import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Name, type Subject}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import gleam/uri
import nostr_no_su/named
import nostr_no_su/nostr/event.{type Event}
import nostr_no_su/relay_fetch
import nostr_no_su/relay_list
import nostr_no_su/task
import nostr_no_su/time

/// キャッシュの URL を取り直すまでの時間（ミリ秒）。ツリーが渡す。
pub const default_ttl_ms = 300_000

/// 取得に失敗した署名者を取り直すまでの時間（ミリ秒）。ツリーが渡す。
pub const default_retry_ms = 30_000

/// 描画が取得を待つ上限（ミリ秒）。
const wait_ms = 1000

/// アクターへの問い合わせを待つ上限（ミリ秒）。
const call_timeout_ms = 500

/// プロフィールのイベントの kind。
const metadata_kind = 0

/// キャッシュのアクターへのメッセージ。
pub type Msg {
  /// 持っている URL を返し、古い署名者を取得中にする。
  Claim(pubkeys: List(String), reply: Subject(Claimed))
  /// 取得の結果。`Ok` の辞書に無い署名者は `picture` が無い。
  Fetched(pubkeys: List(String), found: Result(Dict(String, String), Nil))
}

/// `Claim` の応答。`known` は持っている URL、`stale` はこの呼び手が取る署名者。
pub type Claimed {
  Claimed(known: Dict(String, String), stale: List(String))
}

/// 署名者 1 人の記録。`refresh_at` は次に取り直す `time.monotonic_ms` の目盛りで、取得中にした
/// ときは `ttl_ms` の後、取得に失敗したときは `retry_ms` の後に置く。
type Cached {
  Cached(picture: Option(String), refresh_at: Int)
}

/// アクターの状態。
type State {
  State(ttl_ms: Int, retry_ms: Int, cache: Dict(String, Cached))
}

/// スーパービジョンツリー用の子仕様。
pub fn supervised(
  name: Name(Msg),
  ttl_ms: Int,
  retry_ms: Int,
) -> ChildSpecification(Subject(Msg)) {
  supervision.worker(fn() { start(name, ttl_ms, retry_ms) })
}

/// 名前で登録したアクターを空のキャッシュで起動する。
pub fn start(
  name: Name(Msg),
  ttl_ms: Int,
  retry_ms: Int,
) -> actor.StartResult(Subject(Msg)) {
  actor.new(State(ttl_ms:, retry_ms:, cache: dict.new()))
  |> actor.named(name)
  |> actor.on_message(handle)
  |> actor.start
}

/// `pubkeys` のうち URL を持つ署名者の辞書。取得は `relay_fetch.ask_monitor_relays` で kind 0 を
/// 問い合わせる。
pub fn pictures(
  name: Name(Msg),
  relay_list_name: Name(relay_list.Msg),
  pubkeys: List(String),
) -> Dict(String, String) {
  pictures_with(name, pubkeys, relay_fetch.ask_monitor_relays(
    relay_list_name,
    _,
    metadata_kind,
  ))
}

/// `pictures` の中身。取得を `fetch` で注入し `wait_ms` で打ち切るので、テストはリレー無しで叩ける。
/// 打ち切られた取得の結果は `Fetched` で届き、次の描画に入る。
pub fn pictures_with(
  name: Name(Msg),
  pubkeys: List(String),
  fetch: fn(List(String)) -> Result(List(Event), String),
) -> Dict(String, String) {
  case named.call(name, call_timeout_ms, Claim(pubkeys, _)) {
    None -> dict.new()
    Some(Claimed(known:, stale: [])) -> known
    Some(Claimed(known:, stale:)) -> {
      let fetching =
        task.start(fn() {
          let found =
            fetch(stale)
            |> result.map(found_pictures(stale, _))
            |> result.replace_error(Nil)
          named.send(name, Fetched(stale, found))
          found
        })
      case task.await(fetching, task.deadline_in(wait_ms)) {
        Ok(Ok(found)) -> dict.merge(dict.drop(known, stale), found)
        _ -> known
      }
    }
  }
}

/// kind 0 の content の `picture` が、scheme が `https` で host が空でない URL ならその文字列。JSON でない、
/// `picture` が無いか文字列でない、それ以外の URL は `None`。
pub fn picture(metadata: Event) -> Option(String) {
  case json.parse(metadata.content, decode.at(["picture"], decode.string)) {
    Ok(value) ->
      case uri.parse(value) {
        Ok(uri.Uri(scheme: Some("https"), host: Some(host), ..))
          if host != ""
        -> Some(value)
        _ -> None
      }
    Error(_) -> None
  }
}

/// 署名者ごとに `relay_fetch.newest_by` の 1 件の `picture` を引き、URL のあるものだけの辞書。
fn found_pictures(
  pubkeys: List(String),
  events: List(Event),
) -> Dict(String, String) {
  list.filter_map(pubkeys, fn(pubkey) {
    relay_fetch.newest_by(events, pubkey)
    |> option.then(picture)
    |> option.map(fn(url) { #(pubkey, url) })
    |> option.to_result(Nil)
  })
  |> dict.from_list
}

/// `Claim` と `Fetched` を処理する。署名者が古いのは、キャッシュに無いか `now >= refresh_at` のとき
/// である（`ttl_ms` 0 では同じミリ秒の呼び出しでも毎回取る）。
fn handle(state: State, message: Msg) -> actor.Next(State, Msg) {
  let now = time.monotonic_ms()
  case message {
    Claim(pubkeys:, reply:) -> {
      let stale =
        list.filter(list.unique(pubkeys), fn(pubkey) {
          case dict.get(state.cache, pubkey) {
            Ok(Cached(refresh_at:, ..)) -> now >= refresh_at
            Error(Nil) -> True
          }
        })
      let known =
        list.filter_map(pubkeys, fn(pubkey) {
          case dict.get(state.cache, pubkey) {
            Ok(Cached(picture: Some(url), ..)) -> Ok(#(pubkey, url))
            _ -> Error(Nil)
          }
        })
        |> dict.from_list
      process.send(reply, Claimed(known:, stale:))
      update_each(state, stale, fn(_pubkey, entry) {
        Cached(picture: previous_picture(entry), refresh_at: now + state.ttl_ms)
      })
    }
    Fetched(pubkeys:, found: Ok(found)) ->
      update_each(state, pubkeys, fn(pubkey, entry) {
        let picture = dict.get(found, pubkey) |> option.from_result
        case entry {
          Some(cached) -> Cached(..cached, picture:)
          None -> Cached(picture:, refresh_at: now + state.ttl_ms)
        }
      })
    Fetched(pubkeys:, found: Error(Nil)) ->
      update_each(state, pubkeys, fn(_pubkey, entry) {
        Cached(
          picture: previous_picture(entry),
          refresh_at: now + state.retry_ms,
        )
      })
  }
}

/// `pubkeys` の各記録を、署名者と前の記録（無ければ `None`）から `update` で作ったものに置き換える。
fn update_each(
  state: State,
  pubkeys: List(String),
  update: fn(String, Option(Cached)) -> Cached,
) -> actor.Next(State, Msg) {
  let cache =
    list.fold(pubkeys, state.cache, fn(cache, pubkey) {
      dict.upsert(cache, pubkey, update(pubkey, _))
    })
  actor.continue(State(..state, cache:))
}

/// 前の記録の URL。記録が無ければ `None`。
fn previous_picture(entry: Option(Cached)) -> Option(String) {
  option.then(entry, fn(cached) { cached.picture })
}
