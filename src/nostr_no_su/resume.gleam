//// 監視の購読を再開する時刻（再開点）の記録。プロセスにも IO にも触れない純粋な
//// 値で、`dedup` が保持する。リレーごとに、受け取ったイベントの最新の `created_at`
//// と、アカウントを追加した時刻の大きいほうを持つ。

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// リレー URL ごとの再開点。
pub opaque type Resume {
  Resume(points: Dict(String, Int))
}

/// 再開点の無い記録。
pub fn new() -> Resume {
  Resume(points: dict.new())
}

/// そのリレーの再開点を `at` 以上に引き上げる。`observe` と `adding_account` が
/// 共用する。
fn raise(
  points: Dict(String, Int),
  relay_url: String,
  at: Int,
) -> Dict(String, Int) {
  dict.upsert(points, relay_url, fn(current) {
    case current {
      Some(existing) -> int.max(existing, at)
      None -> at
    }
  })
}

/// リレー `relay_url` から `created_at` のイベントを時刻 `now` に受け取ったことを
/// 記録する。`now` より未来の `created_at` は `now` に切り詰める。
pub fn observe(
  resume: Resume,
  relay_url: String,
  created_at: Int,
  now: Int,
) -> Resume {
  Resume(points: raise(resume.points, relay_url, int.min(created_at, now)))
}

/// 時刻 `at` にアカウントを追加することを、`relay_urls` の全リレーの再開点の
/// 引き上げとして記録する。まだイベントを受け取っていないリレーにも再開点ができる。
pub fn adding_account(
  resume: Resume,
  relay_urls: List(String),
  at: Int,
) -> Resume {
  Resume(
    points: list.fold(relay_urls, resume.points, fn(points, relay_url) {
      raise(points, relay_url, at)
    }),
  )
}

/// そのリレーの再開点。無ければ `None`。
pub fn since(resume: Resume, relay_url: String) -> Option(Int) {
  dict.get(resume.points, relay_url) |> option.from_result
}

/// 保存のための写し。
pub fn points(resume: Resume) -> Dict(String, Int) {
  resume.points
}

/// `current` のうち、`saved` と値が違うリレーの再開点。表示とテストが安定するよう
/// URL の順に並べる。
pub fn unsaved(
  saved: Dict(String, Int),
  current: Dict(String, Int),
) -> List(#(String, Int)) {
  current
  |> dict.to_list
  |> list.filter(fn(entry) { dict.get(saved, entry.0) != Ok(entry.1) })
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
}
