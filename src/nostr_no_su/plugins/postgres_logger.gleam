//// 受信したイベントを Postgres の `events` テーブルへ保存するプラグイン。
////
//// プラグインの `handle` は重複排除ディスパッチャーのプロセス上で動くため、
//// そこからは DB を触らず専用のアクターへ `Store` を送るだけにする。ディスパッ
//// チャーは DB の応答を待たず、他のプラグインの処理も止まらない。
////
//// DB に到達できない間は保存を止め、届いたイベントは数えて捨てる。リレー監視を
//// 巻き込んで落とさないためであり、接続の復旧は pog のプールに任せる。挿入を
//// 試み続けると 1 件ごとにチェックアウト待ちでアクターがブロックし、メール
//// ボックスが際限なく伸びてしまう。

import gleam/erlang/process.{type Name, type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import gleam/string
import nostr_no_su/log
import nostr_no_su/named
import nostr_no_su/nostr/event.{type Event}
import nostr_no_su/plugin.{type Plugin, Plugin}
import pog

/// 保存を止めてから作り直しを試みるまでの待ち時間。DDL は `IF NOT EXISTS` 付き
/// なので、再試行がそのまま疎通確認を兼ねる。
const schema_retry_delay_ms = 5000

/// DDL のタイムアウト。既存のテーブルへインデックスを張る場合、既定の 5 秒では
/// 足りないことがある。DB に到達できないときはこの時間だけチェックアウトを待つ
/// が、待つのは再試行 1 回につき 1 度で、その間に届いたイベントは未準備の経路で
/// 捨てられる。
const schema_timeout_ms = 30_000

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

/// このプラグインが出すログ行の接頭辞。
pub const log_prefix = "postgres_logger"

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

/// 保存アクターが受け取るメッセージ。
pub type Msg {
  /// 保存するイベント。
  Store(event: Event)
  /// スキーマ作成を試みる。初期化時と、保存を止めたあとの再試行タイマーから
  /// 送られる。
  EnsureSchema
}

/// 保存できる状態かどうか。
type Availability {
  /// 保存できる。
  Ready
  /// DB に到達できない。`dropped` はこの間に捨てたイベント数で、復帰したときに
  /// まとめて報告する。`reported` は理由をすでにログへ出したかどうかで、再試行
  /// のたびに同じ行を並べないために持つ。
  Unavailable(dropped: Int, reported: Bool)
}

/// 保存アクターが保持する状態。
type State {
  State(db: pog.Connection, self: Subject(Msg), availability: Availability)
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
  State(
    db: pog.named_connection(pool),
    self: self,
    availability: Unavailable(dropped: 0, reported: False),
  )
  |> actor.initialised
  |> actor.returning(self)
  |> Ok
}

/// スキーマを用意するか、イベントを 1 件保存する。どちらも次の可用性を返す。
fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  let availability = case msg {
    EnsureSchema -> prepare(state)
    Store(incoming) -> persist(state, incoming)
  }
  actor.continue(State(..state, availability: availability))
}

/// テーブルとインデックスを作成する。失敗してもクラッシュせず、保存を止めた
/// まま再試行を予約する。DB がアプリより後に立ち上がる、あるいは一時的に落ちて
/// いる状況が普通にあるため。
fn prepare(state: State) -> Availability {
  case ensure_schema(state.db) {
    Ok(Nil) -> resume(state.availability)
    Error(error) -> suspend(state, error, dropped(state.availability))
  }
}

/// イベント 1 件を保存する。保存を止めている間は数えて捨てるだけにして、DB の
/// チェックアウト待ちでアクターをブロックしない。
fn persist(state: State, incoming: Event) -> Availability {
  case state.availability {
    Unavailable(dropped:, reported:) ->
      Unavailable(dropped: dropped + 1, reported:)
    Ready ->
      case insert(state.db, incoming) {
        Ok(_inserted) -> Ready
        Error(error) ->
          case unreachable(error) {
            // 到達できないなら、このイベントを 1 件目として保存を止める。
            True -> suspend(state, error, 1)
            // それ以外はこのイベント固有の問題なので、保存は続ける。
            False -> {
              log.println(
                log_prefix,
                "insert failed for event "
                  <> incoming.id
                  <> ": "
                  <> string.inspect(error),
              )
              Ready
            }
          }
      }
  }
}

/// 保存を再開する。止まっている間に捨てた件数があれば、まとめて報告する。
fn resume(availability: Availability) -> Availability {
  case availability {
    Unavailable(dropped:, ..) if dropped > 0 ->
      log.println(
        log_prefix,
        "database is back; dropped "
          <> int.to_string(dropped)
          <> " events while it was unavailable",
      )
    _ -> log.println(log_prefix, "schema ready")
  }
  Ready
}

/// 保存を止めて再試行を予約する。出すべきログ行は `suspension_message` が
/// 決める。理由の抑止が効くのは到達できないことによる停止だけなので、次に
/// 持ち越す「報告済み」もそこから導ける。
fn suspend(state: State, error: pog.QueryError, dropped: Int) -> Availability {
  let _ = process.send_after(state.self, schema_retry_delay_ms, EnsureSchema)
  case suspension_message(error, was_reported(state.availability), dropped) {
    Some(line) -> log.println(log_prefix, line)
    None -> Nil
  }
  Unavailable(dropped: dropped, reported: unreachable(error))
}

/// 停止の理由として出すログ行。`None` なら黙る。DB に到達できないことによる
/// 停止は、復帰すれば `resume` が件数とあわせて報告するので、理由は復帰する
/// までに 1 回だけ出す。それ以外の失敗（権限不足のような設定の不備）は待っても
/// 直らず復帰の報告も出ないため、再試行のたびに破棄件数を添えて出す。
pub fn suspension_message(
  error: pog.QueryError,
  reported: Bool,
  dropped: Int,
) -> Option(String) {
  let delay = int.to_string(schema_retry_delay_ms)
  case unreachable(error), reported {
    True, True -> None
    True, False ->
      Some(
        "database unavailable: "
        <> string.inspect(error)
        <> "; retrying every "
        <> delay
        <> "ms",
      )
    False, _ ->
      Some(
        "schema setup failed: "
        <> string.inspect(error)
        <> "; retrying in "
        <> delay
        <> "ms (dropped "
        <> int.to_string(dropped)
        <> " events so far)",
      )
  }
}

/// DB に到達できないことを示すエラーか。これらは待てば直る見込みがあり、次の
/// イベントでも同じだけ待たされるため、保存を止めて再試行に切り替える。
fn unreachable(error: pog.QueryError) -> Bool {
  case error {
    pog.ConnectionUnavailable | pog.QueryTimeout -> True
    _ -> False
  }
}

/// 保存を止めてから捨てたイベント数。
fn dropped(availability: Availability) -> Int {
  case availability {
    Ready -> 0
    Unavailable(dropped:, ..) -> dropped
  }
}

/// 停止の理由をすでに報告しているか。
fn was_reported(availability: Availability) -> Bool {
  case availability {
    Ready -> False
    Unavailable(reported:, ..) -> reported
  }
}

/// テーブルとインデックスを作成する。すでにあれば何もしない。
pub fn ensure_schema(db: pog.Connection) -> Result(Nil, pog.QueryError) {
  use statement <- list.try_each(schema)
  pog.query(statement)
  |> pog.timeout(schema_timeout_ms)
  |> pog.execute(on: db)
}

/// イベントを 1 行挿入し、実際に挿入された行数を返す。すでに保存済みの id
/// なら 0 になる。
pub fn insert(
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
