//// `plugin_pages/2` と `plugin_page_content/3` を持つ fixture。
//// `support/plugin_with_pages` と同じ形で、本体が表示の言語のコードを最後の引数に
//// 渡すことを確かめるのに使う。
////
//// gleeunit は `test/` 配下の全ファイルを eunit に渡すため、関数名を `_test` で
//// 終わらせてはならない。

import gleam/dynamic.{type Dynamic}

/// 供給する唯一のページのキー。
pub const page_key = "status"

/// 言語のコードごとの表示名。一覧と記述の見出しの両方に使う。
pub fn title_for(language: String) -> String {
  case language {
    "ja" -> "状態"
    _ -> "Status"
  }
}

/// 対応するプラグイン API のバージョン。
pub fn plugin_api_version() -> Int {
  1
}

/// ダッシュボードとログに出る表示名。
pub fn plugin_name() -> String {
  "plugin_with_localized_pages"
}

/// イベント処理は使わない。
pub fn handle_event(_event: Dynamic) -> Nil {
  Nil
}

/// 供給するページの一覧。表示名は `language` のもの。
pub fn plugin_pages(_config: Dynamic, language: String) -> List(Dynamic) {
  [
    dynamic.properties([
      #(dynamic.string("key"), dynamic.string(page_key)),
      #(dynamic.string("title"), dynamic.string(title_for(language))),
    ]),
  ]
}

/// `page_key` の記述。見出しが `language` の表示名の節 1 つで、ブロックは無い。
pub fn plugin_page_content(
  _key: String,
  _config: Dynamic,
  language: String,
) -> Dynamic {
  dynamic.properties([
    #(
      dynamic.string("sections"),
      dynamic.list([
        dynamic.properties([
          #(dynamic.string("type"), dynamic.string("section")),
          #(dynamic.string("title"), dynamic.string(title_for(language))),
          #(dynamic.string("blocks"), dynamic.list([])),
        ]),
      ]),
    ),
  ])
}
