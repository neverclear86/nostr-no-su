//// `plugin_term` の部品を呼び出し元を通さずに確かめるテスト。

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/option.{None, Some}
import nostr_no_su/plugin_term.{AtomKey, BinaryKey}
import support/erl.{tuple}

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

/// atom ならその名前を返し、同じ綴りの binary や atom でない値は `Error(Nil)`。
pub fn atom_name_reads_only_atoms_test() {
  assert plugin_term.atom_name(atom.to_dynamic(atom.create("permanent")))
    == Ok("permanent")
  assert plugin_term.atom_name(dynamic.string("permanent")) == Error(Nil)
  assert plugin_term.atom_name(dynamic.int(1)) == Error(Nil)
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

/// 欠けたキーは `<label>: missing <key>`、decoder で読めない値は
/// `<label>: <key> must be <expected>, got <classify>` の理由になる。
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

/// 欠けたキーは `missing <key>`、decoder で読めない値は
/// `<key> must be <expected>, got <classify>` の理由になり、`<label>: ` の前置は付かない。
pub fn field_reports_missing_and_mismatched_keys_without_a_label_test() {
  let map =
    dynamic.properties([
      #(dynamic.string("key"), dynamic.int(1)),
      #(dynamic.string("title"), dynamic.string("Settings")),
    ])
  assert plugin_term.field(
      dynamic.properties([]),
      BinaryKey,
      "title",
      "a String",
      decode.string,
    )
    == Error("missing title")
  assert plugin_term.field(map, BinaryKey, "key", "a String", decode.string)
    == Error("key must be a String, got Int")
  assert plugin_term.field(map, BinaryKey, "key", "an Int", decode.int) == Ok(1)
}

/// 無ければ（map ですらなければ）`Ok(None)`、decoder で読めない値は
/// `<key> must be <expected>, got <classify>` の理由になる。
pub fn optional_field_reads_an_absent_key_as_none_test() {
  let map =
    dynamic.properties([#(dynamic.string("checked"), dynamic.string("yes"))])
  assert plugin_term.optional_field(
      dynamic.properties([]),
      BinaryKey,
      "checked",
      "a Bool",
      decode.bool,
    )
    == Ok(None)
  assert plugin_term.optional_field(
      map,
      BinaryKey,
      "checked",
      "a Bool",
      decode.bool,
    )
    == Error("checked must be a Bool, got String")
  assert plugin_term.optional_field(
      map,
      BinaryKey,
      "checked",
      "a String",
      decode.string,
    )
    == Ok(Some("yes"))
}

/// 空文字と、`alphabet` に無い文字を含む文字列は `False` になる。
pub fn consists_of_accepts_only_non_empty_text_from_the_alphabet_test() {
  assert plugin_term.consists_of("ab-1", "ab1-")
  assert !plugin_term.consists_of("", "ab1-")
  assert !plugin_term.consists_of("aB", "ab1-")
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

/// 要素 0 が atom の `error` のタプルを組み立てる。
fn error_tuple(elements: List(Dynamic)) -> Dynamic {
  tuple([atom.to_dynamic(atom.create("error")), ..elements])
}
