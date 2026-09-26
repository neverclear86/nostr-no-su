//// プラグインのエクスポートが返す Erlang の項を読む部品。理由の文字列の形
//// （`<label>: missing <key>`、`<label>: <key> must be <expected>, got <classify>` など）を
//// ここで揃える。

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// プラグインが返す map のキーの型。子仕様（OTP の `child_spec()`）は atom、ページの記述は
/// binary のキーを使う。
pub type KeyType {
  /// atom のキー（`#{id => ...}`）。
  AtomKey
  /// binary のキー（`#{<<"key">> => ...}`）。
  BinaryKey
}

/// 理由の文字列とログ行に出す `関数/アリティ` の表記。
pub fn export_label(function: String, arity: Int) -> String {
  function <> "/" <> int.to_string(arity)
}

/// 戻り値が `{error, Reason}` の形かどうか。**判別子は要素 0 が atom の `error`
/// であることだけ**で、要素数は見ない。要素数を条件に入れると
/// `{error, A, B}` の扱いを別途決めることになる。
pub fn is_error_tuple(value: Dynamic) -> Bool {
  case decode.run(value, decode.at([0], atom.decoder())) {
    Ok(tag) -> atom.to_string(tag) == "error"
    Error(_) -> False
  }
}

/// `{error, Reason}` の `Reason` を binary として読む。要素 1 が無ければ `Error(None)`、
/// binary でなければその型の名前（`dynamic.classify`）を `Error(Some(..))` で返す。
/// 形は `is_error_tuple` で確かめてから渡す。
pub fn error_reason(value: Dynamic) -> Result(String, Option(String)) {
  case decode.run(value, decode.at([1], decode.dynamic)) {
    Error(_) -> Error(None)
    Ok(reason) ->
      case decode.run(reason, decode.string) {
        Ok(text) -> Ok(text)
        Error(_) -> Error(Some(dynamic.classify(reason)))
      }
  }
}

/// `Reason` が binary でない `{error, Reason}` の理由の文字列
/// `<label>: error reason must be a String, got <got>`。
pub fn reason_not_a_string(label: String, got: String) -> String {
  label <> ": error reason must be a String, got " <> got
}

/// map であることを先に確かめる。map でない要素（素の `{Module, Function, Args}` や
/// `{key, title}` のタプル）を渡されたとき、キーが 1 つも読めないことを「必須のキーが
/// 無い」と報告すると作者が原因にたどり着けないので、形そのものの誤り
/// `<label>: must be <expected>, got <classify>` にする。`dynamic.classify` は map を
/// `Dict`、タプルを `Array` と呼ぶ。
pub fn check_map(
  raw: Dynamic,
  label: String,
  expected: String,
) -> Result(Nil, String) {
  case dynamic.classify(raw) {
    "Dict" -> Ok(Nil)
    other -> Error(label <> ": must be " <> expected <> ", got " <> other)
  }
}

/// map から `key_type` の型のキー `key` を取り出す。無ければ（map ですらなければ）
/// `None`。
pub fn lookup(raw: Dynamic, key_type: KeyType, key: String) -> Option(Dynamic) {
  case key_type {
    AtomKey -> lookup_term(raw, atom.create(key))
    BinaryKey -> lookup_term(raw, key)
  }
}

/// `key` の項をそのまま map のキーとして引く。`lookup` の実体。
fn lookup_term(raw: Dynamic, key: k) -> Option(Dynamic) {
  let decoder =
    decode.optional_field(
      key,
      None,
      decode.map(decode.dynamic, Some),
      decode.success,
    )
  decode.run(raw, decoder)
  |> result.unwrap(None)
}

/// 必須のキーを読む。欠けていれば `<label>: missing <key>`、`decoder` で読めなければ
/// `<label>: <key> must be <expected>, got <classify>`。atom キーの map に対する
/// `decode.run` のエラーのパスはプラグイン作者の役に立たないので、理由は自前で
/// 組み立てる。
pub fn required(
  raw: Dynamic,
  key_type: KeyType,
  key: String,
  label: String,
  expected: String,
  decoder: decode.Decoder(a),
) -> Result(a, String) {
  case lookup(raw, key_type, key) {
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

/// 0 起点の添字を付けて要素を 1 つずつ検証し、最初の誤りで止める。
pub fn try_map_indexed(
  items: List(a),
  f: fn(a, Int) -> Result(b, e),
) -> Result(List(b), e) {
  items
  |> list.index_map(fn(item, index) { #(item, index) })
  |> list.try_map(fn(pair) { f(pair.0, pair.1) })
}
