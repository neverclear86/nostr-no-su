//// 管理 UI に出る製品名の表記の検査。

import gleam/list
import gleam/string
import support/admin_ui

/// どのページにも `Nostr-no-Su` の表記だけが出て、小文字の `nostr-no-su` は出ない。
pub fn pages_spell_the_product_name_test() {
  use page <- list.each(admin_ui.all_pages())
  assert string.contains(page, "Nostr-no-Su")
  assert !string.contains(page, "nostr-no-su")
}
