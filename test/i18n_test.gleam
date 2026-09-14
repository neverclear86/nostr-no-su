//// 管理 UI の表示の言語の選び方と文言（`admin/i18n`）の単体テスト。

import gleam/list
import gleam/option.{None, Some}
import nostr_no_su/admin/i18n
import nostr_no_su/bunker/vault
import nostr_no_su/nostr/nip19

/// `Accept-Language` から、対応する言語のうち最も優先される言語を選ぶ。優先度が同じなら
/// 先に書かれた言語を選ぶ。
pub fn accept_language_picks_the_preferred_supported_language_test() {
  let cases = [
    // Playwright 1.63.0 の Chromium に locale を渡したときに送られた値。
    #("ja-JP", i18n.Japanese),
    #("en-US", i18n.English),
    #("ja,en-US;q=0.9,en;q=0.8", i18n.Japanese),
    #("en-US,en;q=0.9,ja;q=0.8", i18n.English),
    #("fr-CH, fr;q=0.9, en;q=0.8, de;q=0.7, *;q=0.5", i18n.English),
    #("de, ja;q=0.5, en;q=0.4", i18n.Japanese),
    #("en;q=0.5, ja;q=0.5", i18n.English),
    #("ja;q=0.5, en;q=0.5", i18n.Japanese),
    #("JA-jp", i18n.Japanese),
    #("ja;Q=1.000", i18n.Japanese),
    #("zh-Hant-TW, ja;q=0.001", i18n.Japanese),
    #("ja; q=0.9", i18n.Japanese),
    // 形式に合わない項目は、その項目だけを無視する。
    #("ja;q=2, en;q=0.1", i18n.English),
  ]
  use #(header, language) <- list.each(cases)
  assert #(header, i18n.from_accept_language(header)) == #(header, Ok(language))
}

/// 対応しない言語、`*`、優先度 0、形式に合わない項目からは選ばない。
pub fn accept_language_ignores_unusable_ranges_test() {
  let headers = [
    "", "*", "fr, de", "ja;q=0", "ja;q=0.000", "ja;q=1.001", "ja;q=2", "ja;q=-1",
    "ja;q=abc", "ja;q=0.1234", "ja;q=.5", "ja;x=1", ",,;", "ja;q=0, *",
  ]
  use header <- list.each(headers)
  assert #(header, i18n.from_accept_language(header)) == #(header, Error(Nil))
}

/// 対応する言語は言語コードから引き直せ、切り替えには言語コードの順に並ぶ。
pub fn language_codes_round_trip_test() {
  list.each(i18n.languages, fn(language) {
    assert i18n.from_code(i18n.code(language)) == Ok(language)
  })
  assert i18n.from_code("fr") == Error(Nil)
  assert list.map(i18n.languages, i18n.code) == ["en", "ja"]
  assert list.map(i18n.languages, i18n.native_name) == ["English", "日本語"]
}

/// 対応する言語の一覧には、`i18n.Language` のすべての構築子が 1 回ずつ並ぶ。構築子を足して
/// 一覧に足し忘れると落ちる。
pub fn languages_include_every_language_test() {
  assert list.unique(i18n.languages) == i18n.languages
  assert list.length(i18n.languages) == language_count(i18n.default_language)
}

/// `i18n.Language` の構築子の数。構築子を網羅する `case` なので、言語を足すとテストのビルドが
/// 止まり、この数を直すことになる。
fn language_count(language: i18n.Language) -> Int {
  case language {
    i18n.English | i18n.Japanese -> 2
  }
}

/// 値を埋め込む文言は、言語ごとの語順と記号で文全体を返す。
pub fn messages_with_values_follow_each_language_test() {
  let cases = [
    #(i18n.ExpiresInSeconds(12), "12s", "12 秒"),
    #(
      i18n.NoPendingConnections(10),
      "No pending connections. Pending connections expire after 10 minutes.",
      "承認待ちの接続はありません。承認待ちは 10 分で失効します。",
    ),
    #(i18n.AutoRefreshingEverySeconds(30), "Refreshing every 30s", "30 秒ごとに更新中"),
    #(
      i18n.ApprovalRequestGone(10),
      "This connection request was not found. It may have expired (requests expire after 10 minutes) or already been approved or denied. Connect again from the client.",
      "この接続要求は見つかりません。10 分で失効するため時間切れになったか、すでに承認か拒否がされた可能性があります。クライアントから接続し直してください。",
    ),
    #(
      i18n.LabelTooLong(max: 100),
      "label must be at most 100 characters",
      "ラベルは 100 文字以内にしてください。",
    ),
    #(
      i18n.LabelHint(max: 100),
      "Up to 100 characters. A combined emoji can count as several characters.",
      "100 文字まで。組み合わせた絵文字は 1 つで数文字分になることがあります。",
    ),
    #(i18n.Dropped(3), "(dropped 3)", "（破棄 3 件）"),
    #(
      i18n.InvalidNsec(nip19.PrefixMismatch(nip19.Nsec)),
      "expected nsec prefix",
      "接頭辞が nsec ではありません。",
    ),
    #(
      i18n.UnreadableReason(vault.PublicKeyMismatch),
      "The decrypted private key does not match the pubkey.",
      "復号した秘密鍵が pubkey と一致しません。",
    ),
  ]
  use #(message, english, japanese) <- list.each(cases)
  assert i18n.text(i18n.English, message) == english
  assert i18n.text(i18n.Japanese, message) == japanese
}

/// 英語のまま届いた理由の前置きは、英語以外のページにだけ置く。
pub fn leads_are_only_for_other_languages_test() {
  assert i18n.lead(i18n.English, i18n.CouldNotRegister) == None
  assert i18n.lead(i18n.Japanese, i18n.CouldNotRegister) == Some("登録できませんでした。")
  assert i18n.lead(i18n.Japanese, i18n.CouldNotListRelays)
    == Some("リレーの一覧を表示できません。")
  assert i18n.lead(i18n.Japanese, i18n.CouldNotAddRelay)
    == Some("リレーを登録できませんでした。")
  assert i18n.lead(i18n.Japanese, i18n.CouldNotSaveRelay)
    == Some("用途を保存できませんでした。")
  assert i18n.lead(i18n.Japanese, i18n.CouldNotDeleteRelay)
    == Some("リレーを削除できませんでした。")
}
