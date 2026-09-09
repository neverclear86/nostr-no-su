//// 受信したイベントを Postgres の `events` テーブルへ保存するプラグイン。
////
//// プラグインの `handle` は重複排除ディスパッチャーのプロセス上で動くため、
//// そこからは DB を触らず専用のアクターへ `Store` を送るだけにする。ディスパッ
//// チャーは DB の応答を待たず、他のプラグインの処理も止まらない。
////
//// 挿入の失敗はログに出して捨てる。リレー監視を巻き込んで落とさないためであり、
//// 接続の復旧は pog のプールに任せる。

import gleam/erlang/process.{type Name, type Subject}
import gleam/io
import gleam/json
import gleam/list
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import gleam/string
import nostr_no_su/named
import nostr_no_su/nostr/event.{type Event}
import nostr_no_su/plugin.{type Plugin, Plugin}
import pog

/// スキーマ作成に失敗してから作り直すまでの待ち時間。アプリが DB より先に立ち
/// 上がった場合に備える。
const schema_retry_delay_ms = 5000

/// イベントを保存するテーブル。`received_at` は取り込んだ時刻で、イベント自身の
/// `created_at`（リレーが配送する Unix 秒）とは別に持つ。
pub const create_events_table = "CREATE TABLE IF NOT EXISTS events (
  id text PRIMARY KEY,
  pubkey text NOT NULL,
  created_at bigint NOT NULL,
  kind int NOT NULL,
  tags jsonb NOT NULL,
  content text NOT NULL,
  sig text NOT NULL,
  received_at timestamptz NOT NULL DEFAULT now()
)"

/// アカウントごとの時系列を引くためのインデックス。
pub const create_pubkey_index = "CREATE INDEX IF NOT EXISTS events_pubkey_created_at ON events (pubkey, created_at)"

/// kind で絞り込むためのインデックス。
pub const create_kind_index = "CREATE INDEX IF NOT EXISTS events_kind ON events (kind)"

/// 起動時に実行する DDL。すべて `IF NOT EXISTS` なので何度実行してもよい。
pub const schema = [create_events_table, create_pubkey_index, create_kind_index]

/// イベント 1 件の挿入。同じ id を別のリレーから受け直しても既存行は変更しない。
/// `tags` は JSON 文字列として渡し、Postgres 側で jsonb にする。
pub const insert_sql = "INSERT INTO events (id, pubkey, created_at, kind, tags, content, sig)
VALUES ($1, $2, $3, $4, $5::jsonb, $6, $7)
ON CONFLICT (id) DO NOTHING"

/// `events` テーブルの 1 行。イベントから純粋に導出できるため、DB なしで
/// テストできる。
pub type Row {
  Row(
    id: String,
    pubkey: String,
    created_at: Int,
    kind: Int,
    tags: String,
    content: String,
    sig: String,
  )
}

pub type Msg {
  /// 保存するイベント。
  Store(event: Event)
  /// スキーマ作成を試みる。初期化時と、失敗後の再試行タイマーから送られる。
  EnsureSchema
}

type State {
  State(db: pog.Connection, self: Subject(Msg), ready: Bool)
}

/// イベントを保存アクターへ転送するプラグイン。アクターは名前で参照するため、
/// 再起動しても同じプラグインがそのまま新しいプロセスへ届く。
pub fn new(name: Name(Msg)) -> Plugin {
  Plugin(name: "postgres_logger", handle: fn(incoming) {
    named.send(name, Store(incoming))
  })
}

/// スーパービジョンツリー用の子仕様。
pub fn supervised(
  name: Name(Msg),
  pool: Name(pog.Message),
) -> ChildSpecification(Subject(Msg)) {
  supervision.worker(fn() { start(name, pool) })
}

/// 保存アクターを起動する。`pool` は同じツリーにいる pog のプールの名前で、
/// プールが再起動しても同じ名前を指し続ける。
pub fn start(
  name: Name(Msg),
  pool: Name(pog.Message),
) -> actor.StartResult(Subject(Msg)) {
  actor.new_with_initialiser(1000, fn(self) { initialise(pool, self) })
  |> actor.named(name)
  |> actor.on_message(handle)
  |> actor.start
}

/// スキーマ作成をキューに積む。ここで作成まで済ませると、DB が応答しない間
/// スーパーバイザーの起動をブロックし、初期化のタイムアウトでツリーごと起動に
/// 失敗してしまう。
fn initialise(
  pool: Name(pog.Message),
  self: Subject(Msg),
) -> Result(actor.Initialised(State, Msg, Subject(Msg)), String) {
  process.send(self, EnsureSchema)
  State(db: pog.named_connection(pool), self: self, ready: False)
  |> actor.initialised
  |> actor.returning(self)
  |> Ok
}

/// スキーマを用意するか、イベントを 1 件保存する。
fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    EnsureSchema -> actor.continue(State(..state, ready: prepare(state)))
    Store(incoming) -> {
      persist(state, incoming)
      actor.continue(state)
    }
  }
}

/// テーブルとインデックスを作成し、保存を始められるかどうかを返す。失敗しても
/// クラッシュせず、再試行を予約する。DB がアプリより後に立ち上がる、あるいは
/// 一時的に落ちている状況が普通にあるため。
fn prepare(state: State) -> Bool {
  case ensure_schema(state.db) {
    Ok(Nil) -> {
      log("schema ready")
      True
    }
    Error(error) -> {
      log("schema setup failed: " <> string.inspect(error) <> "; retrying")
      let _ =
        process.send_after(state.self, schema_retry_delay_ms, EnsureSchema)
      False
    }
  }
}

/// イベント 1 件を保存する。まだスキーマを作れていない場合と挿入に失敗した場合
/// はログに出して捨てる。監視を止めるより取りこぼす方がましだという判断。
fn persist(state: State, incoming: Event) -> Nil {
  case state.ready {
    False -> log("schema not ready; dropped event " <> incoming.id)
    True ->
      case store(state.db, incoming) {
        Ok(_inserted) -> Nil
        Error(error) ->
          log(
            "insert failed for event "
            <> incoming.id
            <> ": "
            <> string.inspect(error),
          )
      }
  }
}

/// テーブルとインデックスを作成する。すでにあれば何もしない。
pub fn ensure_schema(db: pog.Connection) -> Result(Nil, pog.QueryError) {
  use statement <- list.try_each(schema)
  pog.query(statement) |> pog.execute(on: db)
}

/// イベントを 1 行挿入し、実際に挿入された行数を返す。すでに保存済みの id
/// なら 0 になる。
pub fn store(
  db: pog.Connection,
  incoming: Event,
) -> Result(Int, pog.QueryError) {
  let row = to_row(incoming)
  pog.query(insert_sql)
  |> pog.parameter(pog.text(row.id))
  |> pog.parameter(pog.text(row.pubkey))
  |> pog.parameter(pog.int(row.created_at))
  |> pog.parameter(pog.int(row.kind))
  |> pog.parameter(pog.text(row.tags))
  |> pog.parameter(pog.text(row.content))
  |> pog.parameter(pog.text(row.sig))
  |> pog.execute(on: db)
  |> result.map(fn(returned) { returned.count })
}

/// イベントを挿入する 1 行に変換する。`tags` は NIP-01 と同じ入れ子配列を
/// JSON 文字列にしたもので、jsonb 列にはこれをキャストして渡す。
pub fn to_row(incoming: Event) -> Row {
  Row(
    id: incoming.id,
    pubkey: incoming.pubkey,
    created_at: incoming.created_at,
    kind: incoming.kind,
    tags: json.to_string(event.tags_json(incoming)),
    content: incoming.content,
    sig: incoming.sig,
  )
}

/// プラグインのログ行。
fn log(message: String) -> Nil {
  io.println("[postgres] " <> message)
}
