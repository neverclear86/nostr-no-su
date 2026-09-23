//// 管理 UI の表示の言語と、言語ごとの文言。
////
//// 文言は `Message` の値で表し、`text` が表示の言語の文字列にする。言語ごとの関数
//// （`english`、`japanese`）は、どれも `Message` のすべての値を網羅する `case` なので、
//// どちらかの言語の訳が無いとビルドが通らない。値を埋め込む文言（残り秒、件数、ラベルの
//// 上限）は値を持つ構築子にし、語順と記号を含めて言語ごとに文全体を返す。文の中に要素（`<time>`）を
//// 挟む文言だけは、要素の前と後ろを別の構築子（`ExpiryBeforeTime`、`ExpiryAfterTime`）にする。
////
//// 言語を足すときは、`Language` に構築子を、`languages` に値を足し、コンパイラーが示す
//// `case`（`code`、`native_name`、`text`、`lead`、`sentence_gap`、`i18n_test` の
//// `language_count`）に枝を足す。
////
//// 管理 UI の外（バンカー、アカウントストア、設定、プラグイン）から英語の文字列で届く
//// 理由は訳さず、`Untranslated` として英語のまま出す。設定、DB、プラグインの理由はログにも
//// 同じ文が出るが、バンカーのアクターの案内（`accounts are being loaded` など）は出ない。
//// 例外として、変更を確認できなかったときの本文（アカウントの変更、リレーの変更、
//// クライアントの接続の 202 と、承認・拒否・取り消しの 503）は、バンカーと管理 UI の
//// Context が原因を型で返すので訳す。
//// 承認待ちの一覧に無いトークンの承認ページの 404 の本文も訳す。これは外から届いた文字列
//// ではなく、管理 UI が一覧との照合で自分で決めている判定だからである。プラグインの
//// 再有効化の 503 は英語のまま。読み込みで飛ばされた行の理由は `vault.RowError` の型で
//// 届くので訳す。アカウントの登録済みと未登録の理由も、バンカーが
//// `bunker.ChangeFailure` の型で返すので訳す（未登録は `AccountNotFound` の文言を
//// 使う）。
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
  CouldNotListPendingAccountsSessions
  CouldNotAddRelay
  CouldNotSaveRelay
  CouldNotDeleteRelay
  CouldNotSavePermissions
  CouldNotStartConnection
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
        CouldNotListPendingAccountsSessions -> "承認待ち、アカウント、セッションの一覧を表示できません。"
        CouldNotAddRelay -> "リレーを登録できませんでした。"
        CouldNotSaveRelay -> "用途を保存できませんでした。"
        CouldNotDeleteRelay -> "リレーを削除できませんでした。"
        CouldNotSavePermissions -> "権限を保存できませんでした。"
        CouldNotStartConnection -> "接続を開始できませんでした。"
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
  LogoSubtitle
  LanguageSwitchLabel
  ThemeSwitchLabel
  FollowBrowser
  ThemeLight
  ThemeDark
  Copy
  Copied
  SelectedPressCtrlC
  CopyNpub
  CopyClient
  ShowFieldHint
  // ダッシュボード
  Dashboard
  Pending
  OverviewLabel
  AwaitingDecision
  SoonestExpiry(remaining: String)
  PendingExpireAfterMinutes(minutes: Int)
  OverviewNotAvailable
  UnreadableRowCount(count: Int)
  AllAccountsLoaded
  Sessions
  ApprovedClients
  DisconnectedRelayCount(count: Int)
  UnansweredRelayCount(count: Int)
  AllRelaysConnected
  NoBunkerRelayShort
  RunningOfTotal
  OverloadedPluginCount(count: Int)
  DisabledPluginCount(count: Int)
  UnavailablePluginCount(count: Int)
  NoPluginsEnabledShort
  PluginsNotLoadedShort(count: Int)
  PendingConnections
  PendingConnectionsDescription
  RefreshesEverySeconds(seconds: Int)
  PendingSecretNotOffered
  PendingSecretMismatch
  NoPermissionsRequestedBadge
  Signer
  Client
  ExpiresIn
  UtcTimeOfDay(time: String)
  ExpiryBeforeTime(remaining: String)
  ExpiryAfterTime
  Permissions
  NoPermissionsRequested
  EditPermissions
  EditPermissionsDescription
  CurrentPermissions
  PermissionsNotDeclared
  AllowSignEvent
  SignEventAlwaysRefused
  AllowNip44Encrypt
  AllowNip44Decrypt
  AllowedKinds
  AllowedKindsHint
  OtherPermissions
  OtherPermissionsHint
  PermissionSignAnyKind
  PermissionSignKind(kind: Int)
  PermissionNip44Encrypt
  PermissionNip44Decrypt
  PermissionUnsupported
  UnsupportedPermissionsNote
  SelectAtLeastOne
  InvalidKindList
  SessionNotFound
  Created
  LastUsed
  JustNow
  MinutesAgo(minutes: Int)
  HoursAgo(hours: Int)
  DaysAgo(days: Int)
  Approve
  Deny
  ApproveAnyway
  ApprovalExplanation
  Accounts
  Add
  AddAccount
  NoAccounts
  GettingStarted
  GettingStartedDescription
  SetupBunkerRelay
  SetupBunkerRelayDescription
  SetupAccount
  SetupAccountDescription
  SetupConnectionUri
  SetupConnectionUriDescription
  SetupStepDone
  ReloadAccounts
  UnreadableAccounts
  UnreadableAccountsWarning
  UnreadableReason(reason: vault.RowError)
  UnreadableNotDeletable
  NotLoadedPlugins
  NotLoadedPluginsWarning
  PluginLoadFailed
  ReasonLabel
  ConnectionUri
  ConnectionUriForApproval
  ConnectionUrisAndPublicKey
  ConnectionQr
  ConnectionQrDescription
  ConnectionQrSecretWarning
  CouldNotEncodeQr
  ScanWithClientScanner
  CameraCopySteps
  CameraCopyNote
  BunkerRelaysForUri
  BunkerRelaysHint
  ApprovalUriNeedsApproval
  ConnectWithClientUri
  ConnectWithClientUriHint
  PublicKeyHex
  EditLabel
  ShowPrivateKey
  RotateSecret
  DeleteAccount
  Delete
  ApprovedSessions
  ApprovedSessionsDescription
  NoApprovedSessions
  Revoke
  Relays
  Role
  MonitorRole
  BunkerRole
  RelayRoleUnused
  RelayConnected
  RelayDisconnected
  NoBunkerRelay
  AddRelay
  RelayUrl
  RelayUrlHint
  UseForMonitoring
  UseForBunker
  MonitorRoleDescription
  BunkerRoleDescription
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
  ConnectClient
  ConnectClientDescription
  NostrconnectUri
  NostrconnectUriHint
  SigningAccount
  Connect
  NoAccountsForConnect
  SigningAccountNotFound
  NostrconnectRelayNotConnected
  NotNostrconnectUri
  NostrconnectClientInvalid
  NostrconnectQueryInvalid
  NostrconnectRelayInvalid
  NostrconnectSecretMissing
  Plugins
  /// ダッシュボードのプラグインの節の見出しの下の 1 行の説明。
  PluginsDescription
  PluginRunning
  PluginOverloaded
  PluginDisabled
  ReenablePlugin
  PluginUnavailable
  Dropped(count: Int)
  NoPlugins
  /// 節とブロックの空の状態に共通で使う。
  PluginSectionEmpty
  /// `image` ブロックの `url` の scheme が `http` / `https` でないときの理由。
  PluginImageNotShown
  /// プラグインのページの `<title>` と `<h1>`。プラグイン名はここに混ぜない
  /// （`view.untranslated` で別に出す）。
  PluginPage
  /// ダッシュボードのプラグインの節から、ページを供給するプラグインへのリンクの文言。
  OpenPluginPage
  /// プラグインのページの `sections` が 0 件のときの案内。
  PluginPageEmpty
  /// 節 1 つの記述が変換できなかったときの案内。理由はこれに続けて英語のまま出す。
  PluginSectionFailed
  /// プラグインのページの応答が得られなかったときの見出し。
  PluginPageUnavailable
  /// プラグインのページのフォームの送信が拒否された、または呼び出しに失敗した
  /// ときの見出し。
  PluginActionFailed
  /// 無効になったプラグインのページに出す注意。
  PluginPageWhileDisabled
  // 承認ページと通知ページ
  ApproveConnection
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
  AccountAlreadyRegistered
  MethodNotAllowedDetail
  FormNotReadable
  OriginMismatch
  BunkerDidNotRespond
  StoreDidNotConfirm
  NotAvailable
  NotAvailableForReasonAbove
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
    LogoSubtitle -> "Admin"
    LanguageSwitchLabel -> "Language"
    ThemeSwitchLabel -> "Theme"
    FollowBrowser -> "Browser setting"
    ThemeLight -> "Light"
    ThemeDark -> "Dark"
    Copy -> "Copy"
    Copied -> "Copied"
    SelectedPressCtrlC -> "Selected. Press Ctrl+C (⌘C on macOS) to copy."
    CopyNpub -> "Copy npub"
    CopyClient -> "Copy client"
    ShowFieldHint -> "Show help"
    Dashboard -> "Dashboard"
    Pending -> "Pending"
    OverviewLabel -> "Overview"
    AwaitingDecision -> "Awaiting your decision"
    SoonestExpiry(remaining:) -> "Soonest expires in " <> remaining
    PendingExpireAfterMinutes(minutes:) ->
      "Expire after " <> int.to_string(minutes) <> " minutes"
    OverviewNotAvailable -> "Not available"
    UnreadableRowCount(count:) -> int.to_string(count) <> " unreadable rows"
    AllAccountsLoaded -> "All loaded"
    Sessions -> "Sessions"
    ApprovedClients -> "Approved clients"
    DisconnectedRelayCount(count:) -> int.to_string(count) <> " disconnected"
    UnansweredRelayCount(count:) -> int.to_string(count) <> " unanswered"
    AllRelaysConnected -> "All connected"
    NoBunkerRelayShort -> "No bunker relay"
    RunningOfTotal -> "Running / total"
    OverloadedPluginCount(count:) -> int.to_string(count) <> " overloaded"
    DisabledPluginCount(count:) -> int.to_string(count) <> " disabled"
    UnavailablePluginCount(count:) -> int.to_string(count) <> " unavailable"
    NoPluginsEnabledShort -> "No plugins enabled"
    PluginsNotLoadedShort(count:) -> int.to_string(count) <> " failed to load"
    PendingConnections -> "Pending connections"
    PendingConnectionsDescription ->
      "Until you approve, this client cannot request signing or encryption."
    RefreshesEverySeconds(seconds:) ->
      "Refreshes every " <> int.to_string(seconds) <> " s"
    PendingSecretNotOffered -> "Secret not offered"
    PendingSecretMismatch -> "Secret mismatch"
    NoPermissionsRequestedBadge -> "No permissions requested"
    Signer -> "Signer"
    Client -> "Client"
    ExpiresIn -> "Expires in"
    UtcTimeOfDay(time:) -> time <> " UTC"
    ExpiryBeforeTime(remaining:) -> remaining <> " (expires at "
    ExpiryAfterTime -> ")"
    Permissions -> "Permissions"
    NoPermissionsRequested ->
      "None requested. Signing any kind but 24133, and NIP-44 encryption and decryption, are allowed."
    EditPermissions -> "Edit permissions"
    EditPermissionsDescription ->
      "Choose the operations this client may request."
    CurrentPermissions -> "Current permissions"
    PermissionsNotDeclared -> "Not declared (default)"
    AllowSignEvent -> "Allow signing events"
    SignEventAlwaysRefused ->
      "Kind 24133 is always refused, even when this is allowed."
    AllowNip44Encrypt -> "Allow NIP-44 encryption"
    AllowNip44Decrypt -> "Allow NIP-44 decryption"
    AllowedKinds -> "Allowed kinds"
    AllowedKindsHint ->
      "Used only when signing events is not allowed above. Comma-separated event kinds, such as 1,10002."
    OtherPermissions -> "Other declared permissions"
    OtherPermissionsHint ->
      "Not handled by this form. Kept unchanged when you save."
    PermissionSignAnyKind -> "Sign any kind"
    PermissionSignKind(kind:) ->
      "Sign "
      <> case kind_name(English, kind) {
        Some(name) -> name
        None -> "kind " <> int.to_string(kind)
      }
    PermissionNip44Encrypt -> "Encrypt with NIP-44"
    PermissionNip44Decrypt -> "Decrypt with NIP-44"
    PermissionUnsupported -> "Unsupported"
    UnsupportedPermissionsNote ->
      "Unsupported permissions name methods this bunker does not implement. Their requests are refused even when granted."
    SelectAtLeastOne -> "choose at least one permission"
    InvalidKindList ->
      "kinds must be a comma-separated list of non-negative integers"
    SessionNotFound -> "this session is not approved"
    Created -> "Created"
    LastUsed -> "Last used"
    JustNow -> "just now"
    MinutesAgo(minutes:) -> int.to_string(minutes) <> " min ago"
    HoursAgo(hours:) -> int.to_string(hours) <> " h ago"
    DaysAgo(days:) -> int.to_string(days) <> " d ago"
    Approve -> "Approve"
    Deny -> "Deny"
    ApproveAnyway -> "Approve anyway"
    ApprovalExplanation ->
      "Approving lets this client request signing and encryption within the permissions above. You can change them later from the approved session."
    Accounts -> "Accounts"
    Add -> "Add"
    AddAccount -> "Add account"
    NoAccounts ->
      "No accounts registered. Import an nsec or generate a new key."
    GettingStarted -> "Getting started"
    GettingStartedDescription ->
      "Register a relay and an account, then paste the connection URI into your client."
    SetupBunkerRelay -> "Add a bunker relay"
    SetupBunkerRelayDescription ->
      "Clients send signing and encryption requests through this relay. You need at least one."
    SetupAccount -> "Register an account"
    SetupAccountDescription ->
      "Import an existing nsec or generate a new private key. Private keys are stored encrypted."
    SetupConnectionUri -> "Paste the connection URI into a client"
    SetupConnectionUriDescription ->
      "Once both are in place, give a client the connection URI or QR code from the Accounts section."
    SetupStepDone -> "Done"
    ReloadAccounts -> "Reload from database"
    UnreadableAccounts -> "Unreadable accounts"
    UnreadableAccountsWarning ->
      "The current ACCOUNT_MASTER_KEY cannot decrypt these rows."
    UnreadableReason(reason) -> english_row_error(reason)
    UnreadableNotDeletable ->
      "This row cannot be deleted here because its pubkey cannot be read."
    NotLoadedPlugins -> "Plugins that failed to load"
    PluginLoadFailed -> "failed to load"
    NotLoadedPluginsWarning ->
      "These plugins are not running. Fix the cause below and restart the server."
    ReasonLabel -> "Reason"
    ConnectionUri -> "Connection URI"
    ConnectionUriForApproval -> "Connection URI (approval)"
    ConnectionUrisAndPublicKey -> "Connection URIs and public key"
    ConnectionQr -> "Connection QR code"
    ConnectionQrDescription ->
      "Choose a connection URI with the tabs. The code shown is meant to be scanned and copied with the phone's camera. To use the client's own scanner instead, open the panel below the code and scan the code inside."
    ConnectionQrSecretWarning ->
      "The codes and the URI on this tab contain the connection secret. Do not show them where others can see the screen."
    CouldNotEncodeQr ->
      "The URI is too long for a QR code. Copy it from the field below."
    ScanWithClientScanner -> "Scan with the client's own scanner"
    CameraCopySteps ->
      "Scan the first code in the selected tab with the camera, copy the text, type bunker:// in the client's input field, and paste the text after it."
    CameraCopyNote ->
      "As long as it starts with bunker://, leave the %2E in relay= as it is; the client turns it back into a dot."
    BunkerRelaysForUri -> "Relays this URI uses"
    BunkerRelaysHint ->
      "If the phone cannot reach these relays, the connection fails even when the code scans."
    ApprovalUriNeedsApproval ->
      "A client that connects with this URI cannot sign until you approve it under pending connections on the dashboard."
    ConnectWithClientUri -> "Connect with the client's own URI"
    ConnectWithClientUriHint ->
      "If the client can show its own nostrconnect:// URI or QR code, pasting that into this admin UI is more reliable: the phone copies it from the client itself, so the camera's limits do not apply."
    PublicKeyHex -> "Public key (hex)"
    EditLabel -> "Edit label"
    ShowPrivateKey -> "Show private key"
    RotateSecret -> "Rotate secret"
    DeleteAccount -> "Delete account"
    Delete -> "Delete"
    ApprovedSessions -> "Approved sessions"
    ApprovedSessionsDescription ->
      "Clients can request signing and encryption within the permissions shown here."
    NoApprovedSessions -> "No approved sessions."
    Revoke -> "Revoke"
    Relays -> "Relays"
    Role -> "Role"
    MonitorRole -> "monitor"
    BunkerRole -> "bunker"
    RelayRoleUnused -> "Unused"
    RelayConnected -> "connected"
    RelayDisconnected -> "disconnected"
    NoBunkerRelay ->
      "No relay is used for the bunker. Clients cannot connect to any account until you add one."
    AddRelay -> "Add relay"
    RelayUrl -> "Relay URL"
    RelayUrlHint -> "Starts with ws:// or wss://."
    UseForMonitoring -> "Use for monitoring"
    UseForBunker -> "Use for the bunker"
    MonitorRoleDescription ->
      "Subscribes to registered accounts' events and passes them to plugins"
    BunkerRoleDescription -> "Accepts NIP-46 requests"
    AddRelayDescription ->
      "Use NIP-46-only relays, which refuse subscriptions other than kind 24133, for the bunker only."
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
    ConnectClient -> "Connect a client"
    ConnectClientDescription ->
      "Paste the URI shown by the client. Its relays are added for the bunker."
    NostrconnectUri -> "nostrconnect:// URI"
    NostrconnectUriHint -> "Starts with nostrconnect://."
    SigningAccount -> "Signing account"
    Connect -> "Connect"
    NoAccountsForConnect -> "Register an account before connecting a client."
    SigningAccountNotFound -> "the signing account is not registered"
    NostrconnectRelayNotConnected ->
      "could not connect to any relay in the uri in time"
    NotNostrconnectUri -> "the uri must start with nostrconnect://"
    NostrconnectClientInvalid ->
      "the client public key in the uri must be 32 bytes of hex"
    NostrconnectQueryInvalid -> "the query of the uri could not be read"
    NostrconnectRelayInvalid ->
      "the uri must carry at least one relay with a ws:// or wss:// url"
    NostrconnectSecretMissing -> "the uri must carry a secret"
    Plugins -> "Plugins"
    PluginsDescription ->
      "Receives and processes the events of registered accounts."
    PluginRunning -> "running"
    PluginOverloaded -> "overloaded"
    PluginDisabled -> "disabled"
    ReenablePlugin -> "Re-enable"
    PluginUnavailable -> "unavailable"
    Dropped(count:) -> "(dropped " <> int.to_string(count) <> ")"
    NoPlugins ->
      "No plugins enabled. Plugins placed in the plugin directory are loaded when the server restarts."
    PluginSectionEmpty -> "Nothing to show."
    PluginImageNotShown -> "Image not shown: the URL is not http or https."
    PluginPage -> "Plugin page"
    OpenPluginPage -> "Open"
    PluginPageEmpty -> "This plugin page has nothing to show."
    PluginSectionFailed -> "This section could not be displayed."
    PluginPageUnavailable -> "Plugin page not available"
    PluginActionFailed -> "Plugin action failed"
    PluginPageWhileDisabled ->
      "This plugin is disabled and is not handling events."
    ApproveConnection -> "Approve connection"
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
    AccountAlreadyRegistered -> "account is already registered"
    MethodNotAllowedDetail ->
      "This URL is for a button in the admin UI and cannot be opened directly. Use the dashboard instead."
    FormNotReadable ->
      "The form was incomplete. Go back to the dashboard and try again."
    OriginMismatch ->
      "The Origin of the request does not match the Host. If a reverse proxy is in front of the admin UI, pass the Host header through unchanged; see docs/configuration.md."
    BunkerDidNotRespond -> "the bunker did not respond"
    StoreDidNotConfirm ->
      "the store did not confirm the change; it may have been applied"
    NotAvailable -> "Not available right now."
    NotAvailableForReasonAbove -> "Not available for the reason above."
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
      "If registration reports \"account is already registered\" for an account that is not on the dashboard, a row encrypted with a different master key is left in the database; see docs/operations.md for how to remove it."
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
      "Reloading this page or coming back to it with the back button can resend the form, which shows the key again and logs again that it was shown."
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
    LogoSubtitle -> "管理画面"
    LanguageSwitchLabel -> "言語"
    ThemeSwitchLabel -> "テーマ"
    FollowBrowser -> "ブラウザーの設定"
    ThemeLight -> "ライト"
    ThemeDark -> "ダーク"
    Copy -> "コピー"
    Copied -> "コピー済み"
    SelectedPressCtrlC -> "選択しました。Ctrl+C（macOS では ⌘C）でコピーしてください。"
    CopyNpub -> "npub をコピー"
    CopyClient -> "クライアントをコピー"
    ShowFieldHint -> "補足を表示"
    Dashboard -> "ダッシュボード"
    Pending -> "承認待ち"
    OverviewLabel -> "概要"
    AwaitingDecision -> "承認を待っています"
    SoonestExpiry(remaining:) -> "最短 " <> remaining <> " で失効"
    PendingExpireAfterMinutes(minutes:) -> int.to_string(minutes) <> " 分で失効します"
    OverviewNotAvailable -> "取得できません"
    UnreadableRowCount(count:) -> "読み込めない行 " <> int.to_string(count)
    AllAccountsLoaded -> "すべて読み込み済み"
    Sessions -> "セッション"
    ApprovedClients -> "承認済みのクライアント"
    DisconnectedRelayCount(count:) -> "未接続 " <> int.to_string(count)
    UnansweredRelayCount(count:) -> "応答なし " <> int.to_string(count)
    AllRelaysConnected -> "すべて接続中"
    NoBunkerRelayShort -> "バンカー用が未登録"
    RunningOfTotal -> "動作中 / 全件数"
    OverloadedPluginCount(count:) -> "過負荷 " <> int.to_string(count)
    DisabledPluginCount(count:) -> "無効 " <> int.to_string(count)
    UnavailablePluginCount(count:) -> "応答なし " <> int.to_string(count)
    NoPluginsEnabledShort -> "有効なプラグインなし"
    PluginsNotLoadedShort(count:) -> "読み込み失敗 " <> int.to_string(count)
    PendingConnections -> "承認待ちの接続"
    PendingConnectionsDescription -> "承認するまで、このクライアントは署名も暗号化も依頼できません。"
    RefreshesEverySeconds(seconds:) -> int.to_string(seconds) <> " 秒ごとに更新"
    PendingSecretNotOffered -> "secret 提示なし"
    PendingSecretMismatch -> "secret 不一致"
    NoPermissionsRequestedBadge -> "権限の要求なし"
    Signer -> "署名者"
    Client -> "クライアント"
    ExpiresIn -> "失効まで"
    UtcTimeOfDay(time:) -> time <> "（UTC）"
    ExpiryBeforeTime(remaining:) -> remaining <> "（"
    ExpiryAfterTime -> " に失効）"
    Permissions -> "権限"
    NoPermissionsRequested -> "要求なし。kind 24133 を除く署名と、NIP-44 の暗号化・復号を許します。"
    EditPermissions -> "権限を編集"
    EditPermissionsDescription -> "このクライアントに許す操作を選んでください。"
    CurrentPermissions -> "今の権限"
    PermissionsNotDeclared -> "宣言なし（既定）"
    AllowSignEvent -> "署名を許可する"
    SignEventAlwaysRefused -> "kind 24133 はこれを許可していても常に拒否します。"
    AllowNip44Encrypt -> "NIP-44 の暗号化を許可する"
    AllowNip44Decrypt -> "NIP-44 の復号を許可する"
    AllowedKinds -> "許可する kind"
    AllowedKindsHint -> "上の署名を許可していないときだけ使います。1,10002 のようにカンマ区切りで指定します。"
    OtherPermissions -> "そのほかの宣言"
    OtherPermissionsHint -> "このフォームが扱わない宣言です。保存してもそのまま残します。"
    PermissionSignAnyKind -> "すべての kind の署名"
    PermissionSignKind(kind:) ->
      case kind_name(Japanese, kind) {
        Some(name) -> name <> "の署名"
        None -> "kind " <> int.to_string(kind) <> " の署名"
      }
    PermissionNip44Encrypt -> "NIP-44 で暗号化"
    PermissionNip44Decrypt -> "NIP-44 で復号"
    PermissionUnsupported -> "未対応"
    UnsupportedPermissionsNote -> "「未対応」の権限は、このバンカーが実装していない方法です。許可しても要求は拒否します。"
    SelectAtLeastOne -> "権限を少なくとも 1 つ選んでください。"
    InvalidKindList -> "kind はカンマ区切りの 0 以上の整数で入力してください。"
    SessionNotFound -> "このセッションは承認されていません。"
    Created -> "作成"
    LastUsed -> "最終利用"
    JustNow -> "たった今"
    MinutesAgo(minutes:) -> int.to_string(minutes) <> " 分前"
    HoursAgo(hours:) -> int.to_string(hours) <> " 時間前"
    DaysAgo(days:) -> int.to_string(days) <> " 日前"
    Approve -> "承認する"
    Deny -> "拒否する"
    ApproveAnyway -> "それでも承認する"
    ApprovalExplanation ->
      "承認すると、このクライアントは上の権限の範囲で署名と暗号化を依頼できます。承認したときの権限は、後から「承認済みのセッション」の「権限を編集」で変えられます。"
    Accounts -> "アカウント"
    Add -> "追加"
    AddAccount -> "アカウントを追加"
    NoAccounts -> "登録されたアカウントはありません。nsec を登録するか、新しい鍵を生成してください。"
    GettingStarted -> "はじめに"
    GettingStartedDescription -> "リレーとアカウントを登録し、接続 URI をクライアントに貼ると使えます。"
    SetupBunkerRelay -> "バンカー用のリレーを追加"
    SetupBunkerRelayDescription -> "クライアントは、このリレーを通して署名と暗号化を依頼します。1 件以上必要です。"
    SetupAccount -> "アカウントを登録"
    SetupAccountDescription -> "既存の nsec を登録するか、新しい秘密鍵を生成します。秘密鍵は暗号化して保存します。"
    SetupConnectionUri -> "接続 URI をクライアントに貼る"
    SetupConnectionUriDescription ->
      "両方がそろったら、アカウントの節の接続 URI か QR コードをクライアントに渡します。"
    SetupStepDone -> "済み"
    ReloadAccounts -> "DB から読み直す"
    UnreadableAccounts -> "読み込めなかったアカウント"
    UnreadableAccountsWarning -> "現在の ACCOUNT_MASTER_KEY では、これらの行の秘密鍵を復号できません。"
    UnreadableReason(reason) -> japanese_row_error(reason)
    UnreadableNotDeletable -> "この行は pubkey を読めないため、画面からは削除できません。"
    NotLoadedPlugins -> "読み込めなかったプラグイン"
    PluginLoadFailed -> "読み込み失敗"
    NotLoadedPluginsWarning -> "これらのプラグインは動作していません。下の理由を直してサーバーを再起動してください。"
    ReasonLabel -> "理由"
    ConnectionUri -> "接続 URI"
    ConnectionUriForApproval -> "接続 URI（要承認）"
    ConnectionUrisAndPublicKey -> "接続 URI と公開鍵"
    ConnectionQr -> "接続 QR コード"
    ConnectionQrDescription ->
      "タブで接続 URI を選びます。出ているコードは、端末のカメラで読み取ってコピーするためのものです。クライアント自身の読み取り機能を使うときは、コードの下の畳みを開いてその中のコードを読み取ってください。"
    ConnectionQrSecretWarning ->
      "このタブのコードと URI には接続 secret が含まれます。画面を他人に見られる場所では表示しないでください。"
    CouldNotEncodeQr -> "この URI は QR コードにするには長すぎます。下の欄からコピーしてください。"
    ScanWithClientScanner -> "クライアントの読み取り機能で読み取る"
    CameraCopySteps ->
      "選んだタブの最初のコードをカメラで読み取ってテキストをコピーし、クライアントの入力欄に bunker:// と打ってから、その後ろに貼り付けます。"
    CameraCopyNote ->
      "先頭が bunker:// で始まっていれば、relay= の中の %2E はそのままで構いません。クライアントが . に戻します。"
    BunkerRelaysForUri -> "この URI が使うリレー"
    BunkerRelaysHint -> "スマートフォンからこれらのリレーに接続できないと、読み取れても接続は成立しません。"
    ApprovalUriNeedsApproval ->
      "この URI で接続したクライアントは、ダッシュボードの承認待ちで承認するまで署名できません。"
    ConnectWithClientUri -> "クライアント側の URI で接続する"
    ConnectWithClientUriHint ->
      "クライアントが nostrconnect:// の URI や QR コードを出せるなら、それを管理画面に貼る方が確実です。スマートフォン側でコピーできるので、カメラの制約を受けません。"
    PublicKeyHex -> "公開鍵（16 進）"
    EditLabel -> "ラベルを編集"
    ShowPrivateKey -> "秘密鍵を表示"
    RotateSecret -> "secret を再生成"
    DeleteAccount -> "アカウントを削除"
    Delete -> "削除"
    ApprovedSessions -> "承認済みのセッション"
    ApprovedSessionsDescription -> "クライアントは、ここに出ている権限の範囲で署名と暗号化を依頼できます。"
    NoApprovedSessions -> "承認済みのセッションはありません。"
    Revoke -> "承認を取り消す"
    Relays -> "リレー"
    Role -> "用途"
    MonitorRole -> "監視"
    BunkerRole -> "バンカー"
    RelayRoleUnused -> "未使用"
    RelayConnected -> "接続中"
    RelayDisconnected -> "未接続"
    NoBunkerRelay -> "バンカーに使うリレーがありません。リレーを追加するまで、クライアントはどのアカウントにも接続できません。"
    AddRelay -> "リレーを追加"
    RelayUrl -> "リレーの URL"
    RelayUrlHint -> "ws:// か wss:// で始まる URL。"
    UseForMonitoring -> "監視に使う"
    UseForBunker -> "バンカーに使う"
    MonitorRoleDescription -> "登録アカウントのイベントを購読してプラグインに渡す"
    BunkerRoleDescription -> "NIP-46 のリクエストを受け付ける"
    AddRelayDescription ->
      "kind 24133 以外の購読を拒否する NIP-46 専用のリレーは、バンカーにだけ使ってください。"
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
    ConnectClient -> "クライアントを接続"
    ConnectClientDescription -> "クライアントが出した URI を貼り付けます。URI のリレーはバンカーの用途で登録します。"
    NostrconnectUri -> "nostrconnect:// の URI"
    NostrconnectUriHint -> "nostrconnect:// で始まる URI。"
    SigningAccount -> "署名するアカウント"
    Connect -> "接続"
    NoAccountsForConnect -> "クライアントを接続する前に、アカウントを登録してください。"
    SigningAccountNotFound -> "署名するアカウントが登録されていません。"
    NostrconnectRelayNotConnected -> "URI のリレーのどれにも接続できませんでした。時間をおいて試してください。"
    NotNostrconnectUri -> "nostrconnect:// で始まる URI を貼り付けてください。"
    NostrconnectClientInvalid -> "URI のクライアント公開鍵が 32 バイトの 16 進ではありません。"
    NostrconnectQueryInvalid -> "URI のクエリーを読み取れませんでした。"
    NostrconnectRelayInvalid -> "URI に ws:// か wss:// で始まるリレーが 1 件も含まれていません。"
    NostrconnectSecretMissing -> "URI に secret が含まれていません。"
    Plugins -> "プラグイン"
    PluginsDescription -> "登録したアカウントのイベントを受け取って処理します。"
    PluginRunning -> "動作中"
    PluginOverloaded -> "過負荷"
    PluginDisabled -> "無効"
    ReenablePlugin -> "再有効化"
    PluginUnavailable -> "応答なし"
    Dropped(count:) -> "（破棄 " <> int.to_string(count) <> " 件）"
    NoPlugins -> "有効なプラグインはありません。プラグインのディレクトリーに置いたプラグインは、サーバーの再起動で読み込まれます。"
    PluginSectionEmpty -> "表示する内容はありません。"
    PluginImageNotShown -> "画像を表示していません。URL が http でも https でもありません。"
    PluginPage -> "プラグインのページ"
    OpenPluginPage -> "ページを開く"
    PluginPageEmpty -> "このプラグインのページに表示する内容はありません。"
    PluginSectionFailed -> "この節は表示できませんでした。"
    PluginPageUnavailable -> "プラグインのページを利用できません"
    PluginActionFailed -> "プラグインの操作に失敗しました"
    PluginPageWhileDisabled -> "このプラグインは無効で、イベントを処理していません。"
    ApproveConnection -> "接続を承認"
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
    AccountAlreadyRegistered -> "このアカウントはすでに登録されています。"
    MethodNotAllowedDetail ->
      "この URL は管理 UI のボタンから送る操作のもので、直接は開けません。ダッシュボードから操作してください。"
    FormNotReadable -> "フォームの値が足りません。ダッシュボードからやり直してください。"
    OriginMismatch ->
      "要求の Origin が Host と一致しません。リバースプロキシーを前段に置いている場合は、Host ヘッダーを書き換えずに渡してください（docs/configuration.md の「リバースプロキシーの設定」）。"
    BunkerDidNotRespond -> "バンカーが応答しませんでした。"
    StoreDidNotConfirm -> "データベースが変更を確定しませんでした。反映されている可能性があります。"
    NotAvailable -> "今は取得できません。"
    NotAvailableForReasonAbove -> "上の理由で取得できません。"
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
    SkippedRowNote ->
      "ダッシュボードに無いアカウントの登録で「このアカウントはすでに登録されています。」と表示される場合は、別のマスターキーで暗号化された行がデータベースに残っています。削除の方法は docs/operations.md を参照してください。"
    GeneratedKey -> "生成した秘密鍵"
    BackUpNow -> "この秘密鍵を今すぐバックアップしてください。"
    GeneratedKeyNotice ->
      "「この鍵を登録する」を押すまで、アカウントは登録されません。登録した後は、管理パスワードを入力し直したときにだけ表示します。"
    RegisterThisKey -> "この鍵を登録する"
    RegistrationNotAccepted ->
      "アカウントを利用できない状態のため、登録していません。しばらく待ってから、もう一度「この鍵を登録する」を押してください。"
    RegistrationNotConfirmed ->
      "登録されたかを確認できませんでした。秘密鍵をバックアップしてから、もう一度「この鍵を登録する」を押してください。登録されていなければ登録し、登録されていれば「このアカウントはすでに登録されています。」と表示します。"
    AccountRegistered -> "アカウントを登録しました"
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
      "このページを再読み込みしたり、戻るボタンで戻ってきたりすると、フォームが再送信され、鍵がもう一度表示され、表示したことが再びログに記録されることがあります。"
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

/// 権限のチップに出す、よく使う kind の名前。表に無い kind は `None` で、呼び出し側が番号を出す。
fn kind_name(language: Language, kind: Int) -> Option(String) {
  case language, kind {
    English, 0 -> Some("profile")
    English, 1 -> Some("post")
    English, 3 -> Some("follow list")
    English, 6 -> Some("repost")
    English, 7 -> Some("reaction")
    English, 10_002 -> Some("relay list")
    Japanese, 0 -> Some("プロフィール")
    Japanese, 1 -> Some("投稿")
    Japanese, 3 -> Some("フォロー")
    Japanese, 6 -> Some("リポスト")
    Japanese, 7 -> Some("リアクション")
    Japanese, 10_002 -> Some("リレーリスト")
    _, _ -> None
  }
}
