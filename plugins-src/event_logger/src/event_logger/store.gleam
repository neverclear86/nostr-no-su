//// 受信したイベントを Postgres の `events` テーブルへ保存するアクター。
////
//// プラグインのイベント処理関数はイベントごとの使い捨てプロセスで動くため、
//// そこからは DB を触らず、このアクターへ `Store` を送るだけにする。使い捨て
//// プロセスから DB を触ると、接続のチェックアウト待ちが 1 件あたりの実行時間の
//// 上限に当たり、DB が落ちている間にこのプラグインが無効化されてしまう。送る
//// だけなら実行は即座に終わり、保存の遅れも失敗もアクター側に閉じる。
////
//// DB に到達できない間は保存を止め、届いたイベントは数えて捨てる。リレー監視を
//// 巻き込んで落とさないためであり、接続の復旧は pog のプールに任せる。挿入を
//// 試み続けると 1 件ごとにチェックアウト待ちでアクターがブロックし、メール
//// ボックスが際限なく伸びてしまう。落ちずに数えて捨てる形は、諦められた子が
//// 本体の再起動まで戻らないプラグインの失敗モデル（`docs/plugin-api.md`
//// 第 5.4 節）に対する正しい振る舞いでもある。
////
//// DB に到達できても 1 件の挿入が遅いと、未処理の `Store` がメールボックスに
//// 積まれ続ける。そこで `Store` を取り出すたびに残りの件数を見て、上限を超えたら
//// 上限の半分に減るまで数えて捨てる。取り出すときに見るので、1 件の挿入の間に
//// 届いた分だけは上限を超えうる。

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process.{type Name, type Subject}
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import pog

/// 保存を止めてから作り直しを試みるまでの待ち時間。DDL は `IF NOT EXISTS` 付き
/// なので、再試行がそのまま疎通確認を兼ねる。
const schema_retry_delay_ms = 5000

/// DDL のタイムアウト。既存のテーブルへインデックスを張る場合、既定の 5 秒では
/// 足りないことがある。DB に到達できないときはこの時間だけチェックアウトを待つ
/// が、待つのは再試行 1 回につき 1 度で、その間に届いたイベントは未準備の経路で
/// 捨てられる。
const schema_timeout_ms = 30_000

/// このプラグインが自分で出すログ行の接頭辞。本体が出す行の接頭辞
/// （`[plugin event_logger]`）とは別物である。
const log_prefix = "[event_logger] "

/// 保存を待つ `Store` の上限の既定値。本体のランナーの上限と同じ件数にする。
pub const default_max_queue_len = 1000

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

/// `events` テーブルの 1 行。イベント map から純粋に導出できるため、DB なしで
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
  /// 保存する 1 行。イベント map からの変換は送り手（使い捨てプロセス）が
  /// 済ませ、アクターには DB の仕事だけを残す。
  Store(row: Row)
  /// スキーマ作成を試みる。初期化時と、保存を止めたあとの再試行タイマーから
  /// 送られる。
  EnsureSchema
}

/// 保存アクターが DB に対して行う 2 つの操作。本番は `postgres/1` が pog の
/// プールから作り、テストは遅い DB や失敗する DB を模した関数を渡す。
pub type Database {
  Database(
    ensure_schema: fn() -> Result(Nil, pog.QueryError),
    insert: fn(Row) -> Result(Int, pog.QueryError),
  )
}

/// 保存できる状態かどうか。
type Availability {
  /// 保存できる。
  Ready
  /// 保存が追いつかず、未処理のメッセージが上限を超えた。`dropped` はこの間に
  /// 捨てたイベント数で、上限の半分まで減って保存を再開するときに報告する。
  Overloaded(dropped: Int)
  /// DB に到達できない。`dropped` はこの間に捨てたイベント数で、復帰したときに
  /// まとめて報告する。`reported` は理由をすでにログへ出したかどうかで、再試行
  /// のたびに同じ行を並べないために持つ。
  Unavailable(dropped: Int, reported: Bool)
}

/// 保存アクターが保持する状態。
type State {
  State(
    database: Database,
    self: Subject(Msg),
    max_queue_len: Int,
    availability: Availability,
  )
}

/// 名前で登録された pog のプールに対する `Database`。プールが再起動しても同じ
/// 名前を指し続ける。
pub fn postgres(pool: Name(pog.Message)) -> Database {
  let db = pog.named_connection(pool)
  Database(ensure_schema: fn() { ensure_schema(db) }, insert: insert(db, _))
}

/// 保存アクターを起動する。`max_queue_len` は保存を待つメッセージの上限で、
/// 本番は `default_max_queue_len` を渡す。
pub fn start(
  name: Name(Msg),
  database: Database,
  max_queue_len: Int,
) -> actor.StartResult(Subject(Msg)) {
  actor.new_with_initialiser(1000, fn(self) {
    initialise(database, max_queue_len, self)
  })
  |> actor.named(name)
  |> actor.on_message(handle)
  |> actor.start
}

/// スキーマ作成をキューに積む。ここで作成まで済ませると、DB が応答しない間
/// スーパーバイザーの起動をブロックし、初期化のタイムアウトでツリーごと起動に
/// 失敗してしまう。
fn initialise(
  database: Database,
  max_queue_len: Int,
  self: Subject(Msg),
) -> Result(actor.Initialised(State, Msg, Subject(Msg)), String) {
  process.send(self, EnsureSchema)
  State(
    database: database,
    self: self,
    max_queue_len: max_queue_len,
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
    Store(row:) -> persist(state, row, message_queue_len())
  }
  actor.continue(State(..state, availability: availability))
}

/// テーブルとインデックスを作成する。失敗してもクラッシュせず、保存を止めた
/// まま再試行を予約する。DB がアプリより後に立ち上がる、あるいは一時的に落ちて
/// いる状況が普通にあるため。
fn prepare(state: State) -> Availability {
  case state.database.ensure_schema() {
    Ok(Nil) -> resume(state.availability)
    Error(error) -> suspend(state, error, dropped(state.availability))
  }
}

/// 1 行を保存する。`queue_len` はこの行を取り出したあとに残っている未処理の
/// メッセージ数である。保存を止めている間と、積まれすぎている間は数えて捨てる
/// だけにして、DB を待たずにメールボックスを減らす。
fn persist(state: State, row: Row, queue_len: Int) -> Availability {
  case state.availability {
    Unavailable(dropped:, reported:) ->
      Unavailable(dropped: dropped + 1, reported:)
    // 上限の半分まで減るまで捨て続ける。上限そのものを復帰条件にすると、
    // 境界で捨て始めと再開のログが 1 件ごとに交互に出る。
    Overloaded(dropped:) if queue_len > state.max_queue_len / 2 ->
      Overloaded(dropped: dropped + 1)
    Overloaded(dropped:) -> {
      println(
        "caught up; dropped "
        <> int.to_string(dropped)
        <> " events while overloaded",
      )
      write(state, row)
    }
    Ready if queue_len > state.max_queue_len -> {
      println(
        "too slow: "
        <> int.to_string(queue_len)
        <> " events queued (limit "
        <> int.to_string(state.max_queue_len)
        <> "); dropping until it catches up",
      )
      Overloaded(dropped: 1)
    }
    Ready -> write(state, row)
  }
}

/// 1 行を挿入し、結果から次の可用性を決める。
fn write(state: State, row: Row) -> Availability {
  case state.database.insert(row) {
    Ok(_inserted) -> Ready
    Error(error) ->
      case unreachable(error) {
        // 到達できないなら、このイベントを 1 件目として保存を止める。
        True -> suspend(state, error, 1)
        // それ以外はこのイベント固有の問題なので、保存は続ける。
        False -> {
          println(
            "insert failed for event "
            <> row.id
            <> ": "
            <> string.inspect(error),
          )
          Ready
        }
      }
  }
}

/// 保存を再開する。止まっている間に捨てた件数があれば、まとめて報告する。
fn resume(availability: Availability) -> Availability {
  case availability {
    Unavailable(dropped:, ..) if dropped > 0 ->
      println(
        "database is back; dropped "
        <> int.to_string(dropped)
        <> " events while it was unavailable",
      )
    _ -> println("schema ready")
  }
  Ready
}

/// 保存を止めて再試行を予約する。出すべきログ行は `suspension_message` が
/// 決める。理由の抑止が効くのは到達できないことによる停止だけなので、次に
/// 持ち越す「報告済み」もそこから導ける。
fn suspend(state: State, error: pog.QueryError, dropped: Int) -> Availability {
  let _ = process.send_after(state.self, schema_retry_delay_ms, EnsureSchema)
  case suspension_message(error, was_reported(state.availability), dropped) {
    Some(line) -> println(line)
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
    Ready | Overloaded(..) -> 0
    Unavailable(dropped:, ..) -> dropped
  }
}

/// 停止の理由をすでに報告しているか。
fn was_reported(availability: Availability) -> Bool {
  case availability {
    Ready | Overloaded(..) -> False
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

/// 1 行を挿入し、実際に挿入された行数を返す。すでに保存済みの id なら 0 になる。
pub fn insert(db: pog.Connection, row: Row) -> Result(Int, pog.QueryError) {
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

/// プラグイン境界のイベント map（binary キーの Erlang map）を挿入する 1 行に
/// 変換する。`tags` は NIP-01 と同じ入れ子配列を JSON 文字列にしたもので、jsonb
/// 列にはこれをキャストして渡す。**知らないキーは無視する**
/// （`docs/plugin-api.md` 第 3 章）。
pub fn to_row(event: Dynamic) -> Result(Row, String) {
  decode.run(event, row_decoder())
  |> result.map_error(string.inspect)
}

/// イベント map から 1 行を読むデコーダー。
fn row_decoder() -> decode.Decoder(Row) {
  use id <- decode.field("id", decode.string)
  use pubkey <- decode.field("pubkey", decode.string)
  use created_at <- decode.field("created_at", decode.int)
  use kind <- decode.field("kind", decode.int)
  use tags <- decode.field("tags", decode.list(decode.list(decode.string)))
  use content <- decode.field("content", decode.string)
  use sig <- decode.field("sig", decode.string)
  decode.success(Row(
    id: id,
    pubkey: pubkey,
    created_at: created_at,
    kind: kind,
    tags: json.to_string(json.array(tags, of: json.array(_, of: json.string))),
    content: content,
    sig: sig,
  ))
}

/// このプラグインのログ行を 1 行出す。
fn println(line: String) -> Nil {
  io.println(log_prefix <> line)
}

/// 自プロセスの未処理メッセージ数。
@external(erlang, "event_logger_ffi", "message_queue_len")
fn message_queue_len() -> Int
