import gleam/json
import gleam/option.{Some}
import nostr_no_su/nostr/filter.{Filter}

/// フィールドを何も設定しないフィルターは空の JSON オブジェクトになる。
pub fn empty_filter_encodes_to_empty_object_test() {
  assert filter.new() |> filter.to_json |> json.to_string == "{}"
}

/// エンコード結果には、設定済みのフィールドだけが現れる。
pub fn unset_fields_are_omitted_test() {
  let query = Filter(..filter.new(), kinds: Some([1, 7]), since: Some(123))
  assert filter.to_json(query) |> json.to_string
    == "{\"kinds\":[1,7],\"since\":123}"
}

/// `p_tags` は NIP-01 の `#p` キーとしてエンコードされる。
pub fn p_tags_encode_test() {
  let query =
    Filter(..filter.new(), kinds: Some([24_133]), p_tags: Some(["abc", "def"]))
  assert filter.to_json(query) |> json.to_string
    == "{\"kinds\":[24133],\"#p\":[\"abc\",\"def\"]}"
}
