import gleam/bit_array
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/list
import gleam/string
import nostr_no_su/admin
import nostr_no_su/admin/dashboard
import nostr_no_su/admin/i18n
import nostr_no_su/bunker
import support/account_actions
import support/admin_context.{
  Removed, Revoked, action_path, client, context, failing_context, get, header,
  in_japanese, password, post, post_form, reporting_context, signer, signer_nsec,
  spec_nsec, token, with_credentials,
}
import wisp
import wisp/simulate

/// 資格情報のないリクエストは 401 になり、ブラウザーに入力を促すヘッダーが付く。
pub fn dashboard_requires_credentials_test() {
  let response =
    simulate.request(http.Get, "/")
    |> admin.handle_request(context(), _)
  assert response.status == 401
  assert string.starts_with(header(response, "www-authenticate"), "Basic ")
  assert header(response, "content-type") == "text/plain"
}

/// 認証スキームの大文字小文字は区別しない（RFC 7235）。
pub fn authentication_scheme_is_case_insensitive_test() {
  let response =
    simulate.request(http.Get, "/")
    |> with_credentials("admin", password)
    |> lowercase_scheme
    |> admin.handle_request(context(), _)
  assert response.status == 200
}

/// `Authorization` ヘッダーのスキームを小文字にしたリクエスト。
fn lowercase_scheme(request: wisp.Request) -> wisp.Request {
  let assert Ok("Basic " <> credentials) =
    list.key_find(request.headers, "authorization")
  request.set_header(request, "authorization", "basic " <> credentials)
}

/// パスワードが違えば 401。ユーザー名が違う場合も同じ。
pub fn wrong_credentials_are_rejected_test() {
  let wrong_password =
    simulate.request(http.Get, "/")
    |> with_credentials("admin", "wrong")
    |> admin.handle_request(context(), _)
  assert wrong_password.status == 401

  let wrong_user =
    simulate.request(http.Get, "/")
    |> with_credentials("root", password)
    |> admin.handle_request(context(), _)
  assert wrong_user.status == 401
}

/// 壊れた `Authorization` ヘッダーでもクラッシュせず 401 を返す。
pub fn malformed_credentials_are_rejected_test() {
  let response =
    simulate.request(http.Get, "/")
    |> request.set_header("authorization", "Basic not-base64!")
    |> admin.handle_request(context(), _)
  assert response.status == 401
}

/// Basic 認証の失敗は、資格情報なし、形式の誤り、資格情報の不一致に分類される。
pub fn authentication_failures_are_classified_test() {
  let bare = simulate.request(http.Get, "/")
  assert admin.authenticate(password, bare) == Error(admin.NoCredentials)

  let encode = fn(value) {
    bit_array.from_string(value) |> bit_array.base64_encode(True)
  }
  let malformed = [
    "Basic not-base64!",
    "Basic",
    "Bearer " <> encode("admin:" <> password),
    "Basic " <> encode("no-colon"),
  ]
  list.each(malformed, fn(header) {
    let request = bare |> request.set_header("authorization", header)
    assert admin.authenticate(password, request)
      == Error(admin.MalformedCredentials)
  })

  let wrong = [#("admin", "wrong"), #("root", password)]
  list.each(wrong, fn(pair) {
    let #(user, offered) = pair
    let request = bare |> with_credentials(user, offered)
    assert admin.authenticate(password, request)
      == Error(admin.WrongCredentials)
  })

  let correct = bare |> with_credentials("admin", password)
  assert admin.authenticate(password, correct) == Ok(Nil)
  assert admin.authenticate(password, correct |> lowercase_scheme) == Ok(Nil)
}

/// 401 のログ行は理由だけを含む。
pub fn unauthorized_lines_name_the_failure_test() {
  assert admin.unauthorized_line(admin.NoCredentials)
    == "rejected a request without credentials"
  assert admin.unauthorized_line(admin.MalformedCredentials)
    == "rejected a request with malformed credentials"
  assert admin.unauthorized_line(admin.WrongCredentials)
    == "rejected a request with wrong credentials"
}

/// secret 入りの URI を含むダッシュボードは、どこにも保存させない。
pub fn dashboard_is_not_cached_test() {
  assert header(get(context(), "/"), "cache-control") == "no-store"
}

/// `/healthz` は認証なしで 200 を返す。コンテナーの healthcheck 用。
pub fn healthz_needs_no_credentials_test() {
  let response =
    simulate.request(http.Get, "/healthz")
    |> admin.handle_request(context(), _)
  assert response.status == 200
  assert simulate.read_body(response) == "ok"
  assert header(response, "content-type") == "text/plain"
}

/// 別オリジンのフォームから送られた POST は 400 で弾く。Basic 認証の資格情報は
/// ブラウザーが自動送信するため、認証だけでは CSRF を防げない。
pub fn cross_origin_revoke_is_rejected_test() {
  let revoked = process.new_subject()
  let response =
    simulate.browser_request(http.Post, "/sessions/revoke")
    |> request.set_header("origin", "http://evil.example")
    |> with_credentials("admin", password)
    |> simulate.form_body([#("signer", signer), #("client", client)])
    |> admin.handle_request(reporting_context(revoked), _)
  assert response.status == 400
  assert process.receive(revoked, 100) == Error(Nil)
}

/// 同じオリジンからのフォーム送信は通る。ブラウザーからも取り消せること。
pub fn same_origin_revoke_is_accepted_test() {
  let revoked = process.new_subject()
  let response =
    simulate.browser_request(http.Post, "/sessions/revoke")
    |> with_credentials("admin", password)
    |> simulate.form_body([#("signer", signer), #("client", client)])
    |> admin.handle_request(reporting_context(revoked), _)
  assert response.status == 303
  assert process.receive(revoked, 1000)
    == Ok(Revoked(signer: signer, client: client))
}

/// 別オリジンのフォームから送られた POST は 400 で弾き、`reenable_plugin` を呼ばない。
pub fn cross_origin_reenable_is_rejected_test() {
  let reenabled = process.new_subject()
  let response =
    simulate.browser_request(http.Post, "/plugins/reenable")
    |> request.set_header("origin", "http://evil.example")
    |> with_credentials("admin", password)
    |> simulate.form_body([#("name", "broken")])
    |> admin.handle_request(reporting_context(reenabled), _)
  assert response.status == 400
  assert process.receive(reenabled, 100) == Error(Nil)
}

/// 資格情報のない承認は 401 で、Context には届かない。
pub fn approve_requires_credentials_test() {
  let reports = process.new_subject()
  let response =
    simulate.request(http.Post, "/approve/" <> token)
    |> admin.handle_request(reporting_context(reports), _)
  assert response.status == 401
  assert process.receive(reports, 100) == Error(Nil)
}

/// 別オリジンのフォームから送られた承認は 400 で弾く。本文を読まずパスだけで
/// 承認できる設計なので、CSRF 対策はこの経路にも効いている必要がある。
pub fn cross_origin_approve_is_rejected_test() {
  let reports = process.new_subject()
  let response =
    simulate.browser_request(http.Post, "/approve/" <> token)
    |> request.set_header("origin", "http://evil.example")
    |> with_credentials("admin", password)
    |> admin.handle_request(reporting_context(reports), _)
  assert response.status == 400
  assert process.receive(reports, 100) == Error(Nil)
}

/// `:` を含む管理パスワードでも、Basic 認証と再表示のどちらも通る。
pub fn password_containing_a_colon_is_accepted_test() {
  let colon = admin.Context(..context(), password: "pa:ss")
  assert get(colon, "/").status == 200
  let response =
    post_form(colon, action_path(dashboard.RevealPrivateKey), [
      #("password", "pa:ss"),
    ])
  assert response.status == 200
}

// --- 横断 ---

/// 別オリジンから送られた、アカウントを扱う POST はすべて 400 で弾き、何も呼ばない。
pub fn cross_origin_account_changes_are_rejected_test() {
  let reports = process.new_subject()
  let paths = [
    "/accounts/generate",
    "/accounts/import",
    "/accounts/register-generated",
    ..list.map(account_actions.all, action_path)
  ]
  list.each(paths, fn(path) {
    let response =
      simulate.browser_request(http.Post, path)
      |> request.set_header("origin", "http://evil.example")
      |> with_credentials("admin", password)
      |> simulate.form_body([
        #("nsec", spec_nsec),
        #("label", "x"),
        #("password", password),
      ])
      |> admin.handle_request(reporting_context(reports), _)
    assert #(path, response.status) == #(path, 400)
  })
  assert process.receive(reports, 100) == Error(Nil)
}

/// 同じオリジンからの削除の POST は通る。
pub fn same_origin_account_change_is_accepted_test() {
  let reports = process.new_subject()
  let response =
    simulate.browser_request(http.Post, action_path(dashboard.DeleteAccount))
    |> with_credentials("admin", password)
    |> simulate.form_body([])
    |> admin.handle_request(reporting_context(reports), _)
  assert response.status == 303
  assert process.receive(reports, 1000) == Ok(Removed(signer))
}

/// 別オリジンの POST は 400 の HTML で、切り替えを出さず、枠への埋め込みも禁じる。
/// `Host` の無いリクエストも同じ 400 の HTML になる。
pub fn cross_origin_post_is_an_origin_mismatch_page_test() {
  let base =
    simulate.request(http.Post, "/language")
    |> request.set_header("origin", "http://evil.example")
    |> in_japanese
    |> with_credentials("admin", password)

  let with_host = admin.handle_request(context(), base)
  assert with_host.status == 400
  assert header(with_host, "content-type") == "text/html; charset=utf-8"
  let body = simulate.read_body(with_host)
  assert string.contains(body, i18n.text(i18n.Japanese, i18n.OriginMismatch))
  assert !string.contains(body, "name=\"return\"")
  assert header(with_host, "x-frame-options") == "DENY"

  let without_host =
    request.Request(
      ..base,
      headers: list.filter(base.headers, fn(h) { h.0 != "host" }),
    )
    |> admin.handle_request(context(), _)
  assert without_host.status == 400
  assert header(without_host, "content-type") == "text/html; charset=utf-8"
}

/// `Origin`（無ければ `Referer`）がある POST は、そのホストとポートが `Host` と一致するときだけ
/// 通す。リバースプロキシーが `Host` を上流のアドレスに書き換えるか、ポートを落とすと 400 になり、
/// 公開ホスト名とポートのまま渡せば通る（README のリバースプロキシーの節の根拠）。検査は
/// ルーティングの前にあるので、Context の関数を呼ばない言語の切り替えで確かめる。
pub fn posts_need_a_host_that_matches_the_origin_test() {
  let cases = [
    // Host を上流のアドレスに書き換えたプロキシー（nginx の既定）
    #(
      [#("host", "127.0.0.1:8080"), #("origin", "https://admin.example")],
      False,
    ),
    // ポートを落としたプロキシー（nginx の `$host`）
    #(
      [#("host", "admin.example"), #("origin", "https://admin.example:8443")],
      False,
    ),
    // `Origin` が無ければ `Referer` と突き合わせる
    #(
      [#("host", "127.0.0.1:8080"), #("referer", "https://admin.example/")],
      False,
    ),
    // Host をそのまま渡したプロキシー
    #([#("host", "admin.example"), #("origin", "https://admin.example")], True),
    #(
      [
        #("host", "admin.example:8443"),
        #("origin", "https://admin.example:8443"),
      ],
      True,
    ),
    #(
      [#("host", "admin.example"), #("referer", "https://admin.example/")],
      True,
    ),
  ]
  use #(headers, accepted) <- list.each(cases)
  let response =
    list.fold(
      headers,
      simulate.request(http.Post, "/language")
        |> with_credentials("admin", password)
        |> simulate.form_body([#("language", "ja"), #("return", "/")]),
      fn(request, header) { request.set_header(request, header.0, header.1) },
    )
    |> admin.handle_request(context(), _)
  let saved = list.key_find(response.headers, "set-cookie") != Error(Nil)
  case accepted {
    True -> {
      assert #(headers, response.status, saved) == #(headers, 303, True)
    }
    False -> {
      assert #(headers, response.status, saved) == #(headers, 400, False)
      assert header(response, "content-type") == "text/html; charset=utf-8"
      assert string.contains(
        simulate.read_body(response),
        i18n.text(i18n.English, i18n.OriginMismatch),
      )
    }
  }
}

/// 認証済みの応答はどれも、保存の禁止、枠への埋め込みの禁止、CSP、`nosniff`、
/// `Referrer-Policy` のヘッダーを持つ。
pub fn authenticated_responses_carry_security_headers_test() {
  let context = context()
  let reveal = action_path(dashboard.RevealPrivateKey)
  let with_password = [#("password", password)]
  let spec = [#("nsec", spec_nsec), #("label", "work")]
  let responses = [
    get(context, "/"),
    get(context, "/static/admin.css"),
    get(context, "/static/admin.js"),
    post_form(context, "/language", [#("language", "ja"), #("return", "/")]),
    get(context, "/approve/" <> token),
    get(context, "/accounts/new"),
    post(context, "/accounts/generate"),
    post_form(context, "/accounts/import", spec),
    post_form(context, "/accounts/import", [#("nsec", "nope")]),
    post_form(context, "/accounts/import", [
      #("nsec", signer_nsec),
      #("label", "work"),
    ]),
    post_form(
      failing_context(bunker.MaybeApplied(bunker.StoreDidNotConfirm)),
      "/accounts/import",
      spec,
    ),
    post_form(
      failing_context(bunker.NotReady("accounts are not loaded yet")),
      "/accounts/import",
      spec,
    ),
    post_form(context, "/accounts/register-generated", spec),
    get(context, "/accounts/generate"),
    post_form(context, "/accounts/register-generated", [
      #("nsec", spec_nsec),
      #("label", "a\tb"),
    ]),
    ..list.append(
      list.map(account_actions.all, fn(action) {
        get(context, action_path(action))
      }),
      [
        post_form(context, reveal, with_password),
        post_form(context, reveal, [#("password", "wrong")]),
        post_form(
          admin.Context(..context, nsec: fn(_signer) {
            Error("bunker is not responding")
          }),
          reveal,
          with_password,
        ),
        post(context, action_path(dashboard.DeleteAccount)),
        get(context, "/nope"),
      ],
    )
  ]
  assert list.map(responses, fn(response) { response.status })
    == [
      200, 200, 200, 303, 200, 200, 200, 200, 400, 409, 202, 503, 303, 405, 400,
      200, 200, 200, 200, 200, 403, 503, 303, 404,
    ]
  list.each(responses, fn(response) {
    assert header(response, "cache-control") == "no-store"
    assert header(response, "x-frame-options") == "DENY"
    assert header(response, "content-security-policy")
      == "default-src 'none'; script-src 'self'; style-src 'self'; img-src data:; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"
    assert header(response, "x-content-type-options") == "nosniff"
    assert header(response, "referrer-policy") == "same-origin"
  })
}

/// 資格情報の無い登録と再表示の POST は 401 で、何も呼ばない。
pub fn account_management_requires_credentials_test() {
  let reports = process.new_subject()
  let requests = [
    #("/accounts/import", [#("nsec", spec_nsec)]),
    #(action_path(dashboard.RevealPrivateKey), [#("password", password)]),
  ]
  list.each(requests, fn(entry) {
    let #(path, fields) = entry
    let response =
      simulate.request(http.Post, path)
      |> simulate.form_body(fields)
      |> admin.handle_request(reporting_context(reports), _)
    assert response.status == 401
  })
  assert process.receive(reports, 100) == Error(Nil)
}
