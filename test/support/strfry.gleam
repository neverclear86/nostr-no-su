//// 実際のリレー（strfry）を使う統合テストの補助。

import envoy
import gleam/io

/// `TEST_RELAY_URL` が空でなければその値で `run` を呼ぶ。未設定または空のときは
/// 失敗せず、スキップを 1 行ログに出す（CI の `test` ジョブは strfry を立てて渡す）。
/// `label` はログの行頭に付ける識別子。
pub fn with_test_relay_url(label: String, run: fn(String) -> Nil) -> Nil {
  case envoy.get("TEST_RELAY_URL") {
    Ok(url) if url != "" -> run(url)
    _ ->
      io.println(
        "["
        <> label
        <> "] TEST_RELAY_URL is not set; skipping the integration test",
      )
  }
}
