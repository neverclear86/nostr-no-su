//// 任意エクスポート `plugin_children/0` `plugin_children/1` の戻り値を検証し、
//// スーパービジョンツリーの子仕様に変換する。呼び出しは `plugin.load` が起動時に
//// 1 度だけ期限付きで行い、このモジュールには戻り値とアリティが渡ってくる。
//// 返るのは MFA を含む純粋なデータであってプロセスではないため、再起動のたびに
//// 問い合わせ直す必要がなく、ツリーを起動時に組み立てる `static_supervisor`
//// の前提と噛み合う。
////
//// **境界に置くのは OTP の `supervisor:child_spec()` の map であって、Gleam の
//// レコードではない。** Gleam のレコードはランタイムではタグ付きタプルであり、
//// Erlang や Elixir で書いたプラグインからは組み立てられない。イベントを map に
//// したのと同じ理由である。
////
//// ```erlang
//// #{
////     id       => atom() | binary(),                  %% 必須
////     start    => {module(), atom(), [term()]},       %% 必須。必ずリンクを張る関数
////     restart  => permanent | transient | temporary,  %% 任意。既定 permanent
////     shutdown => non_neg_integer() | infinity,       %% 任意。既定 5000（worker）
////     type     => worker | supervisor                 %% 任意。既定 worker
//// }
//// ```
////
//// 仕様の全文（プラグイン作者向け）は `docs/plugin-api.md` の第 5 章と第 6 章に
//// ある。

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import nostr_no_su/log
import nostr_no_su/plugin_term.{AtomKey}

/// 本体が問い合わせる任意エクスポートの名前。
pub const export_name = "plugin_children"

/// 子仕様が採れなかった理由。本体はこの 2 つを別々の 1 行に整える。
pub type Rejection {
  /// 戻り値の形が API に合わない。
  InvalidSpec(reason: String)
  /// プラグイン自身が設定を受け付けなかった（`{error, Reason}`）。
  ConfigRejected(reason: String)
}

/// worker の既定の shutdown（OTP と同じ）。
const default_shutdown_ms = 5000

/// `infinity` を表す shutdown。`static_supervisor` の `make_timeout/1` が負値を
/// `infinity` にすることに依存するので、gleam_otp を更新したら `convert_child` と
/// `make_timeout` を読み直す。
const infinity_shutdown_ms = -1

/// 検証済みの子仕様 1 件。
type Spec {
  Spec(
    id: String,
    start: Mfa,
    restart: supervision.Restart,
    shutdown: Option(Shutdown),
    kind: Kind,
  )
}

/// 子を起こす関数。プラグインが自己完結した形で申告する（登録名の解決も含めて
/// この中で行われる）。
type Mfa {
  Mfa(module: Atom, function: Atom, args: List(Dynamic))
}

/// 停止に与える猶予。
type Shutdown {
  After(ms: Int)
  Infinity
}

/// 子がワーカーかスーパーバイザーか。`supervision.ChildType` と違い shutdown を
/// 含まないので、検証の途中で 2 つを独立に扱える。
type Kind {
  Worker
  Supervisor
}

/// 子仕様のリスト（Dynamic）を検証して変換する。最初に失敗したところで止め、
/// その 1 行を返す。本体では `plugin.load` が期限付きで呼んだ戻り値を渡す。
/// 単体テストとツリー全体のテストも同じ経路を通る。
///
/// **`{error, Reason}` の判定はリストのデコードより先に行う。** Erlang の
/// 2 要素タプルは `decode.list` で長さ 2 のリストとしてデコードされるため、
/// 順序を逆にすると設定の拒否が「子仕様の形が違う」という無関係な理由になる。
pub fn from_dynamic(
  value: Dynamic,
  name: String,
  arity: Int,
) -> Result(List(ChildSpecification(Pid)), Rejection) {
  let label = plugin_term.export_label(export_name, arity)
  case plugin_term.is_error_tuple(value) {
    True -> Error(config_rejection(value, label))
    False -> children(value, name, label)
  }
}

/// `{error, Reason}` の理由を取り出す。理由が binary でなければ、設定の拒否では
/// なく戻り値の形の誤りとして報告する。
fn config_rejection(value: Dynamic, label: String) -> Rejection {
  case plugin_term.error_reason(value) {
    Ok(text) -> ConfigRejected(text)
    Error(got) ->
      InvalidSpec(plugin_term.reason_not_a_string(
        label,
        option.unwrap(got, "nothing"),
      ))
  }
}

/// 子仕様のリストを検証して変換する。
fn children(
  value: Dynamic,
  name: String,
  label: String,
) -> Result(List(ChildSpecification(Pid)), Rejection) {
  use raw <- result.try(
    decode.run(value, decode.list(decode.dynamic))
    |> result.replace_error(InvalidSpec(
      label
      <> " must return a list of child specification maps, got "
      <> dynamic.classify(value),
    )),
  )
  raw
  |> plugin_term.try_map_indexed(spec)
  |> result.map_error(fn(reason) { InvalidSpec(label <> ": " <> reason) })
  |> result.map(list.map(_, to_child(_, name)))
}

/// 子仕様 1 件を検証する。ラベルは `id` が読めれば `child "store"`、読めなければ
/// `child #0` になる（`plugin_term.try_map_indexed` と同じ 0 起点）。理由の先頭に必ず付ける。
fn spec(raw: Dynamic, index: Int) -> Result(Spec, String) {
  let unlabelled = "child #" <> int.to_string(index)
  use _ <- result.try(plugin_term.check_map(
    raw,
    unlabelled,
    "a child specification map",
  ))
  use id <- result.try(plugin_term.required(
    raw,
    AtomKey,
    "id",
    unlabelled,
    "an atom or a string",
    id_decoder(),
  ))
  let label = "child \"" <> id <> "\""
  use start <- result.try(plugin_term.required(
    raw,
    AtomKey,
    "start",
    label,
    "a {Module, Function, Args} tuple",
    mfa_decoder(),
  ))
  use restart <- result.try(read_restart(raw, label))
  use shutdown <- result.try(read_shutdown(raw, label))
  use kind <- result.try(read_kind(raw, label))
  use _ <- result.try(check_supervisor_shutdown(kind, shutdown, label))
  Ok(Spec(id:, start:, restart:, shutdown:, kind:))
}

/// `id` は atom でも binary でもよい。どちらも文字列にして理由とログに使う。
/// `static_supervisor` が子の id を自分で採番するので OTP へは渡らないが、失敗した
/// 子を運用者が特定できるよう必須にしている。
fn id_decoder() -> decode.Decoder(String) {
  decode.one_of(decode.string, [decode.map(atom.decoder(), atom.to_string)])
}

/// `start` は `{Module, Function, Args}` の 3 要素タプル。整数の添字は
/// `gleam_stdlib` の `index/2` がタプルにも効く。
fn mfa_decoder() -> decode.Decoder(Mfa) {
  use module <- decode.field(0, atom.decoder())
  use function <- decode.field(1, atom.decoder())
  use args <- decode.field(2, decode.list(decode.dynamic))
  decode.success(Mfa(module:, function:, args:))
}

/// `restart`。既定は OTP と同じ `permanent`。
fn read_restart(
  raw: Dynamic,
  label: String,
) -> Result(supervision.Restart, String) {
  case plugin_term.lookup(raw, AtomKey, "restart") {
    None -> Ok(supervision.Permanent)
    Some(value) ->
      case atom_name(value) {
        Ok("permanent") -> Ok(supervision.Permanent)
        Ok("transient") -> Ok(supervision.Transient)
        Ok("temporary") -> Ok(supervision.Temporary)
        _ ->
          Error(
            label
            <> ": unsupported restart ("
            <> describe_term(value)
            <> "); use permanent, transient or temporary",
          )
      }
  }
}

/// `shutdown`。`brutal_kill` は `ChildSpecification` が表現できないので拒否する
/// （`0` ms に丸めるのは意味を黙って変えることになる）。負の整数も、
/// `infinity` の内部表現と衝突して黙って意味が変わるため拒否する。
fn read_shutdown(
  raw: Dynamic,
  label: String,
) -> Result(Option(Shutdown), String) {
  case plugin_term.lookup(raw, AtomKey, "shutdown") {
    None -> Ok(None)
    Some(value) ->
      case decode.run(value, decode.int), atom_name(value) {
        Ok(ms), _ if ms >= 0 -> Ok(Some(After(ms)))
        _, Ok("infinity") -> Ok(Some(Infinity))
        _, _ ->
          Error(
            label
            <> ": unsupported shutdown ("
            <> describe_term(value)
            <> "); use a number of milliseconds or infinity",
          )
      }
  }
}

/// `type`。既定は `worker`。
fn read_kind(raw: Dynamic, label: String) -> Result(Kind, String) {
  case plugin_term.lookup(raw, AtomKey, "type") {
    None -> Ok(Worker)
    Some(value) ->
      case atom_name(value) {
        Ok("worker") -> Ok(Worker)
        Ok("supervisor") -> Ok(Supervisor)
        _ ->
          Error(
            label
            <> ": unsupported type ("
            <> describe_term(value)
            <> "); use worker or supervisor",
          )
      }
  }
}

/// スーパーバイザーの子に有限の `shutdown` は書けない。`supervision.timeout/2` が
/// Worker にしか効かず、受け取った値が黙って `infinity` になってしまうため。
fn check_supervisor_shutdown(
  kind: Kind,
  shutdown: Option(Shutdown),
  label: String,
) -> Result(Nil, String) {
  case kind, shutdown {
    Supervisor, Some(After(_)) ->
      Error(label <> ": supervisor children must use shutdown => infinity")
    _, _ -> Ok(Nil)
  }
}

/// atom を文字列として読む。atom でなければ `Error`。
fn atom_name(value: Dynamic) -> Result(String, Nil) {
  decode.run(value, atom.decoder())
  |> result.replace_error(Nil)
  |> result.map(atom.to_string)
}

/// 検証済みの子仕様をスーパービジョンツリーの子仕様にする。
fn to_child(spec: Spec, name: String) -> ChildSpecification(Pid) {
  let start = fn() { start(spec, name) }
  case spec.kind {
    Supervisor -> supervision.supervisor(start)
    Worker ->
      supervision.worker(start)
      |> supervision.timeout(shutdown_ms(spec.shutdown))
  }
  |> supervision.restart(spec.restart)
}

/// worker の shutdown。`infinity` は `infinity_shutdown_ms` が表す。既定は
/// OTP と同じ 5000ms。
fn shutdown_ms(shutdown: Option(Shutdown)) -> Int {
  case shutdown {
    None -> default_shutdown_ms
    Some(Infinity) -> infinity_shutdown_ms
    Some(After(ms)) -> ms
  }
}

/// 子を 1 つ起動する。**失敗したらここで 1 行ログを出す。**
/// `static_supervisor.start` の戻り値は `gleam_otp_external` が
/// `{shutdown, {failed_to_start_child, Id, Reason}}` を `InitFailed("shutdown")`
/// に潰してしまい、Id も Reason も残らない。理由を運用者に届けられるのは、id と
/// 生の理由を両方持っているこの場所だけである。
fn start(
  spec: Spec,
  name: String,
) -> Result(actor.Started(Pid), actor.StartError) {
  case start_child(spec.start.module, spec.start.function, spec.start.args) {
    Ok(pid) -> Ok(actor.Started(pid: pid, data: pid))
    Error(reason) -> {
      let detail =
        "child \"" <> spec.id <> "\" failed to start (" <> reason <> ")"
      log.write(log.Warning, log.plugin_prefix(name), detail)
      Error(actor.InitFailed(detail))
    }
  }
}

/// 子仕様の MFA を呼び、リンクを確かめて Pid を返す。
@external(erlang, "nostr_no_su_ffi", "start_child")
fn start_child(
  module: Atom,
  function: Atom,
  args: List(Dynamic),
) -> Result(Pid, String)

/// 任意の項を 1 行の文字列にする。`dynamic.classify` では `brutal_kill` と
/// `permanent` がどちらも `Atom` になり作者の役に立たないため、受け取った値を
/// そのまま見せるのに使う。
@external(erlang, "nostr_no_su_ffi", "describe_term")
fn describe_term(term: Dynamic) -> String
