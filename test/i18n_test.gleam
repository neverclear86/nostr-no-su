//// 管理 UI の表示の言語の選び方と文言（`admin/i18n`）の単体テスト。

import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
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

/// `i18n.Message` の宣言順で次の構築子を返す。最後の構築子では `None`。構築子を網羅する
/// `case` なので、構築子を足すとテストのビルドが止まる。
fn next_message(message: i18n.Message) -> Option(i18n.Message) {
  case message {
    i18n.BackToDashboard -> Some(i18n.LanguageSwitchLabel)
    i18n.LanguageSwitchLabel -> Some(i18n.ThemeSwitchLabel)
    i18n.ThemeSwitchLabel -> Some(i18n.FollowBrowser)
    i18n.FollowBrowser -> Some(i18n.ThemeLight)
    i18n.ThemeLight -> Some(i18n.ThemeDark)
    i18n.ThemeDark -> Some(i18n.Copy)
    i18n.Copy -> Some(i18n.Copied)
    i18n.Copied -> Some(i18n.SelectedPressCtrlC)
    i18n.SelectedPressCtrlC -> Some(i18n.Dashboard)
    i18n.Dashboard -> Some(i18n.PendingConnections)
    i18n.PendingConnections -> Some(i18n.NoPendingConnections(10))
    i18n.NoPendingConnections(_) -> Some(i18n.AutoRefreshingEverySeconds(30))
    i18n.AutoRefreshingEverySeconds(_) -> Some(i18n.Signer)
    i18n.Signer -> Some(i18n.Client)
    i18n.Client -> Some(i18n.ExpiresIn)
    i18n.ExpiresIn -> Some(i18n.ExpiresInSeconds(12))
    i18n.ExpiresInSeconds(_) -> Some(i18n.SecretLabel)
    i18n.SecretLabel -> Some(i18n.SecretNotOffered)
    i18n.SecretNotOffered -> Some(i18n.SecretMismatch)
    i18n.SecretMismatch -> Some(i18n.Permissions)
    i18n.Permissions -> Some(i18n.NoPermissionsRequested)
    i18n.NoPermissionsRequested -> Some(i18n.Created)
    i18n.Created -> Some(i18n.LastUsed)
    i18n.LastUsed -> Some(i18n.Approve)
    i18n.Approve -> Some(i18n.Deny)
    i18n.Deny -> Some(i18n.Accounts)
    i18n.Accounts -> Some(i18n.AddAccount)
    i18n.AddAccount -> Some(i18n.NoAccounts)
    i18n.NoAccounts -> Some(i18n.UnreadableAccounts)
    i18n.UnreadableAccounts -> Some(i18n.UnreadableAccountsWarning)
    i18n.UnreadableAccountsWarning ->
      Some(i18n.UnreadableReason(vault.PublicKeyMismatch))
    i18n.UnreadableReason(_) -> Some(i18n.ConnectionUri)
    i18n.ConnectionUri -> Some(i18n.ConnectionUriForApproval)
    i18n.ConnectionUriForApproval -> Some(i18n.EditLabel)
    i18n.EditLabel -> Some(i18n.ShowPrivateKey)
    i18n.ShowPrivateKey -> Some(i18n.RotateSecret)
    i18n.RotateSecret -> Some(i18n.DeleteAccount)
    i18n.DeleteAccount -> Some(i18n.ApprovedSessions)
    i18n.ApprovedSessions -> Some(i18n.NoApprovedSessions)
    i18n.NoApprovedSessions -> Some(i18n.Revoke)
    i18n.Revoke -> Some(i18n.Relays)
    i18n.Relays -> Some(i18n.Role)
    i18n.Role -> Some(i18n.StateColumn)
    i18n.StateColumn -> Some(i18n.MonitorRole)
    i18n.MonitorRole -> Some(i18n.BunkerRole)
    i18n.BunkerRole -> Some(i18n.RelayConnected)
    i18n.RelayConnected -> Some(i18n.RelayDisconnected)
    i18n.RelayDisconnected -> Some(i18n.NoBunkerRelay)
    i18n.NoBunkerRelay -> Some(i18n.AddRelay)
    i18n.AddRelay -> Some(i18n.RelayUrl)
    i18n.RelayUrl -> Some(i18n.RelayUrlHint)
    i18n.RelayUrlHint -> Some(i18n.UseForMonitoring)
    i18n.UseForMonitoring -> Some(i18n.UseForBunker)
    i18n.UseForBunker -> Some(i18n.AddRelayDescription)
    i18n.AddRelayDescription -> Some(i18n.InvalidRelayUrl)
    i18n.InvalidRelayUrl -> Some(i18n.RelayAlreadyRegistered)
    i18n.RelayAlreadyRegistered -> Some(i18n.RelayRoleRequired)
    i18n.RelayRoleRequired -> Some(i18n.RelayConnectionsNotConfirmed)
    i18n.RelayConnectionsNotConfirmed -> Some(i18n.EditRelayRoles)
    i18n.EditRelayRoles -> Some(i18n.DeleteRelay)
    i18n.DeleteRelay -> Some(i18n.DeleteRelaySubmit)
    i18n.DeleteRelaySubmit -> Some(i18n.EditRelayRolesDescription)
    i18n.EditRelayRolesDescription -> Some(i18n.DeleteRelayDescription)
    i18n.DeleteRelayDescription -> Some(i18n.RelaysNotAvailable)
    i18n.RelaysNotAvailable -> Some(i18n.RelayNotFound)
    i18n.RelayNotFound -> Some(i18n.Plugins)
    i18n.Plugins -> Some(i18n.NameColumn)
    i18n.NameColumn -> Some(i18n.PluginRunning)
    i18n.PluginRunning -> Some(i18n.PluginOverloaded)
    i18n.PluginOverloaded -> Some(i18n.PluginDisabled)
    i18n.PluginDisabled -> Some(i18n.ReenablePlugin)
    i18n.ReenablePlugin -> Some(i18n.PluginUnavailable)
    i18n.PluginUnavailable -> Some(i18n.Dropped(3))
    i18n.Dropped(_) -> Some(i18n.NoPlugins)
    i18n.NoPlugins -> Some(i18n.ApproveConnection)
    i18n.ApproveConnection -> Some(i18n.WrongSecretOffered)
    i18n.WrongSecretOffered -> Some(i18n.WrongSecretNotice)
    i18n.WrongSecretNotice -> Some(i18n.Approved)
    i18n.Approved -> Some(i18n.Denied)
    i18n.Denied -> Some(i18n.ApprovedCloseWindow)
    i18n.ApprovedCloseWindow -> Some(i18n.DeniedCloseWindow)
    i18n.DeniedCloseWindow -> Some(i18n.NotFound)
    i18n.NotFound -> Some(i18n.ChangeNotConfirmed)
    i18n.ChangeNotConfirmed -> Some(i18n.ChangeNotApplied)
    i18n.ChangeNotApplied -> Some(i18n.BunkerNotAvailable)
    i18n.BunkerNotAvailable -> Some(i18n.CheckDashboardBeforeRetrying)
    i18n.CheckDashboardBeforeRetrying -> Some(i18n.AccountsNotAvailable)
    i18n.AccountsNotAvailable -> Some(i18n.MethodNotAllowed)
    i18n.MethodNotAllowed -> Some(i18n.BadRequest)
    i18n.BadRequest -> Some(i18n.PageNotFound)
    i18n.PageNotFound -> Some(i18n.ApprovalRequestGone(10))
    i18n.ApprovalRequestGone(_) -> Some(i18n.AccountNotFound)
    i18n.AccountNotFound -> Some(i18n.MethodNotAllowedDetail)
    i18n.MethodNotAllowedDetail -> Some(i18n.FormNotReadable)
    i18n.FormNotReadable -> Some(i18n.OriginMismatch)
    i18n.OriginMismatch -> Some(i18n.BunkerDidNotRespond)
    i18n.BunkerDidNotRespond -> Some(i18n.StoreDidNotConfirm)
    i18n.StoreDidNotConfirm -> Some(i18n.ImportPrivateKey)
    i18n.ImportPrivateKey -> Some(i18n.ImportDescription)
    i18n.ImportDescription -> Some(i18n.PrivateKeyNsec)
    i18n.PrivateKeyNsec -> Some(i18n.Label)
    i18n.Label -> Some(i18n.LabelHint(max: 100))
    i18n.LabelHint(_) -> Some(i18n.Register)
    i18n.Register -> Some(i18n.GenerateNewKey)
    i18n.GenerateNewKey -> Some(i18n.GenerateDescription)
    i18n.GenerateDescription -> Some(i18n.Generate)
    i18n.Generate -> Some(i18n.SkippedRowNote)
    i18n.SkippedRowNote -> Some(i18n.GeneratedKey)
    i18n.GeneratedKey -> Some(i18n.BackUpNow)
    i18n.BackUpNow -> Some(i18n.GeneratedKeyNotice)
    i18n.GeneratedKeyNotice -> Some(i18n.RegisterThisKey)
    i18n.RegisterThisKey -> Some(i18n.RegistrationNotAccepted)
    i18n.RegistrationNotAccepted -> Some(i18n.RegistrationNotConfirmed)
    i18n.RegistrationNotConfirmed -> Some(i18n.AccountRegistered)
    i18n.AccountRegistered -> Some(i18n.Account)
    i18n.Account -> Some(i18n.BackUpIfNotAlready)
    i18n.BackUpIfNotAlready -> Some(i18n.RegisteredKeyNotice)
    i18n.RegisteredKeyNotice -> Some(i18n.Save)
    i18n.Save -> Some(i18n.RotateSecretSubmit)
    i18n.RotateSecretSubmit -> Some(i18n.DeleteAccountSubmit)
    i18n.DeleteAccountSubmit -> Some(i18n.ShowPrivateKeySubmit)
    i18n.ShowPrivateKeySubmit -> Some(i18n.RotateSecretDescription)
    i18n.RotateSecretDescription -> Some(i18n.DeleteDescription)
    i18n.DeleteDescription -> Some(i18n.DeleteWarning)
    i18n.DeleteWarning -> Some(i18n.DeleteAlsoRemoves)
    i18n.DeleteAlsoRemoves -> Some(i18n.ShowPrivateKeyDescription)
    i18n.ShowPrivateKeyDescription -> Some(i18n.AdminPassword)
    i18n.AdminPassword -> Some(i18n.PrivateKey)
    i18n.PrivateKey -> Some(i18n.CloseTabAfterCopying)
    i18n.CloseTabAfterCopying -> Some(i18n.ResendNotice)
    i18n.ResendNotice -> Some(i18n.IncorrectPassword)
    i18n.IncorrectPassword -> Some(i18n.LabelEmpty)
    i18n.LabelEmpty -> Some(i18n.LabelTooLong(max: 100))
    i18n.LabelTooLong(_) -> Some(i18n.LabelHasControlCharacters)
    i18n.LabelHasControlCharacters ->
      Some(i18n.InvalidNsec(nip19.PrefixMismatch(nip19.Nsec)))
    i18n.InvalidNsec(_) -> Some(i18n.PrivateKeyOutOfRange)
    i18n.PrivateKeyOutOfRange -> None
  }
}

/// `message` から `next_message` を辿って宣言順の一覧を作る。循環していたらそこで打ち切るので、
/// 個数の検査が落ちる。
fn messages_from(
  message: i18n.Message,
  acc: List(i18n.Message),
) -> List(i18n.Message) {
  use <- bool.guard(list.contains(acc, message), list.reverse(acc))
  case next_message(message) {
    Some(next) -> messages_from(next, [message, ..acc])
    None -> list.reverse([message, ..acc])
  }
}

/// `i18n.Message` のすべての構築子を宣言順に 1 つずつ並べた一覧。
fn all_messages() -> List(i18n.Message) {
  messages_from(i18n.BackToDashboard, [])
}

/// 一覧に構築子が重複なく 137 個並ぶ。構築子を足すと `next_message` のビルドが止まり、
/// 鎖に繋いだ後にこの数を直すことになる。
pub fn all_messages_include_every_message_test() {
  let messages = all_messages()
  assert list.unique(messages) == messages
  assert list.length(messages) == 137
}

/// すべての構築子で英語と日本語の文言が異なる。両言語で同じ文言でよい構築子は無い。
pub fn every_message_differs_between_languages_test() {
  use message <- list.each(all_messages())
  assert i18n.text(i18n.English, message) != i18n.text(i18n.Japanese, message)
}
