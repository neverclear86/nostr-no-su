//// Basic 認証、制御文字を含む `Host`・`Origin`・`Referer` の拒否、CSRF の検査
//// （`Origin` と `Host` の照合）、認証済みの応答のヘッダー、認証の前に置く
//// `/healthz` のテスト。

import gleam/bit_array
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/list
import gleam/string
import nostr_no_su/admin
import nostr_no_su/admin/i18n
import nostr_no_su/admin/routes
import nostr_no_su/bunker
import support/account_actions
import support/admin_context.{
  Removed, Revoked, action_path, client, client_address, context,
  failing_context, get, header, in_japanese, password, post, post_form,
  reporting_context, signer, signer_nsec, spec_nsec, token, with_credentials,
}
import support/log_capture
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

/// 401 のログ行は理由と接続元の IP だけを含む。
pub fn unauthorized_lines_name_the_failure_test() {
  assert admin.unauthorized_line(admin.NoCredentials, client_address)
    == "rejected a request without credentials from 203.0.113.5"
  assert admin.unauthorized_line(admin.MalformedCredentials, client_address)
    == "rejected a request with malformed credentials from 203.0.113.5"
  assert admin.unauthorized_line(admin.WrongCredentials, client_address)
    == "rejected a request with wrong credentials from 203.0.113.5"
  assert admin.unauthorized_line(
      admin.NoCredentials,
      admin.unknown_client_address,
    )
    == "rejected a request without credentials from an unknown address"
}

/// Basic 認証に失敗した応答は、Context の `authentication_delay` を呼んでから返る。
pub fn failed_authentication_is_delayed_test() {
  let waited = process.new_subject()
  let context =
    admin.Context(..context(), authentication_delay: fn() {
      process.send(waited, Nil)
    })
  let response =
    simulate.request(http.Get, "/")
    |> admin.handle_request(context, _)
  assert response.status == 401
  assert process.receive(waited, 0) == Ok(Nil)
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

/// `/healthz` は GET 以外を 405 で拒否する。認証より前に判定するため、資格情報を
/// 付けなくても 401 にはならない。
pub fn healthz_rejects_methods_other_than_get_test() {
  let response =
    simulate.request(http.Post, "/healthz")
    |> admin.handle_request(context(), _)
  assert response.status == 405
  assert header(response, "allow") == "GET"
  assert simulate.read_body(response) == "Method not allowed"
}

/// `handle_head` が HEAD を GET に読み替えるため、`/healthz` は HEAD にも認証なしで
/// 200 を返す。
pub fn healthz_accepts_head_test() {
  let response =
    simulate.request(http.Head, "/healthz")
    |> admin.handle_request(context(), _)
  assert response.status == 200
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

/// 資格情報のない承認は 401 で、Context には届かない。
pub fn approve_requires_credentials_test() {
  let reports = process.new_subject()
  let response =
    simulate.request(http.Post, "/approve/" <> token)
    |> admin.handle_request(reporting_context(reports), _)
  assert response.status == 401
  assert process.receive(reports, 100) == Error(Nil)
}

/// `:` を含む管理パスワードでも、Basic 認証と再表示のどちらも通る。
pub fn password_containing_a_colon_is_accepted_test() {
  let colon = admin.Context(..context(), password: "pa:ss")
  assert get(colon, "/").status == 200
  let response =
    post_form(colon, action_path(routes.RevealPrivateKey), [
      #("password", "pa:ss"),
    ])
  assert response.status == 200
}

// --- 横断 ---

/// 別オリジンから送られた、状態を変える POST（アカウントの変更、セッションの取り消しと
/// 権限の編集、プラグインの再有効化、承認）はすべて 400 で弾き、何も呼ばない。Basic 認証の
/// 資格情報はブラウザーが自動送信し、承認は本文を読まずパスだけで決まるので、認証だけでは
/// CSRF を防げない。
pub fn cross_origin_state_changes_are_rejected_test() {
  let reports = process.new_subject()
  let paths = [
    "/accounts/generate",
    "/accounts/import",
    "/accounts/register-generated",
    routes.href(routes.SessionPermissions(signer, client)),
    "/sessions/revoke",
    "/plugins/reenable",
    "/approve/" <> token,
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
    simulate.browser_request(http.Post, action_path(routes.DeleteAccount))
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
  assert header(with_host, "content-security-policy")
    == "default-src 'none'; script-src 'self'; style-src 'self'; img-src data: https:; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"

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
/// 公開ホスト名とポートのまま渡せば通る（docs/configuration.md の「リバースプロキシーの設定」の根拠）。検査は
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

/// `Host`、`Origin`、`Referer` のどれかに制御文字を含む要求は、メソッドによらず
/// text/plain の 400 で弾き、生の値はログに出ない。OTP logger の行は VM 全体から
/// 捕まり、並列に走る他のモジュールの行も混ざるが、ESC の並びの有無だけを見るので
/// 干渉しない。
pub fn control_characters_in_origin_headers_are_not_logged_test() {
  let capture = log_capture.install()
  let cases = [
    [#("origin", "http://evil.example\u{1b}[2J")],
    [#("referer", "http://evil.example\u{1b}[2J")],
    [#("host", "evil.example\u{1b}[2J"), #("origin", "http://localhost")],
  ]
  list.each(cases, fn(headers) {
    let response =
      list.fold(
        headers,
        simulate.request(http.Post, "/language"),
        fn(request, header) { request.set_header(request, header.0, header.1) },
      )
      |> admin.handle_request(context(), _)
    assert response.status == 400
    assert header(response, "content-type") == "text/plain"
  })
  assert !list.any(log_capture.lines(capture), string.contains(_, "\u{1b}[2J"))
  log_capture.remove(capture)
}

/// 認証済みの応答はどれも、保存の禁止、枠への埋め込みの禁止、CSP、`nosniff`、
/// `Referrer-Policy` のヘッダーを持つ。
pub fn authenticated_responses_carry_security_headers_test() {
  let context = context()
  let reveal = action_path(routes.RevealPrivateKey)
  let with_password = [#("password", password)]
  let spec = [#("nsec", spec_nsec), #("label", "work")]
  let responses = [
    #("GET /", get(context, "/"), 200),
    #("GET /static/admin.css", get(context, "/static/admin.css"), 200),
    #("GET /static/admin.js", get(context, "/static/admin.js"), 200),
    #(
      "POST /language",
      post_form(context, "/language", [#("language", "ja"), #("return", "/")]),
      303,
    ),
    #("GET /approve/" <> token, get(context, "/approve/" <> token), 200),
    #("GET /accounts/new", get(context, "/accounts/new"), 404),
    #("POST /accounts/generate", post(context, "/accounts/generate"), 200),
    #("import", post_form(context, "/accounts/import", spec), 303),
    #(
      "import an invalid nsec",
      post_form(context, "/accounts/import", [#("nsec", "nope")]),
      400,
    ),
    #(
      "import a registered nsec",
      post_form(context, "/accounts/import", [
        #("nsec", signer_nsec),
        #("label", "work"),
      ]),
      409,
    ),
    #(
      "import not confirmed",
      post_form(
        failing_context(bunker.MaybeApplied(bunker.StoreDidNotConfirm)),
        "/accounts/import",
        spec,
      ),
      202,
    ),
    #(
      "import before the accounts are loaded",
      post_form(
        failing_context(bunker.NotReady("accounts are not loaded yet")),
        "/accounts/import",
        spec,
      ),
      503,
    ),
    #(
      "register a generated key",
      post_form(context, "/accounts/register-generated", spec),
      303,
    ),
    #("GET /accounts/generate", get(context, "/accounts/generate"), 405),
    #(
      "register a label with a tab",
      post_form(context, "/accounts/register-generated", [
        #("nsec", spec_nsec),
        #("label", "a\tb"),
      ]),
      400,
    ),
    ..list.append(
      list.map(account_actions.all, fn(action) {
        let path = action_path(action)
        #("GET " <> path, get(context, path), 405)
      }),
      [
        #("reveal", post_form(context, reveal, with_password), 200),
        #(
          "reveal with a wrong password",
          post_form(context, reveal, [#("password", "wrong")]),
          403,
        ),
        #(
          "reveal without an answer",
          post_form(
            admin.Context(..context, nsec: fn(_signer) {
              Error("bunker is not responding")
            }),
            reveal,
            with_password,
          ),
          503,
        ),
        #("delete", post(context, action_path(routes.DeleteAccount)), 303),
        #("plugin page", get(context, "/plugins/console_logger/status"), 200),
        #("unknown path", get(context, "/nope"), 404),
      ],
    )
  ]
  use #(name, response, status) <- list.each(responses)
  assert #(name, response.status) == #(name, status)
  assert #(name, header(response, "cache-control")) == #(name, "no-store")
  assert #(name, header(response, "x-frame-options")) == #(name, "DENY")
  assert #(name, header(response, "x-content-type-options"))
    == #(name, "nosniff")
  assert #(name, header(response, "referrer-policy")) == #(name, "same-origin")
  assert #(
      name,
      string.starts_with(
        header(response, "content-security-policy"),
        "default-src 'none'; script-src 'self'; style-src 'self'; img-src data:",
      ),
    )
    == #(name, True)
}

/// 資格情報の無い登録と再表示の POST は 401 で、何も呼ばない。
pub fn account_management_requires_credentials_test() {
  let reports = process.new_subject()
  let requests = [
    #("/accounts/import", [#("nsec", spec_nsec)]),
    #(action_path(routes.RevealPrivateKey), [#("password", password)]),
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
