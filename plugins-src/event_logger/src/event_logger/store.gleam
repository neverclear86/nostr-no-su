//// 受信したイベントを Postgres の `event_logger_events` テーブルへ保存するアクター。
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
////
//// 保存の対象とするアカウントの集合はこのアクターが状態として持つ。移行の後に
//// DB から読み込み、設定の保存の後は `ReloadMonitored` で読み直す。`persist` は
//// 保存の前にこの集合で `pubkey` を弾き、集合が空なら絞らずに全アカウントを
//// 保存する。
////
//// テーブルとインデックスは版つきの移行として持ち、`event_logger_schema_version` に
//// 記録する。記録された版がこのプラグインより新しければ、理由を 1 行出してアクターを
//// 異常終了させる。待っても直らず、生かしたまま捨て続けると管理 UI に止まっている
//// ことが見えないため（`docs/plugin-api.md` 第 5.4 節）。
////
//// タイムラインのページはこのアクターを通さず `recent_events/2` で直接読み出す
//// （読み出しは保存の順序に影響しないため）。

import event_logger/log
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/set
import gleam/string
import pog

/// 保存を止めてから作り直しを試みるまでの待ち時間。移行は記録された版より新しい
/// ものだけを実行するので、再試行がそのまま疎通確認を兼ねる。
const schema_retry_delay_ms = 5000

/// DDL のタイムアウト。既存のテーブルへインデックスを張る場合、既定の 5 秒では
/// 足りないことがある。DB に到達できないときはこの時間だけチェックアウトを待つ
/// が、待つのは再試行 1 回につき 1 度で、その間に届いたイベントは未準備の経路で
/// 捨てられる。
const schema_timeout_ms = 30_000

/// 保存を待つ `Store` の上限の既定値。本体のランナーの上限と同じ件数にする。
pub const default_max_queue_len = 1000

/// タイムラインのページが出す件数。
pub const recent_limit = 20

/// タイムラインの問い合わせの期限。ページの期限より短くし、失敗しても節を
/// 描けるようにする。
const recent_timeout_ms = 2000

/// 版 1 でイベントを保存するテーブルを `events` の名前で作る。`received_at` は取り込んだ
/// 時刻で、イベント自身の `created_at`（リレーが配送する Unix 秒）とは別に持つ。名前は
/// 版 4 の `prefix_table_names` で `event_logger_events` に変わる。
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

/// タイムラインが読む保存順のインデックス。`select_recent_sql` の並びと同じ
/// 向きにする。
pub const create_received_at_index = "CREATE INDEX IF NOT EXISTS events_received_at ON events (received_at DESC, id DESC)"

/// 版 2 で保存の対象とするアカウントのテーブルを `monitored_accounts` の名前で作る。行が
/// 1 件も無ければ絞らず、全アカウントを保存する。名前は版 4 の `prefix_table_names` で
/// `event_logger_monitored_accounts` に変わる。
const create_monitored_accounts_table = "CREATE TABLE IF NOT EXISTS monitored_accounts (
  pubkey text PRIMARY KEY
)"

/// スキーマの版 1 つぶんの移行。`statements` を順に実行した後に `version` を
/// `event_logger_schema_version` に記録する。
pub type Migration {
  Migration(version: Int, statements: List(String))
}

/// このプラグインのスキーマの移行。版は 1 から欠番なく昇順に並べ、足すときは末尾に
/// 置く。
///
/// 移行の文は何度実行してもよい形（作る文は `IF NOT EXISTS`、改名する文は `IF EXISTS`）で
/// 書く。途中で失敗した移行は版が記録されないので、次の読み込みで頭から実行し直される。
///
/// 適用済みの版の文は書き換えない。版 1〜3 は接頭辞の無い名前（`events`、
/// `monitored_accounts`）で作り、版 4 で改名するので、新しい DB も版 3 までの DB も同じ
/// 順に同じ名前へ進む。
pub const migrations = [
  Migration(
    version: 1,
    statements: [create_events_table, create_pubkey_index, create_kind_index],
  ),
  Migration(version: 2, statements: [create_monitored_accounts_table]),
  Migration(version: 3, statements: [create_received_at_index]),
  Migration(version: 4, statements: prefix_table_names),
]

/// 版 4 の移行。版 1〜3 が作ったテーブルとインデックス（主キーを含む）の名前に、プラグイン
/// 名の `event_logger_` を接頭辞として付ける（`docs/plugin-api.md` 第 5.3 節）。主キーの
/// 制約の名前はインデックスの改名に追随する。どの文も `IF EXISTS` 付きで、改名済みの
/// 名前には何もしないので、途中で失敗した移行を頭から実行し直してよい。
const prefix_table_names = [
  "ALTER TABLE IF EXISTS events RENAME TO event_logger_events",
  "ALTER INDEX IF EXISTS events_pkey RENAME TO event_logger_events_pkey",
  "ALTER INDEX IF EXISTS events_pubkey_created_at RENAME TO event_logger_events_pubkey_created_at",
  "ALTER INDEX IF EXISTS events_kind RENAME TO event_logger_events_kind",
  "ALTER INDEX IF EXISTS events_received_at RENAME TO event_logger_events_received_at",
  "ALTER TABLE IF EXISTS monitored_accounts RENAME TO event_logger_monitored_accounts",
  "ALTER INDEX IF EXISTS monitored_accounts_pkey RENAME TO event_logger_monitored_accounts_pkey",
]

/// 適用した移行の版を 1 行ずつ記録するテーブル。最大の `version` を現在の版とする。
/// 本体の `schema_version` と名前が衝突しないよう、プラグイン名を付ける。
const create_version_table = "CREATE TABLE IF NOT EXISTS event_logger_schema_version (
  version integer PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
)"

/// 記録された版の読み込み。
const select_versions_sql = "SELECT version FROM event_logger_schema_version"

/// 版の記録。
const insert_version_sql = "INSERT INTO event_logger_schema_version (version) VALUES ($1)"

/// スキーマの用意の失敗。
pub type SchemaError {
  /// 版の読み書きか移行の文が失敗した。
  SchemaQueryFailed(error: pog.QueryError)
  /// DB に記録された版（`found`）が、このプラグインの移行の最新の版（`supported`）
  /// より新しい。
  SchemaTooNew(found: Int, supported: Int)
}

/// イベント 1 件の挿入。同じ id を別のリレーから受け直しても既存行は変更しない。
/// `tags` は JSON 文字列として渡し、Postgres 側で jsonb にする。
pub const insert_sql = "INSERT INTO event_logger_events (id, pubkey, created_at, kind, tags, content, sig)
VALUES ($1, $2, $3, $4, $5::jsonb, $6, $7)
ON CONFLICT (id) DO NOTHING"

/// 保存順の直近のイベント。`tags` は jsonb なので text にキャストして読む。
const select_recent_sql = "SELECT id, pubkey, created_at, kind, tags::text, content, sig FROM event_logger_events ORDER BY received_at DESC, id DESC LIMIT $1"

/// 保存の対象とするアカウントの読み込み。
const select_monitored_sql = "SELECT pubkey FROM event_logger_monitored_accounts"

/// 保存の対象とするアカウントの入れ替え。`$1` の配列に無い行を消して配列の要素を
/// 重複を除いて挿入する。消去と挿入は 1 文の中で原子的に行われるので、失敗した
/// ときは表が元のまま残る。
const replace_monitored_sql = "WITH removed AS (DELETE FROM event_logger_monitored_accounts WHERE pubkey <> ALL($1::text[]))
INSERT INTO event_logger_monitored_accounts (pubkey) SELECT unnest($1::text[])
ON CONFLICT DO NOTHING"

/// `event_logger_events` テーブルの 1 行。イベント map から純粋に導出できるため、DB なしで
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

/// 保存の対象。`AllAccounts` は表の行が 0 件の状態で、絞らずに全部保存する。
pub type Monitored {
  AllAccounts
  OnlyPubkeys(pubkeys: set.Set(String))
}

/// `event_logger_monitored_accounts` の行から `Monitored` を作る。行が無ければ `AllAccounts`。
pub fn monitored_from_rows(rows: List(String)) -> Monitored {
  case rows {
    [] -> AllAccounts
    _ -> OnlyPubkeys(set.from_list(rows))
  }
}

/// `pubkey` が保存の対象かどうか。`AllAccounts` は常に対象、`OnlyPubkeys` は
/// 集合に含まれるかどうかで決める。
pub fn is_monitored(monitored: Monitored, pubkey: String) -> Bool {
  case monitored {
    AllAccounts -> True
    OnlyPubkeys(pubkeys:) -> set.contains(pubkeys, pubkey)
  }
}

/// 保存アクターが受け取るメッセージ。
pub type Msg {
  /// 保存する 1 行。イベント map からの変換は送り手（使い捨てプロセス）が
  /// 済ませ、アクターには DB の仕事だけを残す。
  Store(row: Row)
  /// スキーマの移行を試みる。初期化時と、保存を止めたあとの再試行タイマーから
  /// 送られる。
  EnsureSchema
  /// 保存の対象とするアカウントを DB から読み直す。設定の保存の後に届く。
  ReloadMonitored
  /// 今の保存の対象を答える。設定ページの描画に答える。
  GetMonitored(reply_to: Subject(Monitored))
}

/// 保存アクターが DB に対して行う 3 つの操作。本番は `postgres/1` が pog の
/// プールから作り、テストは遅い DB や失敗する DB を模した関数を渡す。
pub type Database {
  Database(
    ensure_schema: fn() -> Result(Nil, SchemaError),
    insert: fn(Row) -> Result(Int, pog.QueryError),
    load_monitored: fn() -> Result(List(String), pog.QueryError),
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
    monitored: Monitored,
  )
}

/// 名前で登録された pog のプールに対する `Database`。プールが再起動しても同じ
/// 名前を指し続ける。
pub fn postgres(pool: Name(pog.Message)) -> Database {
  let db = pog.named_connection(pool)
  Database(
    ensure_schema: fn() { ensure_schema(db) },
    insert: insert(db, _),
    load_monitored: fn() { load_monitored(db) },
  )
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
    monitored: AllAccounts,
  )
  |> actor.initialised
  |> actor.returning(self)
  |> Ok
}

/// スキーマを用意するか、イベントを 1 件保存するか、監視対象を読み直すか、今の
/// 監視対象を答える。スキーマの版がこのプラグインより新しければ、理由を 1 行出して
/// アクターを異常終了させる。
fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    EnsureSchema ->
      case prepare(state) {
        Ok(#(availability, monitored)) ->
          actor.continue(State(..state, availability:, monitored:))
        Error(reason) -> {
          log.write(log.Error, reason)
          actor.stop_abnormal(reason)
        }
      }
    Store(row:) ->
      actor.continue(
        State(
          ..state,
          availability: persist(
            state,
            row,
            pending_messages(process.self()) |> result.unwrap(0),
          ),
        ),
      )
    ReloadMonitored ->
      case state.database.load_monitored() {
        Ok(rows) ->
          actor.continue(State(..state, monitored: monitored_from_rows(rows)))
        Error(error) -> {
          log.write(
            log.Warning,
            "monitored accounts could not be reloaded: "
              <> string.inspect(error),
          )
          actor.continue(state)
        }
      }
    GetMonitored(reply_to:) -> {
      process.send(reply_to, state.monitored)
      actor.continue(state)
    }
  }
}

/// スキーマを最新の版に移行し、次の可用性と監視対象を返す。監視対象の読み込みが
/// 失敗したときもスキーマの失敗と同じく保存を止めて再試行する。クエリーの失敗では
/// クラッシュせず、保存を止めたまま再試行を予約する（DB がアプリより後に立ち上がる、
/// あるいは一時的に落ちている状況が普通にあるため）。版がこのプラグインより新しければ、
/// 待っても直らないので止める理由を返す。
fn prepare(state: State) -> Result(#(Availability, Monitored), String) {
  case state.database.ensure_schema() {
    Ok(Nil) ->
      case state.database.load_monitored() {
        Ok(rows) -> Ok(#(resume(state.availability), monitored_from_rows(rows)))
        Error(error) ->
          Ok(#(
            suspend(state, error, dropped(state.availability)),
            state.monitored,
          ))
      }
    Error(SchemaQueryFailed(error)) ->
      Ok(#(suspend(state, error, dropped(state.availability)), state.monitored))
    Error(SchemaTooNew(found:, supported:)) ->
      Error(
        "database schema version "
        <> int.to_string(found)
        <> " is newer than this plugin supports (up to version "
        <> int.to_string(supported)
        <> "); stopping the store",
      )
  }
}

/// 1 行を保存する。`queue_len` はこの行を取り出したあとに残っている未処理の
/// メッセージ数である。保存を止めている間と、積まれすぎている間は数えて捨てる
/// だけにして、DB を待たずにメールボックスを減らす。対象外のイベントは保存も
/// せず、破棄の件数にも数えない。
fn persist(state: State, row: Row, queue_len: Int) -> Availability {
  case is_monitored(state.monitored, row.pubkey) {
    False -> state.availability
    True ->
      case state.availability {
        Unavailable(dropped:, reported:) ->
          Unavailable(dropped: dropped + 1, reported:)
        // 上限の半分まで減るまで捨て続ける。上限そのものを復帰条件にすると、
        // 境界で捨て始めと再開のログが 1 件ごとに交互に出る。
        Overloaded(dropped:) if queue_len > state.max_queue_len / 2 ->
          Overloaded(dropped: dropped + 1)
        Overloaded(dropped:) -> {
          log.write(
            log.Notice,
            "caught up; dropped "
              <> int.to_string(dropped)
              <> " events while overloaded",
          )
          write(state, row)
        }
        Ready if queue_len > state.max_queue_len -> {
          log.write(
            log.Warning,
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
          log.write(
            log.Warning,
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
      log.write(
        log.Notice,
        "database is back; dropped "
          <> int.to_string(dropped)
          <> " events while it was unavailable",
      )
    _ -> log.write(log.Notice, "schema ready")
  }
  Ready
}

/// 保存を止めて再試行を予約する。出すべきログ行は `suspension_message` が
/// 決める。理由の抑止が効くのは到達できないことによる停止だけなので、次に
/// 持ち越す「報告済み」もそこから導ける。
fn suspend(state: State, error: pog.QueryError, dropped: Int) -> Availability {
  let _ = process.send_after(state.self, schema_retry_delay_ms, EnsureSchema)
  case suspension_message(error, was_reported(state.availability), dropped) {
    Some(line) -> log.write(log.Warning, line)
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
    // 呼び出し元の prepare は EnsureSchema を受けたときだけ動き、EnsureSchema は
    // Unavailable の間しか届かないので、この枝は網羅のためにある。Overloaded の
    // 件数は保存を止めて捨てた数ではなく、再開するときに persist が報告する。
    Ready | Overloaded(..) -> 0
    Unavailable(dropped:, ..) -> dropped
  }
}

/// 停止の理由をすでに報告しているか。
fn was_reported(availability: Availability) -> Bool {
  case availability {
    // 保存している間に挿入が到達できずに失敗すると、write から suspend を経て
    // ここを通る。まだ停止していないので、停止の理由も報告していない。
    Ready | Overloaded(..) -> False
    Unavailable(reported:, ..) -> reported
  }
}

/// 版 `current` の DB に適用する移行を、`migrations` の並びのまま返す。`current` が
/// `migrations` の最新の版より新しければ `SchemaTooNew` を返す。
pub fn pending_migrations(
  migrations: List(Migration),
  current: Int,
) -> Result(List(Migration), SchemaError) {
  let supported =
    list.fold(migrations, 0, fn(latest, migration) {
      int.max(latest, migration.version)
    })
  case current > supported {
    True -> Error(SchemaTooNew(found: current, supported: supported))
    False ->
      Ok(list.filter(migrations, fn(migration) { migration.version > current }))
  }
}

/// スキーマを `migrations` の最新の版にする（`apply_migrations` に `migrations` を渡す）。
pub fn ensure_schema(db: pog.Connection) -> Result(Nil, SchemaError) {
  apply_migrations(db, migrations)
}

/// 版の記録のテーブルを用意し、記録された版より新しい移行を `migrations` の並びの順に適用
/// して、移行ごとに版を記録する。トランザクションは使わない（`pog.transaction` は 5 秒で
/// 打ち切られるため）。記録された版が `migrations` の最新の版より新しければ
/// `SchemaTooNew`。テストは `migrations` の先頭の一部を渡して古い版の DB を作る。
pub fn apply_migrations(
  db: pog.Connection,
  migrations: List(Migration),
) -> Result(Nil, SchemaError) {
  use _created <- result.try(run_schema_query(
    db,
    pog.query(create_version_table),
  ))
  use recorded <- result.try(run_schema_query(
    db,
    pog.query(select_versions_sql) |> pog.returning(decode.at([0], decode.int)),
  ))
  use pending <- result.try(pending_migrations(
    migrations,
    list.fold(recorded.rows, 0, int.max),
  ))
  use migration <- list.try_each(pending)
  use Nil <- result.try(
    list.try_each(migration.statements, fn(statement) {
      run_schema_query(db, pog.query(statement))
    }),
  )
  run_schema_query(
    db,
    pog.query(insert_version_sql) |> pog.parameter(pog.int(migration.version)),
  )
}

/// スキーマの用意の問い合わせを 1 つ、`schema_timeout_ms` の期限で実行する。DDL 以外の
/// 問い合わせ（版の読み書き）も通す。
fn run_schema_query(
  db: pog.Connection,
  query: pog.Query(a),
) -> Result(pog.Returned(a), SchemaError) {
  query
  |> pog.timeout(schema_timeout_ms)
  |> pog.execute(on: db)
  |> result.map_error(SchemaQueryFailed)
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

/// 保存順の直近のイベントを `limit` 件まで読み、`recent_timeout_ms` で打ち切る。
pub fn recent_events(
  db: pog.Connection,
  limit: Int,
) -> Result(List(Row), pog.QueryError) {
  pog.query(select_recent_sql)
  |> pog.parameter(pog.int(limit))
  |> pog.returning(recent_row_decoder())
  |> pog.timeout(recent_timeout_ms)
  |> pog.execute(on: db)
  |> result.map(fn(returned) { returned.rows })
}

/// `select_recent_sql` の列の並びと 1 対 1 に対応する `Row` のデコーダー。
fn recent_row_decoder() -> decode.Decoder(Row) {
  use id <- decode.field(0, decode.string)
  use pubkey <- decode.field(1, decode.string)
  use created_at <- decode.field(2, decode.int)
  use kind <- decode.field(3, decode.int)
  use tags <- decode.field(4, decode.string)
  use content <- decode.field(5, decode.string)
  use sig <- decode.field(6, decode.string)
  decode.success(Row(
    id: id,
    pubkey: pubkey,
    created_at: created_at,
    kind: kind,
    tags: tags,
    content: content,
    sig: sig,
  ))
}

/// 保存の対象とするアカウントの pubkey の一覧を読み込む。
pub fn load_monitored(
  db: pog.Connection,
) -> Result(List(String), pog.QueryError) {
  pog.query(select_monitored_sql)
  |> pog.returning(decode.at([0], decode.string))
  |> pog.execute(on: db)
  |> result.map(fn(returned) { returned.rows })
}

/// 保存の対象とするアカウントを `pubkeys` に入れ替える。消去と挿入を 1 文の SQL で
/// 原子的に行うので、途中で失敗しても行は元のまま残る。
pub fn replace_monitored(
  db: pog.Connection,
  pubkeys: List(String),
) -> Result(Nil, pog.QueryError) {
  pog.query(replace_monitored_sql)
  |> pog.parameter(pog.array(pog.text, pubkeys))
  |> pog.execute(on: db)
  |> result.replace(Nil)
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

/// 指定したプロセスの未処理メッセージ数。プロセスが居なければ `Error(Nil)`。
pub fn pending_messages(pid: Pid) -> Result(Int, Nil) {
  decode.run(process_info(pid, atom.create("message_queue_len")), {
    use length <- decode.field(1, decode.int)
    decode.success(length)
  })
  |> result.replace_error(Nil)
}

/// プロセスの情報を 1 項目だけ問い合わせる。
@external(erlang, "erlang", "process_info")
fn process_info(pid: Pid, key: Atom) -> Dynamic
