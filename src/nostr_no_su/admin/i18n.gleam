//// 管理 UI の表示の言語と、言語ごとの文言。
////
//// 文言は `Message` の値で表し、`text` が表示の言語の文字列にする。言語ごとの関数
//// （`english`、`japanese`）は、どれも `Message` のすべての値を網羅する `case` なので、
//// どちらかの言語の訳が無いとビルドが通らない。値を埋め込む文言（経過秒、件数、ラベルの
//// 上限）は値を持つ構築子にし、語順と記号を含めて言語ごとに文全体を返す。
////
//// 言語を足すときは、`Language` に構築子を、`languages` に値を足し、コンパイラーが示す
//// `case`（`code`、`native_name`、`text`、`lead`、`sentence_gap`、`i18n_test` の
//// `language_count`）に枝を足す。
////
//// 管理 UI の外（バンカー、アカウントストア、設定、プラグイン）から英語の文字列で届く
//// 理由は訳さず、`Untranslated` として英語のまま出す。設定、DB、プラグインの理由はログにも
//// 同じ文が出るが、バンカーのアクターの案内（`accounts are being loaded` など）は出ない。
////
//// クラス名はここに書かない。`assets/admin.css` がこのモジュールを Tailwind の走査から
//// 外しているので、書いても CSS に出力されない。

import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
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
      })
  }
}

/// 強調した文とそれに続く文の間に置く文字。英語は空白で区切り、日本語は区切らない。
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
  // ダッシュボード
  Dashboard
  PendingConnections
  NoPendingConnections
  Signer
  Client
  Age
  AgeSeconds(seconds: Int)
  Approve
  Deny
  Accounts
  AddAccount
  NoAccounts
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
  RoleColumn
  UrlColumn
  StateColumn
  MonitorRole
  BunkerRole
  RelayConnected
  RelayDisconnected
  NoRelays
  Plugins
  NameColumn
  PluginRunning
  PluginOverloaded
  PluginDisabled
  ReenablePlugin
  PluginUnavailable
  Dropped(count: Int)
  DroppedAfterReason(count: Int)
  NoPlugins
  // 承認ページと通知ページ
  ApproveConnection
  Approved
  Denied
  ApprovedCloseWindow
  DeniedCloseWindow
  NotFound
  ChangeNotConfirmed
  AccountsNotAvailable
  // アカウントの登録画面
  ImportPrivateKey
  ImportDescription
  PrivateKeyNsec
  Label
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
  ShowPrivateKeyDescription
  AdminPassword
  // 秘密鍵の表示ページ
  PrivateKey
  CloseTabAfterCopying
  ResendNotice
  // 管理 UI が検査して返す理由
  IncorrectPassword
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
    Dashboard -> "Dashboard"
    PendingConnections -> "Pending connections"
    NoPendingConnections -> "No pending connections."
    Signer -> "Signer"
    Client -> "Client"
    Age -> "Age"
    AgeSeconds(seconds:) -> int.to_string(seconds) <> "s"
    Approve -> "Approve"
    Deny -> "Deny"
    Accounts -> "Accounts"
    AddAccount -> "Add account"
    NoAccounts -> "No accounts registered."
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
    RoleColumn -> "Role"
    UrlColumn -> "URL"
    StateColumn -> "State"
    MonitorRole -> "monitor"
    BunkerRole -> "bunker"
    RelayConnected -> "connected"
    RelayDisconnected -> "disconnected"
    NoRelays -> "No relays configured."
    Plugins -> "Plugins"
    NameColumn -> "Name"
    PluginRunning -> "running"
    PluginOverloaded -> "overloaded"
    PluginDisabled -> "disabled"
    ReenablePlugin -> "Re-enable"
    PluginUnavailable -> "unavailable"
    Dropped(count:) -> "(dropped " <> int.to_string(count) <> ")"
    DroppedAfterReason(count:) -> " (dropped " <> int.to_string(count) <> ")"
    NoPlugins -> "No plugins enabled."
    ApproveConnection -> "Approve connection"
    Approved -> "Approved"
    Denied -> "Denied"
    ApprovedCloseWindow -> "Approved. You can close this window."
    DeniedCloseWindow -> "Denied. You can close this window."
    NotFound -> "Not found"
    ChangeNotConfirmed -> "Change not confirmed"
    AccountsNotAvailable -> "Accounts are not available"
    ImportPrivateKey -> "Import a private key"
    ImportDescription ->
      "Paste the private key (nsec) of the account. It is shown once after registration, and afterwards only when you re-enter the admin password. If the browser offers to save it as a password, decline."
    PrivateKeyNsec -> "Private key (nsec)"
    Label -> "Label"
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
    ShowPrivateKeyDescription ->
      "Re-enter the admin password to show the private key. Showing it is logged with the npub."
    AdminPassword -> "Admin password"
    PrivateKey -> "Private key"
    CloseTabAfterCopying -> "Close this tab after copying the key."
    ResendNotice ->
      "Reloading this page or coming back to it with the back button can resend the form, which shows the key again and logs it again."
    IncorrectPassword -> "incorrect password"
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
    Dashboard -> "ダッシュボード"
    PendingConnections -> "承認待ちの接続"
    NoPendingConnections -> "承認待ちの接続はありません。"
    Signer -> "署名者"
    Client -> "クライアント"
    Age -> "経過時間"
    AgeSeconds(seconds:) -> int.to_string(seconds) <> " 秒"
    Approve -> "承認する"
    Deny -> "拒否する"
    Accounts -> "アカウント"
    AddAccount -> "アカウントを追加"
    NoAccounts -> "登録されたアカウントはありません。"
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
    RoleColumn -> "用途"
    UrlColumn -> "URL"
    StateColumn -> "状態"
    MonitorRole -> "監視"
    BunkerRole -> "バンカー"
    RelayConnected -> "接続中"
    RelayDisconnected -> "未接続"
    NoRelays -> "リレーが設定されていません。"
    Plugins -> "プラグイン"
    NameColumn -> "名前"
    PluginRunning -> "動作中"
    PluginOverloaded -> "過負荷"
    PluginDisabled -> "無効"
    ReenablePlugin -> "再有効化"
    PluginUnavailable -> "応答なし"
    Dropped(count:) -> "（破棄 " <> int.to_string(count) <> " 件）"
    DroppedAfterReason(count:) -> "（破棄 " <> int.to_string(count) <> " 件）"
    NoPlugins -> "有効なプラグインはありません。"
    ApproveConnection -> "接続を承認"
    Approved -> "承認しました"
    Denied -> "拒否しました"
    ApprovedCloseWindow -> "承認しました。このウィンドウは閉じてかまいません。"
    DeniedCloseWindow -> "拒否しました。このウィンドウは閉じてかまいません。"
    NotFound -> "見つかりません"
    ChangeNotConfirmed -> "変更を確認できませんでした"
    AccountsNotAvailable -> "アカウントを利用できません"
    ImportPrivateKey -> "既存の秘密鍵を登録"
    ImportDescription ->
      "アカウントの秘密鍵（nsec）を貼り付けてください。秘密鍵は登録の直後に 1 回だけ表示し、その後は管理パスワードを入力し直したときにだけ表示します。ブラウザーがパスワードとして保存するよう勧めても、保存しないでください。"
    PrivateKeyNsec -> "秘密鍵（nsec）"
    Label -> "ラベル"
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
    ShowPrivateKeyDescription ->
      "秘密鍵を表示するには、管理パスワードを入力し直してください。表示したことは npub とともにログに記録します。"
    AdminPassword -> "管理パスワード"
    PrivateKey -> "秘密鍵"
    CloseTabAfterCopying -> "鍵をコピーしたら、このタブを閉じてください。"
    ResendNotice ->
      "このページを再読み込みしたり、戻るボタンで戻ってきたりすると、フォームが再送信され、鍵がもう一度表示されてログにも再び記録されることがあります。"
    IncorrectPassword -> "管理パスワードが違います。"
    LabelTooLong(max:) -> "ラベルは " <> int.to_string(max) <> " 文字以内にしてください。"
    LabelHasControlCharacters -> "ラベルに制御文字は使えません。"
    InvalidNsec(error) -> japanese_nip19(error)
    PrivateKeyOutOfRange -> "秘密鍵が有効な範囲にありません。"
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
