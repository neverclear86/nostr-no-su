//// 任意エクスポート `plugin_children/0` の検証と変換のテスト。
////
//// 子仕様の map は `test/support/child_fixture.erl` が組み立てる。Gleam 側で
//// atom キーの map を作らないのは、本番のプラグインと同じ形を通すため。
////
//// `ChildSpecification` は公開レコードなので、プロセスを起こさずにフィールドを
//// 検査できる。start クロージャーもフィールドとして公開されているため、直接
//// 呼んで起動の失敗経路を確かめられる。
////
//// **登録名はテストごとに一意にすること。** BEAM の登録名は VM 全体で共有で、
//// `gleam test` は 1 つの VM で全テストを走らせる。

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/string
import nostr_no_su/plugin_children.{
  type Rejection, ConfigRejected, InvalidSpec, from_dynamic,
}

/// 子の起動失敗のログ行に出るプラグイン名。
const plugin_name = "children_test"

/// テストごとに一意な登録名。
fn unique_name(label: String) -> Atom {
  atom.create(
    label <> "_" <> int.to_string(unique_integer([atom.create("positive")])),
  )
}

/// fixture の子仕様 1 件を本番と同じ経路で変換する。アリティ 0 で呼ばれた
/// ことにするので、理由の文字列は従来どおり `plugin_children/0: ...` になる。
fn convert(
  specs: List(Dynamic),
) -> Result(List(ChildSpecification(Pid)), Rejection) {
  from_dynamic(dynamic.list(specs), plugin_name, 0)
}

/// 検証を通る子仕様 1 件を変換して取り出す。
fn child(kind: String, name: Atom) -> ChildSpecification(Pid) {
  let assert Ok([child]) = convert([spec(atom.create(kind), name)])
  child
}

/// 検証で弾かれる子仕様の理由。
fn rejected(kind: String) -> String {
  let assert Error(InvalidSpec(reason)) = convert([bad_spec(atom.create(kind))])
  reason
}

/// 子仕様が 0 件でも成功する。子を持たないプラグインと同じ扱いになる。
pub fn empty_list_test() {
  assert convert([]) == Ok([])
}

/// `id` と `start` だけの最小の子仕様は、OTP と同じ既定値になる。
pub fn minimal_spec_uses_otp_defaults_test() {
  let child = child("minimal", unique_name("store"))
  assert child.restart == supervision.Permanent
  assert child.child_type == supervision.Worker(5000)
  assert child.significant == False
}

/// `id` は binary でもよい。
pub fn binary_id_is_accepted_test() {
  let child = child("binary_id", unique_name("store"))
  assert child.child_type == supervision.Worker(5000)
}

/// `type => supervisor` はスーパーバイザーの子になる（shutdown は infinity 固定）。
pub fn supervisor_type_test() {
  let child = child("supervisor", unique_name("store"))
  assert child.child_type == supervision.Supervisor
}

/// `shutdown => infinity` の worker は負値で表す（`make_timeout/1` が infinity に
/// する）。
pub fn worker_infinity_shutdown_test() {
  let child = child("infinity", unique_name("store"))
  assert child.child_type == supervision.Worker(-1)
}

/// `shutdown` のミリ秒はそのまま渡る。
pub fn worker_shutdown_ms_test() {
  let child = child("shutdown_100", unique_name("store"))
  assert child.child_type == supervision.Worker(100)
}

/// `restart` の 3 つの値がそれぞれ対応する `Restart` になる。
pub fn restart_values_test() {
  assert child("transient", unique_name("store")).restart
    == supervision.Transient
  assert child("temporary", unique_name("store")).restart
    == supervision.Temporary
  assert child("store", unique_name("store")).restart == supervision.Permanent
}

/// `brutal_kill` は `ChildSpecification` が表現できないので拒否する。
pub fn brutal_kill_is_rejected_test() {
  let reason = rejected("brutal_kill")
  assert string.contains(reason, "brutal_kill")
  assert string.contains(reason, "unsupported shutdown")
}

/// 負の `shutdown` は `infinity` の内部表現（負値）と衝突して黙って意味が変わる
/// ため拒否する。
pub fn negative_shutdown_is_rejected_test() {
  let reason = rejected("negative_shutdown")
  assert string.contains(reason, "unsupported shutdown")
  assert string.contains(reason, "-1")
}

/// スーパーバイザーの子に有限の `shutdown` は書けない。黙って `infinity` に
/// 変わるくらいなら理由を出して弾く。
pub fn supervisor_with_finite_shutdown_is_rejected_test() {
  assert string.contains(
    rejected("supervisor_shutdown"),
    "shutdown => infinity",
  )
}

/// 未知の `restart` は、受け取った値をそのまま見せて拒否する。
pub fn unknown_restart_is_rejected_test() {
  assert string.contains(rejected("bad_restart"), "whenever")
}

/// 未知の `type` も同じ形で拒否する。
pub fn unknown_type_is_rejected_test() {
  assert string.contains(rejected("bad_type"), "daemon")
}

/// `id` が無ければ、0 起点の連番でどの子かを示す。
pub fn missing_id_is_rejected_test() {
  let reason = rejected("no_id")
  assert string.contains(reason, "plugin_children/0: child #0: missing id")
  // `decode` のパス（`0.<Atom>`）が漏れていない。
  assert !string.contains(reason, "<Atom>")
}

/// `start` が無ければ、`id` をラベルにして名指しで報告する。
pub fn missing_start_is_rejected_test() {
  let reason = rejected("no_start")
  assert string.contains(reason, "child \"store\": missing start")
  assert !string.contains(reason, "<Atom>")
}

/// 素の `{Module, Function, Args}` の短縮形は、map でないことを名指しで拒否する。
/// 「`id` が無い」と報告すると、作者が原因にたどり着けない。
pub fn bare_mfa_is_rejected_test() {
  let reason = rejected("bare_mfa")
  assert string.contains(
    reason,
    "child #0: must be a child specification map, got Array",
  )
}

/// `start` が 3 要素タプルでなければ拒否する。
pub fn bad_start_is_rejected_test() {
  let reason = rejected("bad_start")
  assert string.contains(reason, "child \"store\":")
  assert string.contains(reason, "start must be")
  assert !string.contains(reason, "<Atom>")
}

/// リストでない値を返すプラグインは、その場で拒否する。
pub fn non_list_is_rejected_test() {
  let assert Error(InvalidSpec(reason)) =
    from_dynamic(atom.to_dynamic(atom.create("nope")), plugin_name, 0)
  assert string.contains(
    reason,
    "plugin_children/0 must return a list of child specification maps",
  )
}

/// アリティ 1 で呼ばれた場合、理由の文字列も `plugin_children/1` になる。
pub fn reason_names_the_called_arity_test() {
  let assert Error(InvalidSpec(reason)) =
    from_dynamic(atom.to_dynamic(atom.create("nope")), plugin_name, 1)
  assert string.contains(
    reason,
    "plugin_children/1 must return a list of child specification maps",
  )
}

/// `{error, Reason}` は設定の拒否として受理する。**リストのデコードより先に
/// 判定する**ため、2 要素タプルが「長さ 2 のリスト」として解釈されることはない。
pub fn error_tuple_is_a_config_rejection_test() {
  assert from_dynamic(
      error_tuple(dynamic.string("path is required")),
      plugin_name,
      1,
    )
    == Error(ConfigRejected("path is required"))
}

/// 理由が binary でない `{error, Reason}` は、設定の拒否ではなく戻り値の形の
/// 誤りとして報告する。
pub fn error_tuple_with_non_binary_reason_test() {
  let assert Error(InvalidSpec(reason)) =
    from_dynamic(
      error_tuple(atom.to_dynamic(atom.create("nope"))),
      plugin_name,
      1,
    )
  assert reason == "plugin_children/1: error reason must be a String, got Atom"
}

/// 判別子は「要素 0 が atom の `error`」だけである。`{ok, 1}` は設定の拒否とは
/// 見なさず、子仕様のリストとして検証されて弾かれる。
pub fn ok_tuple_is_not_a_config_rejection_test() {
  let assert Error(InvalidSpec(reason)) =
    from_dynamic(
      tuple([atom.to_dynamic(atom.create("ok")), dynamic.int(1)]),
      plugin_name,
      1,
    )
  assert string.contains(
    reason,
    "child #0: must be a child specification map, got Atom",
  )
}

/// 正しい子仕様のリストも設定の拒否と誤判定されない。
pub fn child_list_is_not_a_config_rejection_test() {
  let assert Ok([_]) =
    convert([spec(atom.create("minimal"), unique_name("store"))])
}

/// `{error, Reason}` を組み立てる。
fn error_tuple(reason: Dynamic) -> Dynamic {
  tuple([atom.to_dynamic(atom.create("error")), reason])
}

/// 任意の項からタプルを作る。Gleam にはタプルを動的に組み立てる手段が無い。
@external(erlang, "erlang", "list_to_tuple")
fn tuple(elements: List(Dynamic)) -> Dynamic

/// 壊れている箇所が複数あっても、報告するのは最初に検査したキーの 1 件だけ。
pub fn only_the_first_error_is_reported_test() {
  let reason = rejected("everything")
  assert string.contains(reason, "missing id")
  assert !string.contains(reason, "whenever")
}

/// 正しい MFA は Pid を返し、その子は生きている。
pub fn start_returns_a_live_child_test() {
  let name = unique_name("store")
  let assert Ok(started) = child("store", name).start()
  assert process.is_alive(started.pid)
  // start クロージャーはテストプロセス上で走るため、子はテストプロセスに
  // リンクされている。巻き添えを避けてから片付ける。
  process.unlink(started.pid)
  process.kill(started.pid)
}

/// `{error, Reason}` を返す MFA は、id と生の理由を添えて失敗になる。
pub fn start_failure_reports_the_id_and_reason_test() {
  let name = unique_name("store")
  let assert Error(actor.InitFailed(reason)) = child("failing", name).start()
  assert string.contains(reason, atom.to_string(name))
  assert string.contains(reason, "nope")
}

/// `ignore` は Gleam 側が Pid を要求するため未対応。理由にそのまま出す。
pub fn start_ignore_is_rejected_test() {
  let assert Error(actor.InitFailed(reason)) =
    child("ignoring", unique_name("store")).start()
  assert string.contains(reason, "ignore")
}

/// MFA が例外を投げても起動が止まらず、理由が 1 行になる。
pub fn start_exception_becomes_a_reason_test() {
  let assert Error(actor.InitFailed(reason)) =
    child("crashing", unique_name("store")).start()
  assert string.contains(reason, "error:undef")
}

/// リンクを張らない MFA は監視漏れになるので、その場で kill して失敗にする。
pub fn start_without_link_is_rejected_test() {
  let name = unique_name("store")
  let assert Error(actor.InitFailed(reason)) = child("unlinked", name).start()
  assert string.contains(reason, "did not link")
  // 孤児は kill 済み（登録名が解放される）。
  assert await_unregistered(name, 1000)
}

/// Gleam の `Ok(actor.Started(..))`（`{ok, {started, Pid, Data}}`）は `{ok, Pid}`
/// ではないので弾く。Gleam で書いたプラグインが薄いシムを要る根拠。
pub fn start_gleam_style_return_is_rejected_test() {
  let assert Error(actor.InitFailed(reason)) =
    child("gleam_style", unique_name("store")).start()
  assert string.contains(reason, "unexpected start return")
}

/// **リンクは張ったが戻る前に子が死んでいる場合は成功にする。** 死んだ子は
/// リンク集合から消えるが、監視漏れではなく普通のクラッシュであり、再起動は
/// OTP に任せればよい。ここを失敗にすると、本来は再起動されるクラッシュが
/// 起動失敗に化けて、そのプラグインの子が丸ごと諦められる。
///
/// 子はテストプロセスにリンクされたまま死ぬので、**先に exit を trap する。**
/// trap しないとテストプロセスが巻き添えで死ぬ。メールボックスに残る
/// `{'EXIT', ..}` は読まないが、gleeunit がテストごとに別プロセスを起こすため、
/// テストの終了とともに捨てられる。
pub fn start_of_a_child_that_died_is_not_a_link_failure_test() {
  process.trap_exits(True)
  let assert Ok(started) = child("dying", unique_name("store")).start()
  assert !process.is_alive(started.pid)
  process.trap_exits(False)
}

/// **`supervision.timeout(_, -1)` が OTP の `shutdown => infinity` になることを
/// 押さえる唯一のテスト。** Gleam のレコードの値だけを見ても、gleam_otp が負値を
/// `infinity` に変換することは検証できない。gleam_otp の更新でこの対応が壊れたら
/// ここが落ちる。
///
/// 子の id は `static_supervisor` が採番するので `0` になる（プラグインが申告した
/// `id` は OTP へ渡らない）。停止に `send_exit` が効くのは、テストプロセスが
/// このスーパーバイザーの親だからである（gen_server は親からの EXIT で終了する）。
pub fn worker_shutdown_reaches_otp_test() {
  let assert Ok(started) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(child("infinity", unique_name("store")))
    |> supervisor.start
  assert childspec_value(started.pid, 0, "shutdown") == "infinity"
  assert childspec_value(started.pid, 0, "type") == "worker"
  process.send_exit(started.pid)
}

/// 有限の `shutdown` はミリ秒のまま OTP へ届く。
pub fn finite_worker_shutdown_reaches_otp_test() {
  let assert Ok(started) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(child("shutdown_100", unique_name("store")))
    |> supervisor.start
  assert childspec_value(started.pid, 0, "shutdown") == "100"
  process.send_exit(started.pid)
}

/// 登録名が解放されるまで待つ。
fn await_unregistered(name: Atom, remaining: Int) -> Bool {
  case is_registered(name), remaining <= 0 {
    False, _ -> True
    _, True -> False
    _, False -> {
      process.sleep(10)
      await_unregistered(name, remaining - 10)
    }
  }
}

/// OTP に登録された子仕様のフィールドを 1 行の文字列で読む。
fn childspec_value(supervisor: Pid, id: Int, key: String) -> String {
  let decoder = decode.field(atom.create(key), decode.dynamic, decode.success)
  let assert Ok(value) = decode.run(childspec(supervisor, id), decoder)
  describe_term(value)
}

/// 検証を通る子仕様。
@external(erlang, "child_fixture", "spec")
fn spec(kind: Atom, name: Atom) -> Dynamic

/// 検証で弾かれる子仕様。
@external(erlang, "child_fixture", "bad_spec")
fn bad_spec(kind: Atom) -> Dynamic

/// 登録名が使われているか。
@external(erlang, "child_fixture", "is_registered")
fn is_registered(name: Atom) -> Bool

/// OTP 側に登録された子仕様。
@external(erlang, "child_fixture", "childspec")
fn childspec(supervisor: Pid, id: Int) -> Dynamic

/// 任意の項を 1 行の文字列にする。
@external(erlang, "nostr_no_su_ffi", "describe_term")
fn describe_term(term: Dynamic) -> String

/// テストごとに一意な整数。
@external(erlang, "erlang", "unique_integer")
fn unique_integer(options: List(Atom)) -> Int
