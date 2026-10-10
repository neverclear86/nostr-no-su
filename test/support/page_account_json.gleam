//// `plugin_config.page_map` が予約キー `Accounts` に入れるアカウントの JSON を読み戻す。

import gleam/dynamic/decode
import gleam/json

/// `Accounts` の値（アカウントの一覧を JSON にした文字列）を、アカウントごとの
/// `#(pubkey, npub, label)` の一覧に読む。
pub fn parse(
  accounts_json: String,
) -> Result(List(#(String, String, String)), json.DecodeError) {
  json.parse(accounts_json, decode.list(account()))
}

/// アカウント 1 件のオブジェクトを読む decoder。
fn account() -> decode.Decoder(#(String, String, String)) {
  use pubkey <- decode.field("pubkey", decode.string)
  use npub <- decode.field("npub", decode.string)
  use label <- decode.field("label", decode.string)
  decode.success(#(pubkey, npub, label))
}
