//// 日本語で描画した管理 UI のページに、訳し忘れの英文が残っていないことの検査。

import gleam/list
import gleam/string
import nostr_no_su/admin/i18n
import support/admin_ui

/// 日本語で描画したページの英字の連なりが、どれも `allowed_words` にある。
pub fn japanese_pages_have_no_english_words_test() {
  let unexpected =
    admin_ui.pages(i18n.Japanese)
    |> list.flat_map(words)
    |> list.unique
    |> list.filter(fn(word) { !list.contains(allowed_words, word) })
  assert unexpected == []
}

/// 日本語のページでも英字のまま出す語。大文字小文字は区別する。`-` と `_` は連なりを
/// 区切るので、`nostr-no-su` や `sign_event` はそれぞれの語に分けて持つ。内訳は、ブランド
/// （nostr、no、su）、Nostr と NIP-46 の用語（nsec、npub、pubkey、relay、kind、secret、
/// ws、wss、URI、URL、NIP）、環境変数と文書の名前（ACCOUNT、MASTER、KEY、README）、HTTP
/// の語（Origin、Host）、操作の案内（Ctrl、C、macOS）、日付の区切り（T、Z）、NIP-46 の
/// 権限の名前（sign、event）、日本語文中に引用する英語のメッセージ（account is already
/// registered）、言語の自名（English）、固定値（example、label、plugin、a〜d）。
const allowed_words = [
  "nostr", "no", "su", "nsec", "npub", "pubkey", "relay", "kind", "secret", "ws",
  "wss", "URI", "URL", "NIP", "ACCOUNT", "MASTER", "KEY", "README", "Origin",
  "Host", "Ctrl", "C", "macOS", "T", "Z", "sign", "event", "account", "is",
  "already", "registered", "English", "example", "label", "plugin", "a", "b",
  "c", "d",
]

/// ページのテキストノードに現れる英字の連なり。テキストと属性値はエスケープされて `<` と
/// `>` を含まないので、`<` から次の `>` までが開始タグ、その先が次の `<` までのテキストで
/// ある。訳さない英語は `view.untranslated` が `lang="en"` の開始タグで包む決まりなので、
/// そのテキストは対象から外す。
fn words(page: String) -> List(String) {
  page
  |> string.split("<")
  |> list.drop(1)
  |> list.flat_map(fn(chunk) {
    let assert Ok(#(tag, text)) = string.split_once(chunk, ">")
    case string.contains(tag, "lang=\"en\"") {
      True -> []
      False -> latin_runs(text)
    }
  })
}

/// 英大小文字。
const letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

/// 文字列に含まれる英字の連なり。
fn latin_runs(text: String) -> List(String) {
  let #(runs, last) =
    text
    |> string.to_graphemes
    |> list.fold(#([], ""), fn(state, char) {
      let #(runs, current) = state
      case string.contains(letters, char), current {
        True, _ -> #(runs, current <> char)
        False, "" -> #(runs, "")
        False, _ -> #([current, ..runs], "")
      }
    })
  case last {
    "" -> runs
    _ -> [last, ..runs]
  }
}
