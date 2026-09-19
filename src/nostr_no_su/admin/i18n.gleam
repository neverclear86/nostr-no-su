//// 管理 UI の表示の言語と、言語ごとの文言。
////
//// 文言は `Message` の値で表し、`text` が表示の言語の文字列にする。言語ごとの関数
//// （`english`、`japanese`）は、どれも `Message` のすべての値を網羅する `case` なので、
//// どちらかの言語の訳が無いとビルドが通らない。値を埋め込む文言（残り秒、件数、ラベルの
//// 上限）は値を持つ構築子にし、語順と記号を含めて言語ごとに文全体を返す。
////
//// 言語を足すときは、`Language` に構築子を、`languages` に値を足し、コンパイラーが示す
//// `case`（`code`、`native_name`、`text`、`lead`、`sentence_gap`、`i18n_test` の
//// `language_count`）に枝を足す。
////
//// 管理 UI の外（バンカー、アカウントストア、設定、プラグイン）から英語の文字列で届く
//// 理由は訳さず、`Untranslated` として英語のまま出す。設定、DB、プラグインの理由はログにも
//// 同じ文が出るが、バンカーのアクターの案内（`accounts are being loaded` など）は出ない。
//// 例外として、変更を確認できなかったときの本文（アカウントの変更とリレーの変更の 202 と、
//// 承認・拒否・取り消しの 503）は、バンカーと管理 UI の Context が原因を型で返すので訳す。
//// 承認待ちの一覧に無いトークンの承認ページの 404 の本文も訳す。これは外から届いた文字列
//// ではなく、管理 UI が一覧との照合で自分で決めている判定だからである。プラグインの
//// 再有効化の 503 は英語のまま。読み込みで飛ばされた行の理由は `vault.RowError` の型で
//// 届くので訳す。
////
//// クラス名はここに書かない。`assets/admin.css` がこのモジュールを Tailwind の走査から
//// 外しているので、書いても CSS に出力されない。

import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import nostr_no_su/bunker/vault
import nostr_no_su/nostr/nip19

/// 管理 UI を表示する言語。
pub type Language {
  English
  Japanese
}

/// 対応する言語。言語の切り替えはこの順（言語コードの順）に並べる。言語を足したら
/// ここにも足す。足し忘れは `i18n_test` が、`Language` の構築子を網羅する `case` の
/// `language_count` の数とこの一覧の長さを比べて見つけるので、`language_count` に枝を
/// 足すときは数も直す（直さないと足し忘れを見つけられない）。
pub const languages = [English, Japanese]

/// 利用者が選んでおらず、`Accept-Language` からも決まらないときの言語。
pub const default_language = English

/// 言語コード（BCP 47 の最初のサブタグ）。`<html lang>`、切り替えで送る値、cookie の値に
/// 使う。
pub fn code(language: Language) -> String {
  case language {
    English -> "en"
    Japanese -> "ja"
  }
}

/// その言語自身で書いた言語の名前。どの言語のページでも同じ文字で出す。
pub fn native_name(language: Language) -> String {
  case language {
    English -> "English"
    Japanese -> "日本語"
  }
}

/// 言語コードの言語。対応していない言語なら Error。
pub fn from_code(value: String) -> Result(Language, Nil) {
  list.find(languages, fn(language) { code(language) == value })
}

/// `Accept-Language` の値から、対応する言語のうち最も優先される言語を選ぶ。言語の範囲は
/// 最初のサブタグ（`ja-JP` の `ja`）で照合し、優先度が同じなら先に書かれたものを選ぶ。
/// `*`、`q=0`、形式に合わない項目は無視する。対応する言語が無ければ Error。
pub fn from_accept_language(header: String) -> Result(Language, Nil) {
  let weighted =
    header
    |> string.split(",")
    |> list.filter_map(weighted_language)
  case weighted {
    [] -> Error(Nil)
    [first, ..rest] -> {
      let #(_quality, language) =
        list.fold(rest, first, fn(best, next) {
          case next.0 > best.0 {
            True -> next
            False -> best
          }
        })
      Ok(language)
    }
  }
}

/// `Accept-Language` の項目 1 つを、優先度（1000 分の 1 単位）と言語の組にする。対応
/// しない言語、優先度 0、形式に合わない項目は Error。
fn weighted_language(item: String) -> Result(#(Int, Language), Nil) {
  let #(range, weight) = case string.split_once(item, ";") {
    Ok(#(range, weight)) -> #(range, Some(weight))
    Error(Nil) -> #(item, None)
  }
  use language <- result.try(range_language(range))
  use quality <- result.try(case weight {
    None -> Ok(1000)
    Some(weight) -> parse_weight(weight)
  })
  case quality > 0 {
    True -> Ok(#(quality, language))
    False -> Error(Nil)
  }
}

/// 言語の範囲（`ja-JP` など）の最初のサブタグの言語。大文字と小文字を区別しない。
fn range_language(range: String) -> Result(Language, Nil) {
  let tag = string.lowercase(string.trim(range))
  case string.split_once(tag, "-") {
    Ok(#(primary, _)) -> from_code(primary)
    Error(Nil) -> from_code(tag)
  }
}

/// `q=0.8` の形の重みを、1000 分の 1 単位の整数にする。RFC 9110 の qvalue（0 から 1、
/// 小数点以下 3 桁まで）に合わなければ Error。浮動小数点数にしないのは、`float.parse` が
/// `1` のような整数の表記を受け付けないためである。
fn parse_weight(weight: String) -> Result(Int, Nil) {
  use value <- result.try(case string.lowercase(string.trim(weight)) {
    "q=" <> value -> Ok(value)
    _ -> Error(Nil)
  })
  let #(whole, fraction) = case string.split_once(value, ".") {
    Ok(parts) -> parts
    Error(Nil) -> #(value, "")
  }
  use <- bool.guard(
    string.length(fraction) > 3 || !is_digits(fraction),
    Error(Nil),
  )
  use thousandths <- result.try(int.parse(string.pad_end(fraction, 3, "0")))
  case whole, thousandths {
    "0", _ -> Ok(thousandths)
    "1", 0 -> Ok(1000)
    _, _ -> Error(Nil)
  }
}

/// 文字列が 0 から 9 の数字だけでできているか（空文字列を含む）。
fn is_digits(text: String) -> Bool {
  string.to_graphemes(text)
  |> list.all(string.contains("0123456789", _))
}

/// 画面に出す失敗の理由。
pub type Reason {
  /// 管理 UI が言語ごとに訳す理由。
  Translated(Message)
  /// 管理 UI の外から英語の文字列で届く理由。訳さずに出す。
  Untranslated(String)
}

/// 英語のまま届いた理由の前に置く、何ができなかったかを伝える前置き。
pub type Lead {
  CouldNotRegister
  CouldNotSaveLabel
  CouldNotRotateSecret
  CouldNotDeleteAccount
  CouldNotListAccounts
  CouldNotListPending
  CouldNotListSessions
  CouldNotListRelays
  CouldNotAddRelay
  CouldNotSaveRelay
  CouldNotDeleteRelay
}

/// 英語のまま届いた理由の前置き。英語のページでは理由と同じ言語なので置かない。
pub fn lead(language: Language, lead: Lead) -> Option(String) {
  case language {
    English -> None
    Japanese ->
      Some(case lead {
        CouldNotRegister -> "登録できませんでした。"
        CouldNotSaveLabel -> "ラベルを保存できませんでした。"
        CouldNotRotateSecret -> "secret を再生成できませんでした。"
        CouldNotDeleteAccount -> "アカウントを削除できませんでした。"
        CouldNotListAccounts -> "アカウントの一覧を表示できません。"
        CouldNotListPending -> "承認待ちの一覧を表示できません。"
        CouldNotListSessions -> "セッションの一覧を表示できません。"
        CouldNotListRelays -> "リレーの一覧を表示できません。"
        CouldNotAddRelay -> "リレーを登録できませんでした。"
        CouldNotSaveRelay -> "用途を保存できませんでした。"
        CouldNotDeleteRelay -> "リレーを削除できませんでした。"
      })
  }
}

/// 文や句を続けて置くときの間の文字。英語は空白で区切り、日本語は区切らない。
pub fn sentence_gap(language: Language) -> String {
  case language {
    English -> " "
    Japanese -> ""
  }
}

/// 管理 UI の文言。
pub type Message {
  // ページの枠と共通の部品
  BackToDashboard
  LanguageSwitchLabel
  ThemeSwitchLabel
  FollowBrowser
  ThemeLight
  ThemeDark
  Copy
  Copied
  SelectedPressCtrlC
  // ダッシュボード
  Dashboard
  PendingConnections
  NoPendingConnections(minutes: Int)
  AutoRefreshingEverySeconds(seconds: Int)
  Signer
  Client
  ExpiresIn
  ExpiresInSeconds(seconds: Int)
  SecretLabel
  SecretNotOffered
  SecretMismatch
  Permissions
  NoPermissionsRequested
  Created
  LastUsed
  Approve
  Deny
  Accounts
  AddAccount
  NoAccounts
  UnreadableAccounts
  UnreadableAccountsWarning
  UnreadableReason(reason: vault.RowError)
  UnreadableNotDeletable
  ReasonLabel
  ConnectionUri
  ConnectionUriForApproval
  EditLabel
  ShowPrivateKey
  RotateSecret
  DeleteAccount
  ApprovedSessions
  NoApprovedSessions
  Revoke
  Relays
  Role
  StateColumn
  MonitorRole
  BunkerRole
  RelayConnected
  RelayDisconnected
  NoBunkerRelay
  AddRelay
  RelayUrl
  RelayUrlHint
  UseForMonitoring
  UseForBunker
  AddRelayDescription
  InvalidRelayUrl
  RelayAlreadyRegistered
  RelayRoleRequired
  RelayConnectionsNotConfirmed
  EditRelayRoles
  DeleteRelay
  DeleteRelaySubmit
  EditRelayRolesDescription
  DeleteRelayDescription
  RelaysNotAvailable
  RelayNotFound
  Plugins
  NameColumn
  PluginRunning
  PluginOverloaded
  PluginDisabled
  ReenablePlugin
  PluginUnavailable
  Dropped(count: Int)
  NoPlugins
  // 承認ページと通知ページ
  ApproveConnection
  WrongSecretOffered
  WrongSecretNotice
  Approved
  Denied
  ApprovedCloseWindow
  DeniedCloseWindow
  NotFound
  ChangeNotConfirmed
  ChangeNotApplied
  BunkerNotAvailable
  CheckDashboardBeforeRetrying
  AccountsNotAvailable
  MethodNotAllowed
  BadRequest
  PageNotFound
  ApprovalRequestGone(minutes: Int)
  AccountNotFound
  MethodNotAllowedDetail
  FormNotReadable
  OriginMismatch
  BunkerDidNotRespond
  StoreDidNotConfirm
  NotAvailable
  // アカウントの登録画面
  ImportPrivateKey
  ImportDescription
  PrivateKeyNsec
  Label
  LabelHint(max: Int)
  Register
  GenerateNewKey
  GenerateDescription
  Generate
  SkippedRowNote
  // 生成した鍵の確認ページ、登録の完了ページ
  GeneratedKey
  BackUpNow
  GeneratedKeyNotice
  RegisterThisKey
  RegistrationNotAccepted
  RegistrationNotConfirmed
  AccountRegistered
  Account
  BackUpIfNotAlready
  RegisteredKeyNotice
  // アカウントの操作のページ
  Save
  RotateSecretSubmit
  DeleteAccountSubmit
  ShowPrivateKeySubmit
  RotateSecretDescription
  DeleteDescription
  DeleteWarning
  DeleteAlsoRemoves
  DeleteUnreadableDescription
  DeleteUnreadableWarning
  DeleteUnreadableRecover
  ShowPrivateKeyDescription
  AdminPassword
  // 秘密鍵の表示ページ
  PrivateKey
  CloseTabAfterCopying
  ResendNotice
  // 管理 UI が検査して返す理由
  IncorrectPassword
  LabelEmpty
  LabelTooLong(max: Int)
  LabelHasControlCharacters
  InvalidNsec(nip19.Nip19Error)
  PrivateKeyOutOfRange
}

/// 文言を表示の言語の文字列にする。
pub fn text(language: Language, message: Message) -> String {
  case language {
    English -> english(message)
    Japanese -> japanese(message)
  }
}

/// 英語の文言。
fn english(message: Message) -> String {
  case message {
    BackToDashboard -> "Back to dashboard"
    LanguageSwitchLabel -> "Language"
    ThemeSwitchLabel -> "Theme"
    FollowBrowser -> "Browser setting"
    ThemeLight -> "Light"
    ThemeDark -> "Dark"
    Copy -> "Copy"
    Copied -> "Copied"
    SelectedPressCtrlC -> "Selected. Press Ctrl+C (⌘C on macOS) to copy."
    Dashboard -> "Dashboard"
    PendingConnections -> "Pending connections"
    NoPendingConnections(minutes:) ->
      "No pending connections. Pending connections expire after "
      <> int.to_string(minutes)
      <> " minutes."
    AutoRefreshingEverySeconds(seconds:) ->
      "Refreshing every " <> int.to_string(seconds) <> "s"
    Signer -> "Signer"
    Client -> "Client"
    ExpiresIn -> "Expires in"
    ExpiresInSeconds(seconds:) -> int.to_string(seconds) <> "s"
    SecretLabel -> "Secret"
    SecretNotOffered -> "Not offered"
    SecretMismatch -> "Mismatch"
    Permissions -> "Permissions"
    NoPermissionsRequested ->
      "None requested. Signing and encryption are refused."
    Created -> "Created"
    LastUsed -> "Last used"
    Approve -> "Approve"
    Deny -> "Deny"
    Accounts -> "Accounts"
    AddAccount -> "Add account"
    NoAccounts -> "No accounts registered."
    UnreadableAccounts -> "Unreadable accounts"
    UnreadableAccountsWarning ->
      "The current ACCOUNT_MASTER_KEY cannot decrypt these rows."
    UnreadableReason(reason) -> english_row_error(reason)
    UnreadableNotDeletable ->
      "This row cannot be deleted here because its pubkey cannot be read."
    ReasonLabel -> "Reason"
    ConnectionUri -> "Connection URI"
    ConnectionUriForApproval -> "Connection URI (approval)"
    EditLabel -> "Edit label"
    ShowPrivateKey -> "Show private key"
    RotateSecret -> "Rotate secret"
    DeleteAccount -> "Delete account"
    ApprovedSessions -> "Approved sessions"
    NoApprovedSessions -> "No approved sessions."
    Revoke -> "Revoke"
    Relays -> "Relays"
    Role -> "Role"
    StateColumn -> "State"
    MonitorRole -> "monitor"
    BunkerRole -> "bunker"
    RelayConnected -> "connected"
    RelayDisconnected -> "disconnected"
    NoBunkerRelay ->
      "No relay is used for the bunker. Clients cannot connect to any account until you add one."
    AddRelay -> "Add relay"
    RelayUrl -> "Relay URL"
    RelayUrlHint -> "Starts with ws:// or wss://."
    UseForMonitoring -> "Use for monitoring"
    UseForBunker -> "Use for the bunker"
    AddRelayDescription ->
      "Relays used for monitoring are subscribed to for events written by the registered accounts. Relays used for the bunker are listed as relay= in every connection URI. Use NIP-46-only relays, which refuse subscriptions other than kind 24133, for the bunker only."
    InvalidRelayUrl -> "relay url must be a valid ws:// or wss:// url"
    RelayAlreadyRegistered -> "relay is already registered"
    RelayRoleRequired -> "choose monitoring, the bunker, or both"
    RelayConnectionsNotConfirmed ->
      "the change was saved, but the relay connections did not confirm it"
    EditRelayRoles -> "Edit roles"
    DeleteRelay -> "Delete relay"
    DeleteRelaySubmit -> "Delete relay"
    EditRelayRolesDescription ->
      "If you stop using this relay for the bunker, it is removed from relay= in the connection URIs, and clients that connect only through it stop receiving responses. Paste the new connection URI from the dashboard into those clients."
    DeleteRelayDescription ->
      "The connections to this relay are closed and the relay is removed. If it was used for the bunker, clients that connect only through it stop receiving responses; paste the new connection URI from the dashboard into those clients."
    RelaysNotAvailable -> "Relays are not available"
    RelayNotFound ->
      "This relay is not registered. It may have been deleted already; check the dashboard."
    Plugins -> "Plugins"
    NameColumn -> "Name"
    PluginRunning -> "running"
    PluginOverloaded -> "overloaded"
    PluginDisabled -> "disabled"
    ReenablePlugin -> "Re-enable"
    PluginUnavailable -> "unavailable"
    Dropped(count:) -> "(dropped " <> int.to_string(count) <> ")"
    NoPlugins -> "No plugins enabled."
    ApproveConnection -> "Approve connection"
    WrongSecretOffered -> "The connection secret does not match."
    WrongSecretNotice ->
      "This happens when a client still uses the connection URI from before the secret was rotated, or when someone is guessing the secret. If you do not recognize this client, deny the request."
    Approved -> "Approved"
    Denied -> "Denied"
    ApprovedCloseWindow -> "Approved. You can close this window."
    DeniedCloseWindow -> "Denied. You can close this window."
    NotFound -> "Not found"
    ChangeNotConfirmed -> "Change not confirmed"
    ChangeNotApplied -> "Change not applied"
    BunkerNotAvailable -> "Bunker is not available"
    CheckDashboardBeforeRetrying ->
      "Before trying again, check on the dashboard whether the change was applied."
    AccountsNotAvailable -> "Accounts are not available"
    MethodNotAllowed -> "Method not allowed"
    BadRequest -> "Bad request"
    PageNotFound -> "There is no page at this URL."
    ApprovalRequestGone(minutes:) ->
      "This connection request was not found. It may have expired (requests expire after "
      <> int.to_string(minutes)
      <> " minutes) or already been approved or denied. Connect again from the client."
    AccountNotFound ->
      "This account is not registered. It may have been deleted already; check the dashboard."
    MethodNotAllowedDetail ->
      "This URL is for a button in the admin UI and cannot be opened directly. Use the dashboard instead."
    FormNotReadable ->
      "The form was incomplete. Go back to the dashboard and try again."
    OriginMismatch ->
      "The Origin of the request does not match the Host. If a reverse proxy is in front of the admin UI, pass the Host header through unchanged; see the README."
    BunkerDidNotRespond -> "the bunker did not respond"
    StoreDidNotConfirm ->
      "the store did not confirm the change; it may have been applied"
    NotAvailable -> "Not available right now."
    ImportPrivateKey -> "Import a private key"
    ImportDescription ->
      "Paste the private key (nsec) of the account. It is shown once after registration, and afterwards only when you re-enter the admin password. If the browser offers to save it as a password, decline."
    PrivateKeyNsec -> "Private key (nsec)"
    Label -> "Label"
    LabelHint(max:) ->
      "Up to "
      <> int.to_string(max)
      <> " characters. A combined emoji can count as several characters."
    Register -> "Register"
    GenerateNewKey -> "Generate a new key"
    GenerateDescription ->
      "Generate a new private key on the server. It is shown for backup before it is registered."
    Generate -> "Generate"
    SkippedRowNote ->
      "If registration reports \"account is already registered\" for an account that is not on the dashboard, a row encrypted with a different master key is left in the database; see the README for how to remove it."
    GeneratedKey -> "Generated key"
    BackUpNow -> "Back up this private key now."
    GeneratedKeyNotice ->
      "The account is not registered until you press \"Register this key\". After registration, the key is shown only when you re-enter the admin password."
    RegisterThisKey -> "Register this key"
    RegistrationNotAccepted ->
      "The key was not registered because accounts are not available right now. Wait a moment, then press \"Register this key\" again."
    RegistrationNotConfirmed ->
      "The registration was not confirmed. Back up this key, then press \"Register this key\" again: it is registered if it was not, or \"account is already registered\" is shown if it was."
    AccountRegistered -> "Account registered"
    Account -> "Account"
    BackUpIfNotAlready -> "Back up this private key if you have not already."
    RegisteredKeyNotice ->
      "It is shown again only when you re-enter the admin password. The connection URI is on the dashboard."
    Save -> "Save"
    RotateSecretSubmit -> "Rotate secret"
    DeleteAccountSubmit -> "Delete account"
    ShowPrivateKeySubmit -> "Show private key"
    RotateSecretDescription ->
      "A new connection secret is generated. Clients that connect with the old connection URI are no longer accepted without approval, but sessions that are already approved remain. Paste the new connection URI from the dashboard into your clients."
    DeleteDescription ->
      "The private key is deleted from the bunker and from the database."
    DeleteWarning ->
      "If you have not saved this key anywhere else, the account is lost."
    DeleteAlsoRemoves ->
      "Its sessions and pending connections are removed as well."
    DeleteUnreadableDescription ->
      "This removes the row from the bunker and the database."
    DeleteUnreadableWarning ->
      "If you have not saved the nsec, the account is lost."
    DeleteUnreadableRecover ->
      "Restart with the previous ACCOUNT_MASTER_KEY to show the private key and save it first."
    ShowPrivateKeyDescription ->
      "Re-enter the admin password to show the private key. Showing it is logged with the npub."
    AdminPassword -> "Admin password"
    PrivateKey -> "Private key"
    CloseTabAfterCopying -> "Close this tab after copying the key."
    ResendNotice ->
      "Reloading this page or coming back to it with the back button can resend the form, which shows the key again and logs it again."
    IncorrectPassword -> "incorrect password"
    LabelEmpty -> "label must not be empty"
    LabelTooLong(max:) ->
      "label must be at most " <> int.to_string(max) <> " characters"
    LabelHasControlCharacters -> "label must not contain control characters"
    // nip19 の説明は画面に出せる固定の英文なので、そのまま使う。
    InvalidNsec(error) -> nip19.describe(error)
    PrivateKeyOutOfRange -> "private key not in valid range"
  }
}

/// 日本語の文言。
fn japanese(message: Message) -> String {
  case message {
    BackToDashboard -> "ダッシュボードに戻る"
    LanguageSwitchLabel -> "言語"
    ThemeSwitchLabel -> "テーマ"
    FollowBrowser -> "ブラウザーの設定"
    ThemeLight -> "ライト"
    ThemeDark -> "ダーク"
    Copy -> "コピー"
    Copied -> "コピー済み"
    SelectedPressCtrlC -> "選択しました。Ctrl+C（macOS では ⌘C）でコピーしてください。"
    Dashboard -> "ダッシュボード"
    PendingConnections -> "承認待ちの接続"
    NoPendingConnections(minutes:) ->
      "承認待ちの接続はありません。承認待ちは " <> int.to_string(minutes) <> " 分で失効します。"
    AutoRefreshingEverySeconds(seconds:) -> int.to_string(seconds) <> " 秒ごとに更新中"
    Signer -> "署名者"
    Client -> "クライアント"
    ExpiresIn -> "失効まで"
    ExpiresInSeconds(seconds:) -> int.to_string(seconds) <> " 秒"
    SecretLabel -> "secret"
    SecretNotOffered -> "提示なし"
    SecretMismatch -> "不一致"
    Permissions -> "権限"
    NoPermissionsRequested -> "要求なし。署名と暗号化は拒否します。"
    Created -> "作成"
    LastUsed -> "最終利用"
    Approve -> "承認する"
    Deny -> "拒否する"
    Accounts -> "アカウント"
    AddAccount -> "アカウントを追加"
    NoAccounts -> "登録されたアカウントはありません。"
    UnreadableAccounts -> "読み込めなかったアカウント"
    UnreadableAccountsWarning -> "現在の ACCOUNT_MASTER_KEY では、これらの行の秘密鍵を復号できません。"
    UnreadableReason(reason) -> japanese_row_error(reason)
    UnreadableNotDeletable -> "この行は pubkey を読めないため、画面からは削除できません。"
    ReasonLabel -> "理由"
    ConnectionUri -> "接続 URI"
    ConnectionUriForApproval -> "接続 URI（要承認）"
    EditLabel -> "ラベルを編集"
    ShowPrivateKey -> "秘密鍵を表示"
    RotateSecret -> "secret を再生成"
    DeleteAccount -> "アカウントを削除"
    ApprovedSessions -> "承認済みのセッション"
    NoApprovedSessions -> "承認済みのセッションはありません。"
    Revoke -> "承認を取り消す"
    Relays -> "リレー"
    Role -> "用途"
    StateColumn -> "状態"
    MonitorRole -> "監視"
    BunkerRole -> "バンカー"
    RelayConnected -> "接続中"
    RelayDisconnected -> "未接続"
    NoBunkerRelay -> "バンカーに使うリレーがありません。リレーを追加するまで、クライアントはどのアカウントにも接続できません。"
    AddRelay -> "リレーを追加"
    RelayUrl -> "リレーの URL"
    RelayUrlHint -> "ws:// か wss:// で始まる URL。"
    UseForMonitoring -> "監視に使う"
    UseForBunker -> "バンカーに使う"
    AddRelayDescription ->
      "監視に使うリレーでは、登録したアカウントが書いたイベントを購読します。バンカーに使うリレーは、すべての接続 URI の relay= に入ります。kind 24133 以外の購読を拒否する NIP-46 専用のリレーは、バンカーにだけ使ってください。"
    InvalidRelayUrl -> "ws:// か wss:// で始まる正しい URL を入力してください。"
    RelayAlreadyRegistered -> "このリレーはすでに登録されています。"
    RelayRoleRequired -> "監視とバンカーの少なくとも一方を選んでください。"
    RelayConnectionsNotConfirmed -> "変更は保存しましたが、リレーの接続に反映されたかを確認できませんでした。"
    EditRelayRoles -> "用途を編集"
    DeleteRelay -> "リレーを削除"
    DeleteRelaySubmit -> "リレーを削除する"
    EditRelayRolesDescription ->
      "バンカーに使うのをやめると、接続 URI の relay= からこのリレーが外れ、このリレーだけで接続しているクライアントは応答を受け取れなくなります。そのクライアントには、ダッシュボードから新しい接続 URI を貼り付け直してください。"
    DeleteRelayDescription ->
      "このリレーへの接続を閉じ、登録から削除します。バンカーに使っていた場合、このリレーだけで接続しているクライアントは応答を受け取れなくなるので、ダッシュボードから新しい接続 URI を貼り付け直してください。"
    RelaysNotAvailable -> "リレーを利用できません"
    RelayNotFound -> "このリレーは登録されていません。すでに削除された可能性があるので、ダッシュボードで確認してください。"
    Plugins -> "プラグイン"
    NameColumn -> "名前"
    PluginRunning -> "動作中"
    PluginOverloaded -> "過負荷"
    PluginDisabled -> "無効"
    ReenablePlugin -> "再有効化"
    PluginUnavailable -> "応答なし"
    Dropped(count:) -> "（破棄 " <> int.to_string(count) <> " 件）"
    NoPlugins -> "有効なプラグインはありません。"
    ApproveConnection -> "接続を承認"
    WrongSecretOffered -> "接続 secret が一致しません。"
    WrongSecretNotice ->
      "secret を再生成する前の接続 URI を使い続けているクライアントか、secret を推測する試みです。心当たりの無いクライアントなら拒否してください。"
    Approved -> "承認しました"
    Denied -> "拒否しました"
    ApprovedCloseWindow -> "承認しました。このウィンドウは閉じてかまいません。"
    DeniedCloseWindow -> "拒否しました。このウィンドウは閉じてかまいません。"
    NotFound -> "見つかりません"
    ChangeNotConfirmed -> "変更を確認できませんでした"
    ChangeNotApplied -> "変更を反映できませんでした"
    BunkerNotAvailable -> "バンカーを利用できません"
    CheckDashboardBeforeRetrying -> "やり直す前に、ダッシュボードで反映されたかを確かめてください。"
    AccountsNotAvailable -> "アカウントを利用できません"
    MethodNotAllowed -> "この方法では開けません"
    BadRequest -> "要求を処理できません"
    PageNotFound -> "この URL のページはありません。"
    ApprovalRequestGone(minutes:) ->
      "この接続要求は見つかりません。"
      <> int.to_string(minutes)
      <> " 分で失効するため時間切れになったか、すでに承認か拒否がされた可能性があります。クライアントから接続し直してください。"
    AccountNotFound -> "このアカウントは登録されていません。すでに削除された可能性があるので、ダッシュボードで確認してください。"
    MethodNotAllowedDetail ->
      "この URL は管理 UI のボタンから送る操作のもので、直接は開けません。ダッシュボードから操作してください。"
    FormNotReadable -> "フォームの値が足りません。ダッシュボードからやり直してください。"
    OriginMismatch ->
      "要求の Origin が Host と一致しません。リバースプロキシーを前段に置いている場合は、Host ヘッダーを書き換えずに渡してください（README の「リバースプロキシーの設定」）。"
    BunkerDidNotRespond -> "バンカーが応答しませんでした。"
    StoreDidNotConfirm -> "データベースが変更を確定しませんでした。反映されている可能性があります。"
    NotAvailable -> "今は取得できません。"
    ImportPrivateKey -> "既存の秘密鍵を登録"
    ImportDescription ->
      "アカウントの秘密鍵（nsec）を貼り付けてください。秘密鍵は登録の直後に 1 回だけ表示し、その後は管理パスワードを入力し直したときにだけ表示します。ブラウザーがパスワードとして保存するよう勧めても、保存しないでください。"
    PrivateKeyNsec -> "秘密鍵（nsec）"
    Label -> "ラベル"
    LabelHint(max:) ->
      int.to_string(max) <> " 文字まで。組み合わせた絵文字は 1 つで数文字分になることがあります。"
    Register -> "登録する"
    GenerateNewKey -> "新しい秘密鍵を生成"
    GenerateDescription -> "サーバーで新しい秘密鍵を生成します。登録する前に、バックアップのために表示します。"
    Generate -> "生成する"
    // 引用する理由（account is already registered）はバンカーから英語のまま届くので、
    // 画面に出る文言と一致させるために英語で引用する。
    SkippedRowNote ->
      "ダッシュボードに無いアカウントの登録で「account is already registered」と表示される場合は、別のマスターキーで暗号化された行がデータベースに残っています。削除の方法は README を参照してください。"
    GeneratedKey -> "生成した秘密鍵"
    BackUpNow -> "この秘密鍵を今すぐバックアップしてください。"
    GeneratedKeyNotice ->
      "「この鍵を登録する」を押すまで、アカウントは登録されません。登録した後は、管理パスワードを入力し直したときにだけ表示します。"
    RegisterThisKey -> "この鍵を登録する"
    RegistrationNotAccepted ->
      "アカウントを利用できない状態のため、登録していません。しばらく待ってから、もう一度「この鍵を登録する」を押してください。"
    // 引用する理由（account is already registered）はバンカーから英語のまま届くので、
    // 画面に出る文言と一致させるために英語で引用する。
    RegistrationNotConfirmed ->
      "登録されたかを確認できませんでした。秘密鍵をバックアップしてから、もう一度「この鍵を登録する」を押してください。登録されていなければ登録し、登録されていれば「account is already registered」と表示します。"
    AccountRegistered -> "アカウントを登録しました"
    Account -> "アカウント"
    BackUpIfNotAlready -> "まだバックアップしていなければ、この秘密鍵をバックアップしてください。"
    RegisteredKeyNotice -> "もう一度表示するには、管理パスワードの入力が必要です。接続 URI はダッシュボードにあります。"
    Save -> "保存する"
    RotateSecretSubmit -> "secret を再生成する"
    DeleteAccountSubmit -> "アカウントを削除する"
    ShowPrivateKeySubmit -> "秘密鍵を表示する"
    RotateSecretDescription ->
      "新しい接続 secret を生成します。古い接続 URI で接続するクライアントは承認なしでは受け付けなくなりますが、承認済みのセッションは残ります。ダッシュボードから新しい接続 URI をクライアントに貼り付け直してください。"
    DeleteDescription -> "秘密鍵をバンカーとデータベースから削除します。"
    DeleteWarning -> "この鍵を他の場所に保存していなければ、アカウントは失われます。"
    DeleteAlsoRemoves -> "このアカウントのセッションと承認待ちの接続も削除します。"
    DeleteUnreadableDescription -> "この行をバンカーとデータベースから削除します。"
    DeleteUnreadableWarning -> "nsec を控えていなければ、アカウントは失われます。"
    DeleteUnreadableRecover ->
      "以前の ACCOUNT_MASTER_KEY に戻して起動し直すと、秘密鍵を表示して控えられます。"
    ShowPrivateKeyDescription ->
      "秘密鍵を表示するには、管理パスワードを入力し直してください。表示したことは npub とともにログに記録します。"
    AdminPassword -> "管理パスワード"
    PrivateKey -> "秘密鍵"
    CloseTabAfterCopying -> "鍵をコピーしたら、このタブを閉じてください。"
    ResendNotice ->
      "このページを再読み込みしたり、戻るボタンで戻ってきたりすると、フォームが再送信され、鍵がもう一度表示されてログにも再び記録されることがあります。"
    IncorrectPassword -> "管理パスワードが違います。"
    LabelEmpty -> "ラベルを入力してください。"
    LabelTooLong(max:) -> "ラベルは " <> int.to_string(max) <> " 文字以内にしてください。"
    LabelHasControlCharacters -> "ラベルに制御文字は使えません。"
    InvalidNsec(error) -> japanese_nip19(error)
    PrivateKeyOutOfRange -> "秘密鍵が有効な範囲にありません。"
  }
}

/// 飛ばされた行を読み込めなかった理由の英語。
fn english_row_error(reason: vault.RowError) -> String {
  case reason {
    vault.MalformedPubkey -> "The pubkey column cannot be read."
    vault.UndecryptablePrivateKey ->
      "The private key cannot be decrypted (wrong ACCOUNT_MASTER_KEY or a tampered row)."
    vault.InvalidPrivateKey ->
      "The decrypted private key is not a valid secp256k1 key."
    vault.PublicKeyMismatch ->
      "The decrypted private key does not match the pubkey."
    vault.UndecryptableSecret ->
      "The connection secret cannot be decrypted (wrong ACCOUNT_MASTER_KEY or a tampered row)."
    vault.InvalidSecret ->
      "The decrypted connection secret is empty or not valid UTF-8."
  }
}

/// nsec を復号できなかった理由の日本語。
fn japanese_nip19(error: nip19.Nip19Error) -> String {
  case error {
    nip19.TooLong -> "bech32 の文字列が長すぎます。"
    nip19.InvalidCharacter -> "bech32 で使えない文字が含まれています。"
    nip19.MixedCase -> "bech32 の文字列に大文字と小文字が混在しています。"
    nip19.MissingSeparator -> "bech32 の区切り文字がありません。"
    nip19.EmptyPrefix -> "bech32 の接頭辞が空です。"
    nip19.TooShort -> "bech32 のデータ部がチェックサムより短いです。"
    nip19.InvalidChecksum -> "bech32 のチェックサムが一致しません。"
    nip19.PrefixMismatch(expected) ->
      "接頭辞が " <> nip19.prefix_text(expected) <> " ではありません。"
    nip19.InvalidPadding -> "bech32 のパディングが正しくありません。"
    nip19.InvalidLength -> "鍵の長さが 32 バイトではありません。"
  }
}

/// 飛ばされた行を読み込めなかった理由の日本語。
fn japanese_row_error(reason: vault.RowError) -> String {
  case reason {
    vault.MalformedPubkey -> "pubkey の列を読めない行です。"
    vault.UndecryptablePrivateKey ->
      "秘密鍵を復号できません（ACCOUNT_MASTER_KEY 違いか、行の改ざん）。"
    vault.InvalidPrivateKey -> "復号した秘密鍵が secp256k1 の鍵として不正です。"
    vault.PublicKeyMismatch -> "復号した秘密鍵が pubkey と一致しません。"
    vault.UndecryptableSecret ->
      "接続 secret を復号できません（ACCOUNT_MASTER_KEY 違いか、行の改ざん）。"
    vault.InvalidSecret -> "復号した接続 secret が空か、UTF-8 として不正です。"
  }
}
