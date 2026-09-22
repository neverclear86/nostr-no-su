//// プラグインが呼ぶ本体側の口。プラグイン API v1 の任意エクスポート（本体が
//// プラグインを呼ぶ側）とは向きが逆で、ここはプラグインが本体を呼ぶ。仕様は
//// `docs/plugin-api.md` 第 14 章。

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Name, type Subject}
import gleam/int
import gleam/list
import gleam/result
import nostr_no_su/bunker
import nostr_no_su/nostr/event.{type Event}
import nostr_no_su/relay_connection
import nostr_no_su/relay_list
import nostr_no_su/task
import nostr_no_su/time

/// リレーへ送信を依頼してから応答を集める時間の上限（ミリ秒）。送信は全接続へ
/// 同時に依頼するので、リレーの本数には比例しない。
const publish_timeout_ms = 1000

/// `publish_timeout_ms` に足す余裕。集計を行う使い捨てプロセスの結果を
/// 取りこぼさないためのもの。
const gather_margin_ms = 200

/// `install` が置いていないときの理由。
const not_installed = "the plugin API is not installed"

/// `pubkey` が文字列でないときの理由。
const pubkey_not_a_string = "pubkey must be a String"

/// 監視の用途のリレーが一覧に無いときの理由。
const no_monitor_relay_registered = "no monitor relay is registered"

/// 監視の用途のリレーはあるが、生きたソケットに 1 本も渡せなかったときの理由。
const no_monitor_relay_connected = "no monitor relay is connected"

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
