//// 管理 UI のスクリプト（`priv/static/admin.js`）と、ページの中のスクリプトの検査。

import gleam/list
import gleam/string
import nostr_no_su/admin/view
import support/admin_ui

/// ページ枠がスクリプトを読む要素。ページに現れてよい `script` 要素はこれだけである。
const script_element = "<script src=\"/static/admin.js\" type=\"module\"></script>"

/// どのページもスクリプトをファイルから読み、インラインのスクリプトとイベント属性（`on*`）を
/// 持たない。CSP（`script-src 'self'`）はそれらを実行させないので、書き足すと処理が黙って
/// 動かなくなる。テキストと属性値はエスケープされて `<` と `"` を含まないので、`<script` は
/// 要素の開始タグで、`="` を含む語は属性の始まりである。
pub fn pages_have_no_inline_scripts_test() {
  use page <- list.each(admin_ui.all_pages())
  assert string.contains(page, script_element)
  assert !string.contains(string.replace(page, script_element, ""), "<script")
  assert list.filter(string.split(page, " "), is_event_attribute) == []
}

/// 描画しうる `data-action` の名前は、どれもスクリプトの `actions` に関数がある。名前を綴り
/// 違えるか関数を足し忘れると、ボタンを押しても何も起きず、ほかの検査では見つからない。
pub fn script_handles_every_rendered_action_test() {
  let script = admin_ui.static_file(view.script_segments)
  let rendered =
    admin_ui.all_pages()
    |> list.flat_map(actions)
    |> list.unique
  assert rendered != []
  let missing =
    list.filter(rendered, fn(action) {
      !string.contains(script, "\n  " <> action <> "(")
    })
  assert missing == []
}

/// 空白で区切った語が、イベント属性（`on` で始まる名前の属性）の始まりか。
fn is_event_attribute(word: String) -> Bool {
  string.starts_with(word, "on") && string.contains(word, "=\"")
}

/// ページの `data-action` 属性に現れる処理の名前。値はエスケープされて `"` を含まないので、
/// 次の `"` までが属性値である。
fn actions(page: String) -> List(String) {
  page
  |> string.split(" data-action=\"")
  |> list.drop(1)
  |> list.map(fn(rest) {
    let assert Ok(#(action, _)) = string.split_once(rest, "\"")
    action
  })
}
