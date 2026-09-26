//// `plugin_term` の部品を呼び出し元を通さずに確かめるテスト。

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/option.{None, Some}
import nostr_no_su/plugin_children
import nostr_no_su/plugin_term.{AtomKey, BinaryKey}
import support/erl.{tuple}

/// `関数/アリティ` の表記。呼び出し元が渡す関数名とアリティを `/` で繋ぐ。
pub fn export_label_joins_function_and_arity_test() {
  assert plugin_term.export_label(plugin_children.export_name, 0)
    == "plugin_children/0"
  assert plugin_term.export_label(plugin_children.export_name, 1)
    == "plugin_children/1"
}

/// 判別子は要素 0 が atom の `error` であることだけ。要素数は見ないので
/// `{error, A, B}` も `{error}` も同じく `True` で、atom でない要素 0 や
/// binary の `"error"` では `False` になる。
pub fn is_error_tuple_looks_only_at_element_zero_test() {
  assert plugin_term.is_error_tuple(
    error_tuple([dynamic.int(1), dynamic.int(2)]),
  )
  assert plugin_term.is_error_tuple(error_tuple([]))
  assert !plugin_term.is_error_tuple(
    tuple([atom.to_dynamic(atom.create("ok")), dynamic.int(1)]),
  )
  assert !plugin_term.is_error_tuple(dynamic.string("error"))
}

/// `Reason` が binary なら `Ok`、要素 1 が無ければ `Error(None)`、binary でなければ
/// その型の名前を `Error(Some(..))` で返す。
pub fn error_reason_tells_a_missing_reason_from_a_non_binary_test() {
  assert plugin_term.error_reason(error_tuple([dynamic.string("x")])) == Ok("x")
  assert plugin_term.error_reason(error_tuple([])) == Error(None)
  assert plugin_term.error_reason(error_tuple([dynamic.int(1)]))
    == Error(Some("Int"))
}

/// `AtomKey` は atom のキーだけを、`BinaryKey` は binary のキーだけを引く。
/// 同じ名前でも型が違うキーは見えない。
pub fn lookup_reads_only_the_given_key_type_test() {
  let map =
    dynamic.properties([
      #(atom.to_dynamic(atom.create("id")), dynamic.string("store")),
      #(dynamic.string("key"), dynamic.string("settings")),
    ])
  let assert Some(id) = plugin_term.lookup(map, AtomKey, "id")
  assert decode.run(id, decode.string) == Ok("store")
  assert plugin_term.lookup(map, BinaryKey, "id") == None
  let assert Some(key) = plugin_term.lookup(map, BinaryKey, "key")
  assert decode.run(key, decode.string) == Ok("settings")
}

/// 欠けたキーは `missing <key>`、decoder で読めない値は
/// `<key> must be <expected>, got <classify>` の理由になる。
pub fn required_reports_missing_and_mismatched_keys_test() {
  let map =
    dynamic.properties([
      #(dynamic.string("key"), dynamic.int(1)),
      #(dynamic.string("title"), dynamic.string("Settings")),
    ])
  assert plugin_term.required(
      dynamic.properties([]),
      BinaryKey,
      "title",
      "page #0",
      "a String",
      decode.string,
    )
    == Error("page #0: missing title")
  assert plugin_term.required(
      map,
      BinaryKey,
      "key",
      "page #0",
      "a String",
      decode.string,
    )
    == Error("page #0: key must be a String, got Int")
  assert plugin_term.required(
      map,
      BinaryKey,
      "title",
      "page #0",
      "a String",
      decode.string,
    )
    == Ok("Settings")
}

/// map なら `Ok(Nil)`、map でなければ `dynamic.classify` の型名を添えた
/// 形そのものの誤りになる。
pub fn check_map_reports_the_classified_shape_test() {
  assert plugin_term.check_map(
      dynamic.properties([]),
      "child #0",
      "a child specification map",
    )
    == Ok(Nil)
  assert plugin_term.check_map(
      tuple([dynamic.string("key"), dynamic.string("title")]),
      "child #0",
      "a child specification map",
    )
    == Error("child #0: must be a child specification map, got Array")
}

/// `f` には 0 起点の添字が渡り、最初の誤りで止める。誤りのあとの要素は
/// `f` を呼ばない（`f` は呼ばれるたびに 1 通送るので、届いた添字の並びが
/// 呼んだ回数と順序になる）。
pub fn try_map_indexed_stops_at_the_first_error_test() {
  assert plugin_term.try_map_indexed(["a", "b", "c"], fn(_, index) { Ok(index) })
    == Ok([0, 1, 2])

  let calls = process.new_subject()
  let result =
    plugin_term.try_map_indexed(["a", "b", "c"], fn(_, index) {
      process.send(calls, index)
      case index {
        1 -> Error("bad")
        _ -> Ok(index)
      }
    })
  assert result == Error("bad")
  assert process.receive(calls, 0) == Ok(0)
  assert process.receive(calls, 0) == Ok(1)
  assert process.receive(calls, 10) == Error(Nil)
}

/// 要素 0 が atom の `error` のタプルを組み立てる。
fn error_tuple(elements: List(Dynamic)) -> Dynamic {
  tuple([atom.to_dynamic(atom.create("error")), ..elements])
}
