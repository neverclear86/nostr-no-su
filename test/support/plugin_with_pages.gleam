//// `plugin_pages/1` と `plugin_page_content/2` を持つ fixture。
//// `support/plugin_with_config` と同じくアリティ +1 の設定を受け取る形で、本体が
//// `/1` `/2` を優先して呼ぶことを確かめるのに使う。
////
//// gleeunit は `test/` 配下の全ファイルを eunit に渡すため、関数名を `_test` で
//// 終わらせてはならない。

import gleam/dynamic.{type Dynamic}

/// 供給する唯一のページのキー。
pub const page_key = "status"

/// 供給する唯一のページの表示名。
pub const page_title = "Status"

/// 対応するプラグイン API のバージョン。
pub fn plugin_api_version() -> Int {
  1
}

/// ダッシュボードとログに出る表示名。
pub fn plugin_name() -> String {
  "plugin_with_pages"
}

/// イベント処理は使わない。
pub fn handle_event(_event: Dynamic) -> Nil {
  Nil
}

/// 供給するページの一覧。設定 map は使わないが、アリティ +1 の規則（第 6 章）
/// を満たすために受け取る。
pub fn plugin_pages(_config: Dynamic) -> List(Dynamic) {
  [
    dynamic.properties([
      #(dynamic.string("key"), dynamic.string(page_key)),
      #(dynamic.string("title"), dynamic.string(page_title)),
    ]),
  ]
}

/// `page_key` の記述。節 1 つと、その中に `pairs` ブロック 1 つを持つ。
pub fn plugin_page_content(_key: String, _config: Dynamic) -> Dynamic {
  dynamic.properties([
    #(
      dynamic.string("sections"),
      dynamic.list([
        dynamic.properties([
          #(dynamic.string("type"), dynamic.string("section")),
          #(dynamic.string("title"), dynamic.string(page_title)),
          #(
            dynamic.string("blocks"),
            dynamic.list([
              dynamic.properties([
                #(dynamic.string("type"), dynamic.string("pairs")),
                #(
                  dynamic.string("items"),
                  dynamic.list([
                    dynamic.properties([
                      #(dynamic.string("term"), dynamic.string("state")),
                      #(
                        dynamic.string("value"),
                        dynamic.properties([
                          #(dynamic.string("type"), dynamic.string("text")),
                          #(dynamic.string("text"), dynamic.string("ok")),
                        ]),
                      ),
                    ]),
                  ]),
                ),
              ]),
            ]),
          ),
        ]),
      ]),
    ),
  ])
}
