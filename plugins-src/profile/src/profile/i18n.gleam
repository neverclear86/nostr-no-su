//// 管理 UI のページの表示の言語と、言語ごとの文言。
//// 文言は `Message` の値で表し、`text` が表示の言語の文字列にする。言語ごとの
//// 関数（`english`、`japanese`）は、どれも `Message` のすべての値を網羅する
//// `case` なので、どちらかの言語の訳が無いとビルドが通らない。値を埋め込む文言
//// （理由、アカウントのラベル）は値を持つ構築子にし、語順と記号を含めて言語
//// ごとに文全体を返す。
//// 本体や取得から英語の 1 文で届く理由は訳さず、そのまま文に埋め込む。`npub` と
//// フォームの 8 欄の補足（kind 0 のキー名）は識別子なので、ここに置かずに
//// どの言語でも同じ文字で出す。

/// ページを表示する言語。
pub type Language {
  English
  Japanese
}

/// 本体が `plugin_pages/2` と `plugin_page_content/3` の最後の引数で渡す表示の
/// 言語のコード（`docs/plugin-api.md` 第 13.1 節）の言語。`ja` は日本語、それ
/// 以外は英語にする（知らない言語のコードには英語で返す約束のため）。
pub fn from_code(code: String) -> Language {
  case code {
    "ja" -> Japanese
    _ -> English
  }
}

/// フォームの欄（kind 0 の 8 項目）。欄のラベルの文言を選び、`profile/page` では
/// キー名と値を引く軸にもなる。
pub type Field {
  Name
  DisplayName
  About
  Picture
  Banner
  Nip05
  Website
  Lud16
}

/// ページに出す文言。
pub type Message {
  /// ページの表示名（タブ）と、登録アカウントが無いときの節の見出し。
  PageTitle
  /// 登録アカウントが無いときの案内。
  NoAccounts
  /// kind 0 の取得に失敗したときの `alert`。`reason` は英語の理由の 1 文。
  FetchFailed(reason: String)
  /// リレーに kind 0 が無かったときの `alert`。
  NoProfileEvent
  /// 最新の kind 0 の `content` が JSON のオブジェクトでないときの `alert`。
  ContentNotObject
  /// `pairs` の更新の時刻の項の見出し。
  UpdatedTerm
  /// `picture` の画像の前の `note`。
  PictureNote
  /// `banner` の画像の前の `note`。
  BannerNote
  /// `picture` の画像の代替テキスト。`label` はアカウントのラベル。
  PictureAlt(label: String)
  /// `banner` の画像の代替テキスト。`label` はアカウントのラベル。
  BannerAlt(label: String)
  /// フォームの欄のラベル（人の読める名前）。
  FieldLabel(field: Field)
  /// フォームの送信ボタン。
  SaveButton
  /// 更新の送信に成功したときの `alert`。
  ProfileUpdated
  /// 更新の送信に失敗したときの `alert`。`reason` は英語の理由の 1 文。
  UpdateFailed(reason: String)
}

/// `message` を `language` の文字列にする。
pub fn text(language: Language, message: Message) -> String {
  case language {
    English -> english(message)
    Japanese -> japanese(message)
  }
}

/// 英語の文言。
fn english(message: Message) -> String {
  case message {
    PageTitle -> "Profile"
    NoAccounts ->
      "No account is registered. Register an account first, then reload this page."
    FetchFailed(reason:) ->
      "Could not fetch the profile from the relays (reason: "
      <> reason
      <> "). The edit form is not shown because the current profile is unknown."
    NoProfileEvent ->
      "No kind 0 event was found on the relays. Sending this form publishes a new profile with only the fields below."
    ContentNotObject ->
      "The latest kind 0 event has a content that is not a JSON object."
    UpdatedTerm -> "updated"
    PictureNote -> "Picture"
    BannerNote -> "Banner"
    PictureAlt(label:) -> "Picture of " <> label
    BannerAlt(label:) -> "Banner of " <> label
    FieldLabel(field:) -> english_field_label(field)
    SaveButton -> "Save"
    ProfileUpdated -> "Profile updated."
    UpdateFailed(reason:) -> "Could not update the profile: " <> reason
  }
}

/// 日本語の文言。
fn japanese(message: Message) -> String {
  case message {
    PageTitle -> "プロフィール"
    NoAccounts -> "アカウントが登録されていません。先にアカウントを登録してから、このページを開き直してください。"
    FetchFailed(reason:) ->
      "リレーからプロフィールを取得できませんでした（理由: "
      <> reason
      <> "）。現在のプロフィールが分からないため、編集のフォームは出しません。"
    NoProfileEvent ->
      "リレーに kind 0 のイベントがありませんでした。このフォームを送ると、下の項目だけを持つ新しいプロフィールを送信します。"
    ContentNotObject -> "最新の kind 0 のイベントの content が JSON のオブジェクトではありません。"
    UpdatedTerm -> "更新日時"
    PictureNote -> "アイコン画像"
    BannerNote -> "バナー画像"
    PictureAlt(label:) -> label <> " のアイコン画像"
    BannerAlt(label:) -> label <> " のバナー画像"
    FieldLabel(field:) -> japanese_field_label(field)
    SaveButton -> "保存する"
    ProfileUpdated -> "プロフィールを更新しました。"
    UpdateFailed(reason:) -> "プロフィールを更新できませんでした（理由: " <> reason <> "）。"
  }
}

/// 英語の欄のラベル。
fn english_field_label(field: Field) -> String {
  case field {
    Name -> "Name"
    DisplayName -> "Display name"
    About -> "About"
    Picture -> "Icon image URL"
    Banner -> "Banner image URL"
    Nip05 -> "Verified identifier (NIP-05)"
    Website -> "Website"
    Lud16 -> "Lightning address"
  }
}

/// 日本語の欄のラベル。
fn japanese_field_label(field: Field) -> String {
  case field {
    Name -> "名前"
    DisplayName -> "表示名"
    About -> "自己紹介"
    Picture -> "アイコンの画像の URL"
    Banner -> "バナーの画像の URL"
    Nip05 -> "認証の識別子（NIP-05）"
    Website -> "ウェブサイト"
    Lud16 -> "Lightning アドレス"
  }
}
