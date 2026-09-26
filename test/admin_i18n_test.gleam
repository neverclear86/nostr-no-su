//// 表示の言語（cookie、`Accept-Language`、切り替えの POST、日本語ページでの
//// バンカー由来の理由と通知ページの本文の扱い）のテスト。

import gleam/http
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import nostr_no_su/admin
import nostr_no_su/admin/dashboard
import nostr_no_su/admin/i18n
import nostr_no_su/bunker
import support/admin_context.{
  action_path, client, context, failing_context, get, header, in_japanese,
  not_answering_context, opened_dialog, password, post, signer, signer_nsec,
  spec_nsec, token, unavailable, with_accounts, with_credentials,
}
import wisp
import wisp/simulate

// --- 表示の言語 ---

/// 応答のページの `<html lang>` の値。
fn page_language(response: Response(wisp.Body)) -> String {
  let assert Ok(#(_before, rest)) =
    string.split_once(simulate.read_body(response), "<html lang=\"")
  let assert Ok(#(language, _after)) = string.split_once(rest, "\"")
  language
}

/// 言語の切り替えの POST を、同じオリジンのブラウザーから送ったリクエスト。
fn language_switch_request(fields: List(#(String, String))) -> wisp.Request {
  simulate.browser_request(http.Post, "/language")
  |> with_credentials("admin", password)
  |> simulate.form_body(fields)
}

/// 表示の言語は、切り替えで保存した cookie、`Accept-Language`、英語の順に決める。対応して
/// いない cookie の値は無視する。
pub fn language_follows_the_cookie_then_accept_language_test() {
  let cases = [
    #([], "en"),
    #([#("accept-language", "ja,en-US;q=0.9,en;q=0.8")], "ja"),
    #([#("accept-language", "fr, de")], "en"),
    #([#("cookie", "nostr_no_su_language=ja")], "ja"),
    #([#("cookie", "other=1; nostr_no_su_language=ja")], "ja"),
    #(
      [#("cookie", "nostr_no_su_language=en"), #("accept-language", "ja")],
      "en",
    ),
    #(
      [#("cookie", "nostr_no_su_language=fr"), #("accept-language", "ja")],
      "ja",
    ),
  ]
  use #(headers, language) <- list.each(cases)
  let response =
    list.fold(
      headers,
      simulate.request(http.Get, "/") |> with_credentials("admin", password),
      fn(request, header) { request.set_header(request, header.0, header.1) },
    )
    |> admin.handle_request(context(), _)
  assert #(headers, page_language(response)) == #(headers, language)
}

/// 言語の切り替えは、選んだ言語を cookie に保存し、フォームが送った戻り先へ 303 で戻す。
pub fn language_switch_saves_the_language_and_returns_test() {
  let response =
    language_switch_request([
      #("language", "ja"),
      #("return", "/approve/" <> token),
    ])
    |> admin.handle_request(context(), _)
  assert response.status == 303
  assert header(response, "location") == "/approve/" <> token
  assert header(response, "set-cookie")
    == "nostr_no_su_language=ja; Max-Age=31536000; Path=/; HttpOnly; SameSite=Lax"
  assert header(response, "cache-control") == "no-store"
}

/// 言語の切り替えで「ブラウザーの設定」を選ぶと、cookie を消してフォームが送った戻り先へ
/// 303 で戻す。
pub fn language_switch_to_the_browser_setting_clears_the_cookie_test() {
  let response =
    language_switch_request([#("language", "system"), #("return", "/")])
    |> admin.handle_request(context(), _)
  assert response.status == 303
  assert header(response, "set-cookie")
    == "nostr_no_su_language=; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Max-Age=0; Path=/; HttpOnly; SameSite=Lax"
}

/// 戻り先は、同じサイトのパスとして組み立て直す。別のオリジンを指す値は、このサイトの
/// パスかダッシュボードになる。クエリーはキーと値ごとに符号化し直して残す。
pub fn language_switch_returns_only_within_the_site_test() {
  let cases = [
    #("/", "/"),
    #(action_path(dashboard.EditLabel), action_path(dashboard.EditLabel)),
    #("/approve/" <> token, "/approve/" <> token),
    #("//evil.example/x", "/evil.example/x"),
    #("/\\evil.example", "/%5Cevil.example"),
    #(
      "/approve/tok-1?next=//evil.example",
      "/approve/tok-1?next=%2F%2Fevil.example",
    ),
    #(
      "/approve/tok-1\r\nSet-Cookie: x=1",
      "/approve/tok-1%0D%0ASet-Cookie%3A%20x%3D1",
    ),
    #("https://evil.example/", "/"),
    #("evil.example", "/"),
    #("", "/"),
    #("/x?y=1", "/x?y=1"),
    #("/x?y=a%26b&z=1+2", "/x?y=a%26b&z=1%202"),
    #("/?y=1", "/?y=1"),
    #("/x?", "/x"),
    #("/x?y=%zz", "/x"),
    #("/x?y=1?z", "/x?y=1%3Fz"),
    #("/x?y=1\r\nSet-Cookie: x=1", "/x?y=1%0D%0ASet-Cookie%3A%20x%3D1"),
    #("/x?&", "/x"),
    #("/x?y=1&&z=2", "/x?y=1&z=2"),
    #("/x?=1&y=2", "/x?y=2"),
    #("/x?y", "/x?y="),
  ]
  use #(sent, location) <- list.each(cases)
  let response =
    language_switch_request([#("language", "en"), #("return", sent)])
    |> admin.handle_request(context(), _)
  assert #(sent, header(response, "location")) == #(sent, location)
}

/// 対応していない言語、GET、別のオリジンからの切り替え、資格情報の無い切り替えは受け付けず、
/// cookie を保存せず、それぞれの理由の本文を返す。
pub fn language_switch_rejects_invalid_requests_test() {
  let form_not_readable = i18n.text(i18n.English, i18n.FormNotReadable)
  let rejected = [
    #(
      language_switch_request([#("language", "fr"), #("return", "/")])
        |> admin.handle_request(context(), _),
      400,
      form_not_readable,
    ),
    #(
      language_switch_request([#("return", "/")])
        |> admin.handle_request(context(), _),
      400,
      form_not_readable,
    ),
    #(
      get(context(), "/language"),
      405,
      i18n.text(i18n.English, i18n.MethodNotAllowedDetail),
    ),
    #(
      language_switch_request([#("language", "ja"), #("return", "/")])
        |> request.set_header("origin", "http://evil.example")
        |> admin.handle_request(context(), _),
      400,
      i18n.text(i18n.English, i18n.OriginMismatch),
    ),
    #(
      simulate.browser_request(http.Post, "/language")
        |> simulate.form_body([#("language", "ja"), #("return", "/")])
        |> admin.handle_request(context(), _),
      401,
      "Unauthorized",
    ),
  ]
  use #(response, status, expected) <- list.each(rejected)
  assert response.status == status
  assert list.key_find(response.headers, "set-cookie") == Error(Nil)
  assert #(expected, string.contains(simulate.read_body(response), expected))
    == #(expected, True)
}

/// 切り替えた言語は、GET のページにも、ブラウザーから送った POST の応答のページにも保たれる。
pub fn switched_language_carries_across_pages_test() {
  let switch = language_switch_request([#("language", "ja"), #("return", "/")])
  let switched = admin.handle_request(context(), switch)
  let approval =
    simulate.browser_request(http.Get, "/approve/" <> token)
    |> with_credentials("admin", password)
    |> simulate.session(switch, switched)
    |> admin.handle_request(context(), _)
  assert page_language(approval) == "ja"
  let rejected =
    simulate.browser_request(http.Post, "/accounts/import")
    |> with_credentials("admin", password)
    |> simulate.session(switch, switched)
    |> simulate.form_body([#("nsec", string.drop_end(spec_nsec, 1) <> "4")])
    |> admin.handle_request(context(), _)
  assert rejected.status == 400
  assert string.contains(
    simulate.read_body(rejected),
    "<span class=\"wrap-anywhere\">bech32 のチェックサムが一致しません。</span>",
  )
}

/// `Origin` も `Referer` も無い POST は、CSRF の検査が cookie を取り除くので、
/// `Accept-Language` で言語が決まる。
pub fn posts_without_origin_ignore_the_language_cookie_test() {
  let import_broken_nsec = fn(request) {
    request
    |> with_credentials("admin", password)
    |> simulate.form_body([#("nsec", string.drop_end(spec_nsec, 1) <> "4")])
    |> admin.handle_request(context(), _)
    |> simulate.read_body
  }
  assert simulate.request(http.Post, "/accounts/import")
    |> request.set_header("cookie", "nostr_no_su_language=ja")
    |> import_broken_nsec
    |> string.contains("invalid bech32 checksum")
  assert simulate.request(http.Post, "/accounts/import")
    |> in_japanese
    |> import_broken_nsec
    |> string.contains("bech32 のチェックサムが一致しません。")
}

/// 日本語のページでも、バンカーから英語の文字列で届く理由は英語のまま `lang="en"` で
/// 出す。フォームの上とアカウントの節では、何ができなかったかを日本語で前に置く。
pub fn japanese_pages_keep_reasons_from_the_bunker_in_english_test() {
  let conflict =
    simulate.request(http.Post, action_path(dashboard.EditLabel))
    |> with_credentials("admin", password)
    |> in_japanese
    |> simulate.form_body([#("label", "new")])
    |> admin.handle_request(failing_context(bunker.NotApplied(unavailable)), _)
  assert conflict.status == 409
  assert string.contains(
    simulate.read_body(conflict),
    "<span class=\"wrap-anywhere\">ラベルを保存できませんでした。<span lang=\"en\">"
      <> unavailable
      <> "</span></span>",
  )
  let unavailable_body =
    simulate.request(http.Get, "/")
    |> with_credentials("admin", password)
    |> in_japanese
    |> admin.handle_request(with_accounts(Error(unavailable)), _)
    |> simulate.read_body
  assert string.contains(
    unavailable_body,
    "<span class=\"wrap-anywhere\">アカウントの一覧を表示できません。<span lang=\"en\">"
      <> unavailable
      <> "</span></span>",
  )
}

/// 日本語のページで、プラグインの再有効化の失敗の本文が日本語になる（`lang="en"` の `span` が
/// 無い）。名前に一致するプラグインが無ければ 404、ランナーが応答しなければ 503。
pub fn japanese_pages_translate_reenable_failures_test() {
  let cases = [
    #(admin.PluginNotFound, 404, i18n.PluginNotLoaded),
    #(admin.PluginNotAnswered, 503, i18n.PluginDidNotRespond),
  ]
  use #(failure, status, message) <- list.each(cases)
  let response =
    simulate.request(http.Post, "/plugins/reenable")
    |> with_credentials("admin", password)
    |> in_japanese
    |> simulate.form_body([#("name", "broken")])
    |> admin.handle_request(
      admin.Context(..context(), reenable_plugin: fn(_name) { Error(failure) }),
      _,
    )
  assert response.status == status
  let body = simulate.read_body(response)
  assert string.contains(
    body,
    "<p class=\"min-w-0 self-center\">"
      <> i18n.text(i18n.Japanese, message)
      <> "</p>",
  )
  assert !string.contains(body, "<span lang=\"en\">")
}

/// 日本語のページで、変更を確認できなかった通知ページの本文が日本語になる（`lang="en"` の
/// `span` が無い）。アカウントの変更の 202 と承認・拒否・取り消しの 503 のどれも対象。
pub fn japanese_pages_translate_unconfirmed_changes_test() {
  let cases = [
    #(
      failing_context(bunker.MaybeApplied(bunker.BunkerDidNotRespond)),
      action_path(dashboard.RotateSecret),
      [],
      i18n.BunkerDidNotRespond,
    ),
    #(
      failing_context(bunker.MaybeApplied(bunker.StoreDidNotConfirm)),
      action_path(dashboard.RotateSecret),
      [],
      i18n.StoreDidNotConfirm,
    ),
    #(
      not_answering_context(),
      "/sessions/revoke",
      [#("signer", signer), #("client", client)],
      i18n.BunkerDidNotRespond,
    ),
    #(
      admin.Context(..context(), approve: fn(_token) {
        Error(bunker.SessionMaybeApplied(bunker.StoreDidNotConfirm))
      }),
      "/approve/" <> token,
      [],
      i18n.StoreDidNotConfirm,
    ),
  ]
  use #(failing, path, fields, message) <- list.each(cases)
  let body =
    simulate.request(http.Post, path)
    |> with_credentials("admin", password)
    |> in_japanese
    |> simulate.form_body(fields)
    |> admin.handle_request(failing, _)
    |> simulate.read_body
  assert string.contains(
    body,
    "<h1 class=\"text-2xl font-bold\">変更を確認できませんでした</h1>",
  )
  assert string.contains(
    body,
    "<p class=\"min-w-0 self-center\">"
      <> i18n.text(i18n.Japanese, message)
      <> "</p>",
  )
  assert !string.contains(body, "<span lang=\"en\">")
}

/// 日本語のページで、アカウントの登録済みと未登録の理由が日本語になる（`lang="en"` の
/// `span` が無い）。nsec 入力による登録と生成した鍵の登録の登録済み（409 で開き直したダイアログ）、
/// ラベルの編集の未登録（404 の通知ページ）のどれも対象。
pub fn japanese_pages_translate_account_registration_reasons_test() {
  let already_registered =
    "<span class=\"wrap-anywhere\">"
    <> i18n.text(i18n.Japanese, i18n.AccountAlreadyRegistered)
    <> "</span>"
  let cases = [
    #(
      context(),
      "/accounts/import",
      [#("nsec", signer_nsec), #("label", "work")],
      409,
      Some("dialog-account-new"),
      already_registered,
    ),
    #(
      context(),
      "/accounts/register-generated",
      [#("nsec", signer_nsec), #("label", "work")],
      409,
      Some("dialog-result"),
      already_registered,
    ),
    #(
      failing_context(bunker.AccountNotRegistered),
      action_path(dashboard.EditLabel),
      [#("label", "new")],
      404,
      None,
      "<p class=\"min-w-0 self-center\">"
        <> i18n.text(i18n.Japanese, i18n.AccountNotFound)
        <> "</p>",
    ),
  ]
  use #(failing, path, fields, status, dialog, expected) <- list.each(cases)
  let response =
    simulate.request(http.Post, path)
    |> with_credentials("admin", password)
    |> in_japanese
    |> simulate.form_body(fields)
    |> admin.handle_request(failing, _)
  assert response.status == status
  // 409 はダッシュボードに開いたダイアログの中だけを見る（ダッシュボードのほかの節は英語の理由を含みうる）
  let body = case dialog {
    Some(id) -> opened_dialog(simulate.read_body(response), id)
    None -> simulate.read_body(response)
  }
  assert string.contains(body, expected)
  assert !string.contains(body, "<span lang=\"en\">")
}

/// 通知ページで言語を切り替えた後はダッシュボードを開く。一覧を得られない 503 でも、パスの
/// 署名者を戻り先に含めない。
pub fn notice_pages_return_to_the_dashboard_test() {
  let response =
    post(
      with_accounts(Error(unavailable)),
      "/accounts/%3Cscript%3Eunknown/label",
    )
  assert response.status == 503
  let body = simulate.read_body(response)
  assert string.contains(
    body,
    "<input name=\"return\" type=\"hidden\" value=\"/\">",
  )
  assert !string.contains(body, "unknown")
}
