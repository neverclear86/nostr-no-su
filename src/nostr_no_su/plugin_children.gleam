//// 任意エクスポート `plugin_children/0` `plugin_children/1` の検証と、
//// スーパービジョンツリーの子仕様への変換。
////
//// **どちらも任意エクスポートであり、API バージョンは上げない。** 持たない
//// プラグインは従来どおり子を持たないものとして読み込まれる。呼び出しは
//// `plugin.load` の中で起動時に 1 度だけ行う。返るのは MFA を含む純粋なデータで
//// あってプロセスではないため、再起動のたびに問い合わせ直す必要がなく、ツリーを
//// 起動時に組み立てる `static_supervisor` の前提と噛み合う。
////
//// **アリティの選び方。** `plugin_children/1` があればそちらを呼び、プラグイン
//// 固有の設定 map（`plugin_config.to_map` の形）を渡す。無ければ
//// `plugin_children/0` を呼ぶ。どちらも無ければ問い合わせない。判定は
//// `plugin.gleam` が行い、このモジュールへは引数のリストとして渡ってくる
//// （アリティはその長さから決まる）。
////
//// **`{error, Reason}` で設定を拒否できる。** 子仕様のリストの代わりに
//// `{error, Reason :: binary()}` を返すと、「設定が足りない・不正なのでこの
//// プラグインを読み込まないでほしい」という申告になる。判別子は**要素 0 が
//// atom の `error` であること**だけで、要素数は見ない。**この判定はリストの
//// デコードより先に行う**（Erlang の 2 要素タプルは `decode.list` で長さ 2 の
//// リストとしてデコードされるため、後に回すと無関係な理由が出る）。
////
//// 子プロセスを持たないプラグインも、設定の検査だけのために
//// `plugin_children/1` をエクスポートし、設定が揃っていれば `[]` を返してよい。
//// その場合も本体が出す 1 行は
//// `plugin_children/1 rejected the configuration (...)` になる。関数名が
//// 「子仕様」と言っているのに設定の検査結果を報告する形になるが、これは設定が
//// 子仕様を組み立てるために要るという設計判断の裏面である。
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
//// 押さえておくべき点。
////
//// - **`id` は OTP へは渡らない。** `static_supervisor` が子の id を自分で採番
////   するため、ここでの `id` は理由の文字列とログ行にだけ使う。それでも必須に
////   しているのは、失敗した子を運用者が特定できるようにするためである。
//// - **`shutdown => infinity` は `supervision.timeout(_, -1)` で表す。**
////   `static_supervisor` の `make_timeout/1` が負値を `infinity` に変換すること
////   に依存している。**gleam_otp を更新したら `convert_child` / `make_timeout` を
////   読み直すこと。** この対応を破ったときに落ちる唯一のテストが
////   `plugin_children_test.worker_shutdown_reaches_otp_test` である。
//// - **`type => supervisor` に有限の `shutdown` は書けない。**
////   `supervision.timeout/2` は Worker にしか効かず、Supervisor の shutdown は
////   `make_timeout(-1)`（= `infinity`）に固定される。受け取った値が黙って別の
////   意味になるため、`brutal_kill` と同じく理由を出して拒否する。
//// - **失敗の理由は自前で組み立て、`decode` のパスに頼らない。** atom キーの map
////   に対する `decode.run` のエラーはパスが `0.<Atom>` にしかならず、プラグイン
////   作者の役に立たない。**報告するのは最初の 1 件だけ**にして 1 行に収める。
//// - **子の起動に失敗したときの 1 行ログはこのモジュールが出す。**
////   `static_supervisor.start` の戻り値には理由が残らない（`gleam_otp_external`
////   が `{shutdown, {failed_to_start_child, Id, Reason}}` を
////   `InitFailed("shutdown")` に潰す）ため、id と生の理由を両方持っている
////   子ごとの start クロージャーだけが理由を運用者に届けられる。
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

/// 本体が問い合わせる任意エクスポートの名前。
pub const export_name = "plugin_children"

/// 子仕様が採れなかった理由。本体はこの 2 つを別々の 1 行に整える。
pub type Rejection {
  /// 戻り値の形が API に合わない（従来からの検証失敗）。
  InvalidSpec(reason: String)
  /// プラグイン自身が設定を受け付けなかった（`{error, Reason}`）。
  ConfigRejected(reason: String)
}

/// 理由の文字列とログ行に出す `plugin_children/<アリティ>` という表記。本体側も
/// 同じ表記を組み立てるため、1 か所にまとめて公開している。
pub fn export_label(arity: Int) -> String {
  export_name <> "/" <> int.to_string(arity)
}

/// worker の既定の shutdown（OTP と同じ）。
const default_shutdown_ms = 5000

/// `infinity` を表す shutdown。`static_supervisor` の `make_timeout/1` が負値を
/// `infinity` にすることに依存する。
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

/// モジュールの `plugin_children/<アリティ>` を呼び、子仕様を検証して変換する。
/// **`plugin.load` の必須エクスポート検証を通った後にだけ呼ぶこと。**
/// `name` は `plugin_name/0` の値で、子の起動失敗を報告するログの接頭辞に使う。
/// `args` は呼び出しの引数で、アリティはその長さから決まる（設定を渡す形なら
/// 設定 map 1 つ、渡さない形なら空）。
pub fn from_export(
  module: Atom,
  name: String,
  args: List(Dynamic),
) -> Result(List(ChildSpecification(Pid)), Rejection) {
  let arity = list.length(args)
  case call_export(module, atom.create(export_name), args) {
    Error(reason) ->
      Error(InvalidSpec(export_label(arity) <> " crashed (" <> reason <> ")"))
    Ok(value) -> from_dynamic(value, name, arity)
  }
}

/// 子仕様のリスト（Dynamic）を検証して変換する。最初に失敗したところで止め、
/// その 1 行を返す。呼び出しを伴わない単体テストと、ツリー全体のテストが本番と
/// 同じ経路を通るために公開している。
///
/// **`{error, Reason}` の判定はリストのデコードより先に行う。** Erlang の
/// 2 要素タプルは `decode.list` で長さ 2 のリストとしてデコードされるため、
/// 順序を逆にすると設定の拒否が「子仕様の形が違う」という無関係な理由になる。
pub fn from_dynamic(
  value: Dynamic,
  name: String,
  arity: Int,
) -> Result(List(ChildSpecification(Pid)), Rejection) {
  let label = export_label(arity)
  case is_error_tuple(value) {
    True -> Error(config_rejection(value, label))
    False -> children(value, name, label)
  }
}

/// 戻り値が設定の拒否（`{error, Reason}`）かどうか。**判別子は要素 0 が atom の
/// `error` であることだけ**で、要素数は見ない。要素数を条件に入れると
/// `{error, A, B}` の扱いを別途決めることになる。
fn is_error_tuple(value: Dynamic) -> Bool {
  case decode.run(value, decode.at([0], atom.decoder())) {
    Ok(tag) -> atom.to_string(tag) == "error"
    Error(_) -> False
  }
}

/// `{error, Reason}` の理由を取り出す。理由が binary でなければ、設定の拒否では
/// なく戻り値の形の誤りとして報告する。
fn config_rejection(value: Dynamic, label: String) -> Rejection {
  case decode.run(value, decode.at([1], decode.dynamic)) {
    Error(_) ->
      InvalidSpec(label <> ": error reason must be a String, got nothing")
    Ok(reason) ->
      case decode.run(reason, decode.string) {
        Ok(text) -> ConfigRejected(text)
        Error(_) ->
          InvalidSpec(
            label
            <> ": error reason must be a String, got "
            <> dynamic.classify(reason),
          )
      }
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
  |> list.index_map(fn(child, index) { #(child, index) })
  |> list.try_map(fn(pair) {
    spec(pair.0, pair.1)
    |> result.map_error(fn(reason) { InvalidSpec(label <> ": " <> reason) })
  })
  |> result.map(list.map(_, to_child(_, name)))
}

/// 子仕様 1 件を検証する。ラベルは `id` が読めれば `child "store"`、読めなければ
/// `child #0` になる（`list.index_map` と同じ 0 起点）。理由の先頭に必ず付ける。
fn spec(raw: Dynamic, index: Int) -> Result(Spec, String) {
  let unlabelled = "child #" <> int.to_string(index)
  use _ <- result.try(check_map(raw, unlabelled))
  use id <- result.try(required(
    raw,
    "id",
    unlabelled,
    "an atom or a string",
    id_decoder(),
  ))
  let label = "child \"" <> id <> "\""
  use start <- result.try(required(
    raw,
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

/// 子仕様が map であることを先に確かめる。素の `{Module, Function, Args}` の
/// 短縮形を渡されたとき、キーが 1 つも読めないことを「`id` が無い」と報告すると
/// 作者が原因にたどり着けない。形そのものの誤りとして報告する。
/// `dynamic.classify` は map を `Dict`、タプルを `Array` と呼ぶ。
fn check_map(raw: Dynamic, label: String) -> Result(Nil, String) {
  case dynamic.classify(raw) {
    "Dict" -> Ok(Nil)
    other ->
      Error(label <> ": must be a child specification map, got " <> other)
  }
}

/// map から任意のキーを取り出す。無ければ（map ですらなければ）`None`。
fn lookup(raw: Dynamic, key: String) -> Option(Dynamic) {
  let decoder =
    decode.optional_field(
      atom.create(key),
      None,
      decode.map(decode.dynamic, Some),
      decode.success,
    )
  decode.run(raw, decoder)
  |> result.unwrap(None)
}

/// 必須のキーを読む。欠けていれば `<label>: missing <key>`、型が合わなければ
/// `<label>: <key> must be <expected>, got <classify>`。
fn required(
  raw: Dynamic,
  key: String,
  label: String,
  expected: String,
  decoder: decode.Decoder(a),
) -> Result(a, String) {
  case lookup(raw, key) {
    None -> Error(label <> ": missing " <> key)
    Some(value) ->
      decode.run(value, decoder)
      |> result.replace_error(
        label
        <> ": "
        <> key
        <> " must be "
        <> expected
        <> ", got "
        <> dynamic.classify(value),
      )
  }
}

/// `id` は atom でも binary でもよい。どちらも文字列にして理由とログに使う。
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
  case lookup(raw, "restart") {
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
  case lookup(raw, "shutdown") {
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
  case lookup(raw, "type") {
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

/// worker の shutdown。`infinity` は負値で表す（`static_supervisor` の
/// `make_timeout/1` が負値を infinity にする）。既定は OTP と同じ 5000ms。
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
      log.println(log.plugin_prefix(name), detail)
      Error(actor.InitFailed(detail))
    }
  }
}

/// 例外を捕まえて任意エクスポートを呼ぶ。理由は 1 行の文字列になる。
@external(erlang, "nostr_no_su_ffi", "call_export")
fn call_export(
  module: Atom,
  function: Atom,
  args: List(Dynamic),
) -> Result(Dynamic, String)

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
