//// 管理 UI のアカウントのページの描画（`admin/account_pages`）の単体テスト。

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/element
import nostr_no_su/admin/account_pages
import nostr_no_su/admin/dashboard
import nostr_no_su/admin/i18n
import nostr_no_su/admin/view
import nostr_no_su/bunker/vault
import nostr_no_su/nostr/nip19
import support/account_actions

/// HTML として解釈されうるラベル。
const hostile = "<script>\"x\"</script>"

/// `hostile` をエスケープした表記。
const escaped = "&lt;script&gt;&quot;x&quot;&lt;/script&gt;"

/// 実寸の npub（63 文字）。`view.shorten` が省略することを検査できるよう、`"npub1example"`
/// のような短い値は使わない。
const example_npub = "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"

/// 指定したラベルを持つアカウントの行。
fn row(label: String) -> dashboard.AccountRow {
  dashboard.AccountRow(
    signer: "abcd",
    npub: example_npub,
    label: label,
    uri: "bunker://abcd?relay=x&secret=s",
    auth_uri: "bunker://abcd?relay=x",
  )
}

/// 指定したラベルを持つ、読み込みで飛ばされた行（`MalformedPubkey` 以外）。
fn skipped_row(label: String) -> dashboard.SkippedRow {
  dashboard.SkippedRow(
    pubkey: "abcd",
    npub: example_npub,
    label: label,
    reason: vault.UndecryptablePrivateKey,
  )
}

/// ラベルは、完了ページ、再表示のページ、操作のページ、入力の誤りで戻したフォームの
/// 欄のどれでもエスケープして出す。
pub fn account_pages_escape_the_label_test() {
  let pages = [
    account_pages.registered_page(
      i18n.English,
      view.System,
      "npub1example",
      hostile,
      "nsec1example",
    ),
    account_pages.private_key_page(
      i18n.English,
      view.System,
      row(hostile),
      "nsec1example",
    ),
    account_pages.new_account_page(i18n.English, view.System, hostile, None),
    account_pages.generated_key_page(
      i18n.English,
      view.System,
      example_npub,
      "nsec1example",
      hostile,
      None,
    ),
    account_pages.account_action_page(
      i18n.English,
      view.System,
      row("main"),
      dashboard.EditLabel,
      Some(hostile),
      None,
    ),
    account_pages.unreadable_delete_page(
      i18n.English,
      view.System,
      skipped_row(hostile),
      None,
    ),
    ..list.map(account_actions.with_form, account_pages.account_action_page(
      i18n.English,
      view.System,
      row(hostile),
      _,
      None,
      None,
    ))
  ]
  use page <- list.each(pages)
  assert string.contains(page, escaped)
  assert !string.contains(page, hostile)
}

/// フォームの上に出す理由はエスケープして出す。英語のまま届いた理由には `lang="en"` を
/// 付ける。
pub fn error_reasons_are_escaped_test() {
  let reason = Some(i18n.Untranslated(hostile))
  let pages = [
    account_pages.new_account_page(i18n.English, view.System, "", reason),
    account_pages.account_action_page(
      i18n.English,
      view.System,
      row("main"),
      dashboard.EditLabel,
      None,
      reason,
    ),
    account_pages.unreadable_delete_page(
      i18n.English,
      view.System,
      skipped_row("main"),
      reason,
    ),
  ]
  use page <- list.each(pages)
  assert string.contains(
    page,
    "<div class=\"alert alert-soft alert-error text-base-content\" role=\"alert\">"
      <> element.to_string(view.tone_icon(view.Failure))
      <> "<span class=\"wrap-anywhere\"><span lang=\"en\">"
      <> escaped
      <> "</span></span></div>",
  )
  assert !string.contains(page, hostile)
}

/// 操作のページの欄は、`label` が `None` なら一覧から得た保存済みのラベルを、`Some` なら
/// 渡した値を入れる。カードの上の要約はどちらでも保存済みのまま。
pub fn edit_label_page_uses_the_given_label_test() {
  let saved = row("saved")
  let unset =
    account_pages.account_action_page(
      i18n.English,
      view.System,
      saved,
      dashboard.EditLabel,
      None,
      None,
    )
  assert string.contains(unset, "value=\"saved\"")
  assert string.contains(
    unset,
    "<p class=\"font-semibold break-words\">saved</p>",
  )
  let overridden =
    account_pages.account_action_page(
      i18n.English,
      view.System,
      saved,
      dashboard.EditLabel,
      Some("sent"),
      None,
    )
  assert string.contains(overridden, "value=\"sent\"")
  assert string.contains(
    overridden,
    "<p class=\"font-semibold break-words\">saved</p>",
  )
}

/// 登録の完了ページは、対象のアカウントをラベルと省略した npub で示す。
pub fn registered_page_shows_the_shortened_npub_test() {
  let page =
    account_pages.registered_page(
      i18n.English,
      view.System,
      example_npub,
      "main",
      "nsec1example",
    )
  assert string.contains(
    page,
    "<p class=\"font-semibold break-words\">main</p>",
  )
  assert string.contains(page, view.shorten(example_npub))
}

/// 秘密鍵の表示ページは、対象のアカウントをラベルと省略した npub で示す。
pub fn private_key_page_shows_the_shortened_npub_test() {
  let page =
    account_pages.private_key_page(
      i18n.English,
      view.System,
      row("main"),
      "nsec1example",
    )
  assert string.contains(
    page,
    "<p class=\"font-semibold break-words\">main</p>",
  )
  assert string.contains(page, view.shorten(example_npub))
}

/// 生成した鍵の確認ページは、生成した鍵の省略した npub を出す。
pub fn generated_key_page_shows_the_shortened_npub_test() {
  let page =
    account_pages.generated_key_page(
      i18n.English,
      view.System,
      example_npub,
      "nsec1example",
      "",
      None,
    )
  assert string.contains(page, view.shorten(example_npub))
}

/// アカウント 1 件への操作の確認ページと、読み込めなかった行の削除の確認ページは、
/// 対象のアカウントをラベルと省略した npub で示す。
pub fn account_action_pages_show_the_shortened_npub_test() {
  use action <- list.each(account_actions.with_form)
  let page =
    account_pages.account_action_page(
      i18n.English,
      view.System,
      row("main"),
      action,
      None,
      None,
    )
  assert string.contains(
    page,
    "<p class=\"font-semibold break-words\">main</p>",
  )
  assert string.contains(page, view.shorten(example_npub))
  let unreadable_page =
    account_pages.unreadable_delete_page(
      i18n.English,
      view.System,
      skipped_row("main"),
      None,
    )
  assert string.contains(
    unreadable_page,
    "<p class=\"font-semibold break-words\">main</p>",
  )
  assert string.contains(unreadable_page, view.shorten(example_npub))
}

/// アカウントの追加の画面では、既存の秘密鍵の登録だけが主のボタンで、生成は枠の
/// ボタンになる。
pub fn generate_is_not_a_primary_button_test() {
  let page = account_pages.new_account_page(i18n.English, view.System, "", None)
  let occurrences =
    { string.split(page, "btn btn-primary self-start") |> list.length } - 1
  assert occurrences == 1
}

/// コピーのボタンは値を持たず、スクリプトの `copy` の処理を名前で指す。値は `name` の無い読み取り
/// 専用の欄に、エスケープして入る。コピーの欄は、処理が頼る形（欄はボタンの直前の兄弟、
/// 囲みはボタンの親の親、`role="status"` は囲みの直下）で出す。形が崩れてもコピーはできて
/// しまい、完了の表示と読み上げだけが消えるので、欄全体を照合する。クリップボードに書けない
/// ときの案内は、完了の表示と同じ `role="status"` の中に、見えない状態で出す。
pub fn copy_button_reads_the_value_from_the_page_test() {
  let page =
    account_pages.private_key_page(
      i18n.English,
      view.System,
      row("main"),
      "nsec1first\"",
    )
  assert string.contains(
    page,
    "<div class=\"fieldset group\"><span class=\"fieldset-legend\">Private key (nsec)</span><div class=\"flex items-center gap-1\"><input aria-label=\"Private key (nsec)\" class=\"input w-full min-w-0 font-mono text-xs border-base-content/60\" readonly type=\"text\" value=\"nsec1first&quot;\">"
      <> element.to_string(view.copy_button("Copy"))
      <> "</div><span class=\"sr-only group-data-selected:not-sr-only\" role=\"status\">",
  )
  assert string.contains(
    page,
    "</button></div><span class=\"sr-only group-data-selected:not-sr-only\" role=\"status\"><span class=\"hidden group-data-copied:inline\">Copied</span><span class=\"hidden group-data-selected:inline text-sm\">Selected. Press Ctrl+C (⌘C on macOS) to copy.</span></span></div>",
  )
}

/// どのページも表示の言語を `<html lang>` に出す。テーマと言語の切り替えを出さないのは、
/// 秘密鍵を描画する 3 つのページだけで、そのページでもナビゲーションバーの右端の枠は残す。
pub fn only_pages_with_a_private_key_hide_the_switches_test() {
  use language <- list.each(i18n.languages)
  let html_lang = "<html lang=\"" <> i18n.code(language) <> "\">"
  let hidden = [
    account_pages.generated_key_page(
      language,
      view.System,
      example_npub,
      "nsec1example",
      "",
      None,
    ),
    account_pages.registered_page(
      language,
      view.System,
      "npub1example",
      "main",
      "nsec1example",
    ),
    account_pages.private_key_page(
      language,
      view.System,
      row("main"),
      "nsec1example",
    ),
  ]
  let shown = [
    account_pages.new_account_page(language, view.System, "", None),
    account_pages.unreadable_delete_page(
      language,
      view.System,
      skipped_row("main"),
      None,
    ),
    ..list.map(account_actions.with_form, account_pages.account_action_page(
      language,
      view.System,
      row("main"),
      _,
      None,
      None,
    ))
  ]
  list.each(hidden, fn(page) {
    assert string.contains(page, html_lang)
    assert string.contains(
      page,
      "<div class=\"navbar-end w-auto gap-2\"></div>",
    )
    assert !string.contains(page, "action=\"/theme\"")
    assert !string.contains(page, "action=\"/language\"")
  })
  list.each(shown, fn(page) {
    assert string.contains(page, html_lang)
    assert string.contains(page, "action=\"/theme\"")
    assert string.contains(page, "action=\"/language\"")
  })
}

/// 言語を切り替えた後は、登録画面と操作のページを GET で開き直す。失敗の理由を出した
/// POST の応答でも同じである。
pub fn language_switch_returns_to_the_page_test() {
  let reason = Some(i18n.Untranslated("account is not registered"))
  assert string.contains(
    account_pages.new_account_page(i18n.English, view.System, "", reason),
    "<input name=\"return\" type=\"hidden\" value=\"/accounts/new\">",
  )
  list.each(account_actions.with_form, fn(action) {
    assert string.contains(
      account_pages.account_action_page(
        i18n.English,
        view.System,
        row("main"),
        action,
        None,
        reason,
      ),
      "<input name=\"return\" type=\"hidden\" value=\""
        <> dashboard.account_action_path("abcd", action)
        <> "\">",
    )
  })
  assert string.contains(
    account_pages.unreadable_delete_page(
      i18n.English,
      view.System,
      skipped_row("main"),
      reason,
    ),
    "<input name=\"return\" type=\"hidden\" value=\""
      <> dashboard.account_action_path("abcd", dashboard.DeleteAccount)
      <> "\">",
  )
}

/// 日本語のページでは、管理 UI が訳す理由を日本語で出し、英語のまま届いた理由は前置きの
/// 後に `lang="en"` で出す。英語のページには前置きを置かない。
pub fn japanese_pages_translate_reasons_test() {
  let invalid =
    account_pages.new_account_page(
      i18n.Japanese,
      view.System,
      "",
      Some(i18n.Translated(i18n.InvalidNsec(nip19.InvalidChecksum))),
    )
  assert string.contains(
    invalid,
    "<span class=\"wrap-anywhere\">bech32 のチェックサムが一致しません。</span>",
  )
  let registered = Some(i18n.Untranslated("account is already registered"))
  assert string.contains(
    account_pages.new_account_page(i18n.Japanese, view.System, "", registered),
    "<span class=\"wrap-anywhere\">登録できませんでした。<span lang=\"en\">account is already registered</span></span>",
  )
  assert string.contains(
    account_pages.new_account_page(i18n.English, view.System, "", registered),
    "<span class=\"wrap-anywhere\"><span lang=\"en\">account is already registered</span></span>",
  )
  assert string.contains(
    account_pages.account_action_page(
      i18n.Japanese,
      view.System,
      row("main"),
      dashboard.RevealPrivateKey,
      None,
      Some(i18n.Translated(i18n.IncorrectPassword)),
    ),
    "<span class=\"wrap-anywhere\">管理パスワードが違います。</span>",
  )
}

/// 強調した文と続く文の間は、英語では空白で区切り、日本語では区切らない。操作の見出しと
/// 送信のボタンの文言は、日本語では別の文言になる。
pub fn japanese_pages_follow_the_japanese_style_test() {
  assert string.contains(
    account_pages.generated_key_page(
      i18n.English,
      view.System,
      example_npub,
      "nsec1example",
      "",
      None,
    ),
    "<strong>Back up this private key now.</strong> The account is not registered",
  )
  assert string.contains(
    account_pages.generated_key_page(
      i18n.Japanese,
      view.System,
      example_npub,
      "nsec1example",
      "",
      None,
    ),
    "<strong>この秘密鍵を今すぐバックアップしてください。</strong>「この鍵を登録する」を押すまで",
  )
  let delete =
    account_pages.account_action_page(
      i18n.Japanese,
      view.System,
      row("main"),
      dashboard.DeleteAccount,
      None,
      None,
    )
  assert string.contains(
    delete,
    "<h1 class=\"text-2xl font-bold\">アカウントを削除</h1>",
  )
  assert string.contains(delete, ">アカウントを削除する</button>")
}

/// 日本語の確認ページでは、英語のまま届いた 409 の理由に前置きを付け、503 と 202 の
/// 案内の文と理由の間を区切らない。
pub fn japanese_generated_key_page_explains_the_failure_test() {
  let render = fn(problem) {
    account_pages.generated_key_page(
      i18n.Japanese,
      view.System,
      example_npub,
      "nsec1example",
      "main",
      Some(problem),
    )
  }
  assert string.contains(
    render(
      account_pages.NotApplied(i18n.Untranslated(
        "account is already registered",
      )),
    ),
    "<span class=\"wrap-anywhere\">登録できませんでした。<span lang=\"en\">account is already registered</span></span>",
  )
  assert string.contains(
    render(account_pages.NotAccepted("accounts are not loaded yet")),
    "もう一度「この鍵を登録する」を押してください。<span lang=\"en\">accounts are not loaded yet</span>",
  )
  assert string.contains(
    render(account_pages.NotConfirmed(i18n.StoreDidNotConfirm)),
    "と表示します。データベースが変更を確定しませんでした。",
  )
}

/// 登録画面の nsec の欄は、貼り付けの説明（`ImportDescription`）を ⓘ で開く補足に畳み、
/// 欄の `aria-describedby` から指す。説明はフォームの前の段落には出さない。
pub fn nsec_field_folds_the_import_description_test() {
  use language <- list.each(i18n.languages)
  let text = i18n.text(language, _)
  let page = account_pages.new_account_page(language, view.System, "", None)
  assert string.contains(
    page,
    "<input aria-describedby=\"nsec-hint\" aria-label=\""
      <> text(i18n.PrivateKeyNsec)
      <> "\" autocomplete=\"new-password\"",
  )
  assert string.contains(page, "popovertarget=\"nsec-hint\"")
  assert string.contains(
    page,
    "id=\"nsec-hint\" popover=\"auto\">"
      <> text(i18n.ImportDescription)
      <> "</p>",
  )
  assert !string.contains(
    page,
    "<p class=\"text-sm\">" <> text(i18n.ImportDescription),
  )
}

/// 警告（生成した鍵と登録の完了のバックアップ、秘密鍵の再送の注意、削除の説明、入力の
/// 誤り）は畳まずに出す。登録画面で畳むのは nsec の欄の補足 1 つだけである。
pub fn account_warnings_are_not_folded_test() {
  use language <- list.each(i18n.languages)
  let text = i18n.text(language, _)
  let strong = fn(message) { "<strong>" <> text(message) <> "</strong>" }
  let warnings = [
    #(
      account_pages.generated_key_page(
        language,
        view.System,
        example_npub,
        "nsec1example",
        "",
        None,
      ),
      strong(i18n.BackUpNow),
    ),
    #(
      account_pages.registered_page(
        language,
        view.System,
        "npub1example",
        "main",
        "nsec1example",
      ),
      strong(i18n.BackUpIfNotAlready),
    ),
    #(
      account_pages.private_key_page(
        language,
        view.System,
        row("main"),
        "nsec1example",
      ),
      text(i18n.ResendNotice),
    ),
    #(
      account_pages.account_action_page(
        language,
        view.System,
        row("main"),
        dashboard.DeleteAccount,
        None,
        None,
      ),
      strong(i18n.DeleteWarning),
    ),
    #(
      account_pages.unreadable_delete_page(
        language,
        view.System,
        skipped_row("main"),
        None,
      ),
      strong(i18n.DeleteUnreadableWarning),
    ),
  ]
  list.each(warnings, fn(pair) {
    let #(page, warning) = pair
    assert string.contains(page, warning)
    assert !string.contains(page, "popover")
    assert !string.contains(page, "<details")
  })
  let rejected =
    account_pages.new_account_page(
      language,
      view.System,
      "typed",
      Some(i18n.Translated(i18n.LabelTooLong(max: 100))),
    )
  assert string.contains(rejected, "role=\"alert\"")
  assert list.length(string.split(rejected, "popover=\"auto\"")) == 2
  assert !string.contains(rejected, "<details")
}

/// ページのカードの中身は、ページの枠を持たないフォームの関数の出力そのものである。
pub fn account_forms_are_the_card_content_test() {
  use language <- list.each(i18n.languages)
  let html = fn(elements) {
    elements |> list.map(element.to_string) |> string.concat
  }
  let new_account =
    account_pages.new_account_page(language, view.System, "typed", None)
  assert string.contains(
    new_account,
    html(dashboard.import_form(language, "typed")),
  )
  assert string.contains(new_account, html(dashboard.generate_form(language)))
  list.each(account_actions.with_form, fn(action) {
    let page =
      account_pages.account_action_page(
        language,
        view.System,
        row("main"),
        action,
        Some("typed"),
        None,
      )
    assert string.contains(
      page,
      html(dashboard.account_action_form(
        language,
        row("main"),
        action,
        Some("typed"),
        dashboard.label_hint_id,
      )),
    )
  })
  assert string.contains(
    account_pages.unreadable_delete_page(
      language,
      view.System,
      skipped_row("main"),
      None,
    ),
    html(dashboard.unreadable_delete_form(language, skipped_row("main"))),
  )
}

/// `account_actions.with_form` の各操作のページが、ほかの 3 つの操作のページへの `href` を持ち、今の操作の
/// `href` を持たない。
pub fn account_action_pages_link_to_the_other_actions_test() {
  list.each(account_actions.with_form, fn(action) {
    let page =
      account_pages.account_action_page(
        i18n.English,
        view.System,
        row("main"),
        action,
        None,
        None,
      )
    list.each(account_actions.with_form, fn(other) {
      let href =
        "href=\"" <> dashboard.account_action_path("abcd", other) <> "\""
      assert string.contains(page, href) == { other != action }
    })
  })
}
