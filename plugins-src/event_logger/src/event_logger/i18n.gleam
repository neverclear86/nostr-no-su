//// 管理 UI のページに出す文言の日英。
//// 表示の言語は、本体が `plugin_pages/2` と `plugin_page_content/3` の最後の引数で渡す言語のコード（`docs/plugin-api.md` 第 13.1 節）から `from_code` で決める。
//// 文言は `Message` の値で表し、`text` が表示の言語の文字列にする。言語ごとの関数（`english`、`japanese`）は、どれも `Message` のすべての値を網羅する `case` なので、どちらかの言語の訳が無いとビルドが通らない。値を埋め込む文言は値を持つ構築子にし、言語ごとに文全体を返す。
//// `plugin_page_action/3` には表示の言語が渡らないので、その拒否の理由はここに置かず英語のまま返す。

import gleam/int

/// ページを表示する言語。
pub type Language {
  English
  Japanese
}

/// ページに出す文言。
pub type Message {
  TimelineTitle
  SettingsTitle
  MonitoredAccountsTitle
  ConfigurationTitle
  RuntimeTitle
  ErrorTitle
  UnknownPage
  StoreDidNotAnswer
  StoredOnlyForChecked
  AllCheckedMeansEveryAccount
  Save
  DatabaseUrlTerm
  PoolSizeTerm
  MaxQueueLengthTerm
  NotConfigured
  InvalidDatabaseUrl
  ConfigurationNote
  ProcessColumn
  RegisteredNameColumn
  StatusColumn
  PendingMessagesColumn
  Running
  NotRunning
  ProcessNotRunningWarning
  ConnectionPool
  StoreActor
  TagsSummary(count: Int)
  ContentSummary(bytes: Int)
  AccountTerm
  PoolNotRunning
  EventsUnreadable(detail: String)
}

/// 言語のコードの言語。`ja` は日本語、それ以外（`en`、知らないコード、binary でない値）は英語にする。
pub fn from_code(code: String) -> Language {
  case code {
    "ja" -> Japanese
    _ -> English
  }
}

/// `message` の `language` の文字列。
pub fn text(language: Language, message: Message) -> String {
  case language {
    English -> english(message)
    Japanese -> japanese(message)
  }
}

/// 英語の文言。
fn english(message: Message) -> String {
  case message {
    TimelineTitle -> "Timeline"
    SettingsTitle -> "Settings"
    MonitoredAccountsTitle -> "Monitored accounts"
    ConfigurationTitle -> "Configuration"
    RuntimeTitle -> "Runtime"
    ErrorTitle -> "Error"
    UnknownPage -> "unknown page"
    StoreDidNotAnswer ->
      "monitored accounts are unavailable: the store actor did not answer"
    StoredOnlyForChecked ->
      "Events are stored only for the accounts checked here."
    AllCheckedMeansEveryAccount ->
      "All accounts checked means every account, including ones you register later."
    Save -> "Save"
    DatabaseUrlTerm -> "database URL"
    PoolSizeTerm -> "pool size"
    MaxQueueLengthTerm -> "max queue length"
    NotConfigured -> "not configured"
    InvalidDatabaseUrl -> "database URL is not a valid postgres URL"
    ConfigurationNote ->
      "This plugin strips the password before showing the URL above. The database is the host's DATABASE_URL unless PLUGIN_EVENT_LOGGER_DATABASE_URL is set, and cannot be changed from this page. Only the accounts to store events for are chosen above."
    ProcessColumn -> "Process"
    RegisteredNameColumn -> "Registered name"
    StatusColumn -> "Status"
    PendingMessagesColumn -> "Pending messages"
    Running -> "running"
    NotRunning -> "not running"
    ProcessNotRunningWarning ->
      "A process shown as not running may be restarting or have been given up on; see plugin-api.md section 5.4."
    ConnectionPool -> "connection pool"
    StoreActor -> "store actor"
    TagsSummary(count:) -> "tags (" <> int.to_string(count) <> ")"
    ContentSummary(bytes:) -> "content (" <> int.to_string(bytes) <> " bytes)"
    AccountTerm -> "account"
    PoolNotRunning -> "connection pool is not running"
    EventsUnreadable(detail:) -> "could not read stored events: " <> detail
  }
}

/// 日本語の文言。
fn japanese(message: Message) -> String {
  case message {
    TimelineTitle -> "タイムライン"
    SettingsTitle -> "設定"
    MonitoredAccountsTitle -> "保存するアカウント"
    ConfigurationTitle -> "接続先と上限"
    RuntimeTitle -> "プロセス"
    ErrorTitle -> "エラー"
    UnknownPage -> "このページはありません。"
    StoreDidNotAnswer -> "保存アクターが応答しないため、保存するアカウントを表示できません。"
    StoredOnlyForChecked -> "チェックしたアカウントのイベントだけを保存します。"
    AllCheckedMeansEveryAccount -> "すべてにチェックすると、あとで登録するアカウントも含めて全アカウントが対象になります。"
    Save -> "保存する"
    DatabaseUrlTerm -> "接続先の URL"
    PoolSizeTerm -> "接続数"
    MaxQueueLengthTerm -> "保存待ちの上限"
    NotConfigured -> "未設定"
    InvalidDatabaseUrl -> "接続先の URL を postgres の URL として読めません。"
    ConfigurationNote ->
      "上の URL は、このプラグインがパスワードを取り除いて表示しています。接続先は本体の DATABASE_URL で、PLUGIN_EVENT_LOGGER_DATABASE_URL を設定したときはそちらになり、このページからは変えられません。このページで選べるのは、イベントを保存するアカウントだけです。"
    ProcessColumn -> "プロセス"
    RegisteredNameColumn -> "登録名"
    StatusColumn -> "状態"
    PendingMessagesColumn -> "未処理のメッセージ"
    Running -> "動作中"
    NotRunning -> "停止中"
    ProcessNotRunningWarning ->
      "停止中のプロセスは、再起動の途中か、再起動を諦められた状態です。plugin-api.md の第 5.4 節を参照してください。"
    ConnectionPool -> "接続プール"
    StoreActor -> "保存アクター"
    TagsSummary(count:) -> "tags（" <> int.to_string(count) <> " 件）"
    ContentSummary(bytes:) -> "content（" <> int.to_string(bytes) <> " バイト）"
    AccountTerm -> "アカウント"
    PoolNotRunning -> "接続プールが動いていません。"
    EventsUnreadable(detail:) -> "保存済みのイベントを読めませんでした: " <> detail
  }
}
