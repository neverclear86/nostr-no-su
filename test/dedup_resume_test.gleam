//// `dedup/resume` のテスト。プロセスにも IO にも触れない純粋な値なので、DB も
//// アクターも要らない。

import gleam/dict
import gleam/option.{None, Some}
import nostr_no_su/dedup/resume

/// 記録の無いリレーの再開点は `None`。
pub fn since_is_absent_at_first_test() {
  assert resume.since(resume.new(), "wss://a") == None
}

/// リレーごとに、そのリレーで受け取った最新の `created_at` を持つ。
pub fn since_is_the_latest_created_at_per_relay_test() {
  let recorded =
    resume.new()
    |> resume.observe("wss://a", 100, 1000)
    |> resume.observe("wss://a", 90, 1000)
    |> resume.observe("wss://b", 50, 1000)
  assert resume.since(recorded, "wss://a") == Some(100)
  assert resume.since(recorded, "wss://b") == Some(50)
  assert resume.since(recorded, "wss://c") == None
}

/// 受け取った時刻より未来の `created_at` は、受け取った時刻に切り詰める。
pub fn a_future_created_at_is_clamped_to_the_receive_time_test() {
  let recorded = resume.observe(resume.new(), "wss://a", 5000, 1000)
  assert resume.since(recorded, "wss://a") == Some(1000)
}

/// アカウントの追加は、渡した全リレーの再開点を追加の時刻以上に引き上げる。
/// すでにそれ以上の再開点があるリレーは変えない。
pub fn an_account_addition_raises_every_listed_relay_test() {
  let recorded =
    resume.new()
    |> resume.observe("wss://a", 100, 100)
    |> resume.adding_account(["wss://a", "wss://b"], 150)
  assert resume.since(recorded, "wss://a") == Some(150)
  assert resume.since(recorded, "wss://b") == Some(150)
  assert resume.since(recorded, "wss://c") == None

  let raised_further =
    resume.observe(recorded, "wss://a", 200, 200)
    |> resume.adding_account(["wss://a", "wss://b"], 120)
  assert resume.since(raised_further, "wss://a") == Some(200)
  assert resume.since(raised_further, "wss://b") == Some(150)
}

/// 保存されていない、あるいは値が変わったリレーの再開点だけを、URL の順に返す。
pub fn unsaved_lists_changed_relays_in_url_order_test() {
  let saved = dict.from_list([#("a", 1), #("b", 2)])
  let current = dict.from_list([#("b", 3), #("a", 1), #("c", 4)])
  assert resume.unsaved(saved, current) == [#("b", 3), #("c", 4)]
}
