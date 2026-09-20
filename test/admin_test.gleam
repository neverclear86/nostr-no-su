//// 管理 UI のルートのテスト。`Context` に偽の関数を注入し、アクターを起動せずに
//// 応答を確かめる。ダッシュボードの状態、アカウントの読み直し、セッションの取り消し、
//// クライアントの接続、プラグインの再有効化、承認と拒否、リレーの追加・編集・削除、
//// 静的ファイルと通知の色、表示のテーマを対象にする。

import gleam/erlang/process

import gleam/http
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import nostr_no_su/admin
import nostr_no_su/admin/dashboard
import nostr_no_su/admin/i18n
import nostr_no_su/admin/view
import nostr_no_su/bunker
import nostr_no_su/bunker/engine
import nostr_no_su/relay_list
import nostr_no_su/task
import nostr_no_su/time
import support/account_actions
import support/admin_context.{
  AccountsReloaded, Approved, ClientConnectRequested, Denied, Reenabled,
  RelayAdded, RelayDeleted, RelayRolesUpdated, Revoked, action_path, auth_uri,
  client, context, failing_context, get, header, in_japanese, label,
  not_answering_context, password, post, post_form, reporting_context,
  session_not_approved, signer, signer_npub, spec_nsec, test_context, token,
  unavailable, with_accounts, with_credentials,
}
import wisp
import wisp/simulate

/// 承認済みのセッションを持たないクライアント。
const unknown_client = "cccc3333"

/// フェイクの再有効化が、名前に一致するプラグインが無いときに返す理由。
const plugin_not_found = "plugin not found"

/// フェイクの再有効化が、ランナーの無応答として返す理由。
const plugin_not_answered = "plugin runner did not answer"

/// 認証を通れば、ダッシュボードにアカウント・リレー・セッション・プラグインが
/// 出る。
pub fn dashboard_shows_the_current_state_test() {
  let response = get(context(), "/")
  assert response.status == 200
  let body = simulate.read_body(response)
  assert string.contains(body, signer)
  assert string.contains(body, client)
  assert string.contains(body, "bunker://" <> signer)
  assert string.contains(body, "wss://relay.example")
  assert string.contains(body, "wss://bunker.example")
  // 要素単位で見る。"connected" だけでは "disconnected" にも一致してしまう。
  assert string.contains(
    body,
    "<span class=\"whitespace-nowrap\">monitor</span>",
  )
  assert string.contains(
    body,
    "<span class=\"badge badge-sm badge-success whitespace-nowrap\">connected</span>",
  )
  assert string.contains(
    body,
    "<span class=\"whitespace-nowrap\">bunker</span>",
  )
  assert string.contains(
    body,
    "<span class=\"badge badge-sm badge-error whitespace-nowrap\">disconnected</span>",
  )
  assert string.contains(body, "<td class=\"break-words\">console_logger</td>")
  assert string.contains(
    body,
    "<span class=\"badge badge-sm badge-success whitespace-nowrap\">running</span>",
  )
}

/// 状態に含まれる HTML は、そのまま出さずにエスケープする。リレー URL も
/// クライアント pubkey も外から来た文字列になりうる。
pub fn dashboard_escapes_html_test() {
  let context = test_context(process.new_subject(), "ws://evil/\"><b>xss</b>")
  let body = simulate.read_body(get(context, "/"))
  assert string.contains(body, "&quot;&gt;&lt;b&gt;xss&lt;/b&gt;")
  assert !string.contains(body, "<b>xss</b>")
}

/// 無効化されたプラグインの理由はプラグイン由来の文字列なので、素の HTML として
/// 出してはならない。
pub fn dashboard_escapes_a_plugin_failure_reason_test() {
  let body = simulate.read_body(get(context(), "/"))
  assert string.contains(body, "&lt;script&gt;alert(1)&lt;/script&gt;")
  assert !string.contains(body, "<script>alert(1)</script>")
  assert string.contains(body, "(dropped 3)")
}

/// accounts が締め切りまでに答えなければ、その節だけ締め切り超過の理由になり、
/// 間に合った pending と sessions はそのまま出る。経過は締め切りに収まる
/// （1 秒未満）。
pub fn the_dashboard_gives_up_on_slow_sections_at_the_deadline_test() {
  let slow_context =
    admin.Context(..context(), accounts: fn() {
      process.sleep(3000)
      Ok([])
    })
  let started_at = time.monotonic_ms()
  let snapshot = admin.snapshot(slow_context, task.deadline_in(300))
  assert snapshot.accounts == Error(i18n.Translated(i18n.NotAvailable))
  let assert Ok(_) = snapshot.skipped
  let assert Ok(_) = snapshot.pending
  let assert Ok(_) = snapshot.sessions
  assert time.monotonic_ms() - started_at < 1000
}

/// 取り消しフォームは Context の `revoke` を呼び、ダッシュボードへ 303 で戻す。
pub fn revoke_calls_the_context_and_redirects_test() {
  let revoked = process.new_subject()
  let response =
    post_form(reporting_context(revoked), "/sessions/revoke", [
      #("signer", signer),
      #("client", client),
    ])
  assert response.status == 303
  assert header(response, "location") == "/"
  assert process.receive(revoked, 1000)
    == Ok(Revoked(signer: signer, client: client))
}

/// 承認済みのセッションに無い組の取り消しは 404 で、理由とダッシュボードへのリンクを
/// 出す。送った値は含めない。
pub fn revoking_an_unknown_session_is_not_found_test() {
  let revoked = process.new_subject()
  let response =
    post_form(reporting_context(revoked), "/sessions/revoke", [
      #("signer", signer),
      #("client", unknown_client),
    ])
  assert response.status == 404
  let body = simulate.read_body(response)
  assert string.contains(body, session_not_approved)
  assert string.contains(
    body,
    "<a class=\"link\" href=\"/\">Back to dashboard</a>",
  )
  assert !string.contains(body, unknown_client)
  assert process.receive(revoked, 1000)
    == Ok(Revoked(signer: signer, client: unknown_client))
}

/// フィールドが欠けた取り消しは 400 になり、取り消しは行われない。
pub fn revoke_without_fields_is_a_bad_request_test() {
  let revoked = process.new_subject()
  let response =
    post_form(reporting_context(revoked), "/sessions/revoke", [
      #("signer", signer),
    ])
  assert response.status == 400
  assert process.receive(revoked, 100) == Error(Nil)
}

/// 取り消しは POST でしか受け付けない。
pub fn revoke_rejects_other_methods_test() {
  let response = get(context(), "/sessions/revoke")
  assert response.status == 405
}

/// 再有効化フォームは Context の `reenable_plugin` を名前で呼び、ダッシュボードへ
/// 303 で戻す。
pub fn reenable_calls_the_context_and_redirects_test() {
  let reenabled = process.new_subject()
  let response =
    post_form(reporting_context(reenabled), "/plugins/reenable", [
      #("name", "broken"),
    ])
  assert response.status == 303
  assert header(response, "location") == "/"
  assert process.receive(reenabled, 1000) == Ok(Reenabled(name: "broken"))
}

/// 名前に一致するプラグインが無ければ 404 で、理由とダッシュボードへのリンクを出す。
pub fn reenabling_an_unknown_plugin_is_not_found_test() {
  let context =
    admin.Context(..context(), reenable_plugin: fn(_name) {
      Error(admin.PluginNotFound(plugin_not_found))
    })
  let response = post_form(context, "/plugins/reenable", [#("name", "missing")])
  assert response.status == 404
  let body = simulate.read_body(response)
  assert string.contains(body, plugin_not_found)
  assert string.contains(
    body,
    "<a class=\"link\" href=\"/\">Back to dashboard</a>",
  )
}

/// ランナーが応答しない再有効化は 503 で、理由とダッシュボードへのリンクを出す。
pub fn reenabling_a_plugin_that_does_not_answer_is_unavailable_test() {
  let context =
    admin.Context(..context(), reenable_plugin: fn(_name) {
      Error(admin.PluginNotAnswered(plugin_not_answered))
    })
  let response = post_form(context, "/plugins/reenable", [#("name", "broken")])
  assert response.status == 503
  let body = simulate.read_body(response)
  assert string.contains(body, "Change not confirmed")
  assert string.contains(body, plugin_not_answered)
  assert string.contains(body, "Back to dashboard")
}

/// 欄 `name` が無い再有効化は 400 で、`reenable_plugin` を呼ばない。
pub fn reenable_without_a_name_is_a_bad_request_test() {
  let reenabled = process.new_subject()
  let response =
    post_form(reporting_context(reenabled), "/plugins/reenable", [])
  assert response.status == 400
  assert process.receive(reenabled, 100) == Error(Nil)
}

/// 再有効化は POST でしか受け付けない。
pub fn reenable_rejects_other_methods_test() {
  let response = get(context(), "/plugins/reenable")
  assert response.status == 405
}

/// 読み直しフォームは Context の `reload_accounts` を呼び、ダッシュボードへ 303 で戻す。
pub fn reloading_redirects_to_the_dashboard_test() {
  let reloaded = process.new_subject()
  let response = post(reporting_context(reloaded), "/accounts/reload")
  assert response.status == 303
  assert header(response, "location") == "/"
  assert process.receive(reloaded, 1000) == Ok(AccountsReloaded)
}

/// バンカーが応答しない読み直しは 503 で、理由とダッシュボードへのリンクを出す。
pub fn reloading_without_a_bunker_is_unavailable_test() {
  let context =
    admin.Context(..context(), reload_accounts: fn() {
      Error("bunker is not responding")
    })
  let response = post(context, "/accounts/reload")
  assert response.status == 503
  let body = simulate.read_body(response)
  assert string.contains(body, "bunker is not responding")
  assert string.contains(body, "Back to dashboard")
}

/// ダッシュボードには承認待ちと、承認を経る接続 URI も出る。
pub fn dashboard_shows_pending_connections_test() {
  let body = simulate.read_body(get(context(), "/"))
  assert string.contains(body, "value=\"" <> auth_uri <> "\"")
  assert string.contains(body, "action=\"/approve/" <> token <> "\"")
  assert string.contains(body, "action=\"/deny/" <> token <> "\"")
  assert string.contains(body, "<dd><span>540s</span></dd>")
}

/// 承認ページには、誰が誰に接続しようとしているかが出る。署名者はアカウント一覧と
/// 突き合わせてラベルと省略した npub で出るので、16 進の署名者は出ない。
pub fn approval_page_shows_the_request_test() {
  let response = get(context(), "/approve/" <> token)
  assert response.status == 200
  let body = simulate.read_body(response)
  assert string.contains(body, label)
  assert string.contains(body, view.shorten(signer_npub))
  assert string.contains(body, client)
  assert string.contains(body, "<dd><span>540s</span></dd>")
}

/// 知らない、あるいは失効したトークンの承認ページは 404 の HTML で、理由を出し
/// token を含めない。
pub fn approval_page_for_an_unknown_token_is_not_found_test() {
  let response = get(context(), "/approve/other-token")
  assert response.status == 404
  let body = simulate.read_body(response)
  assert header(response, "content-type") == "text/html; charset=utf-8"
  assert string.contains(body, "It may have expired")
  assert !string.contains(body, "other-token")
}

/// 承認は Context の `approve` を呼び、閉じてよいことを伝える。
pub fn approve_calls_the_context_test() {
  let reports = process.new_subject()
  let response = post(reporting_context(reports), "/approve/" <> token)
  assert response.status == 200
  assert string.contains(simulate.read_body(response), "Approved")
  assert process.receive(reports, 1000) == Ok(Approved(token))
}

/// 拒否は Context の `deny` を呼ぶ。
pub fn deny_calls_the_context_test() {
  let reports = process.new_subject()
  let response = post(reporting_context(reports), "/deny/" <> token)
  assert response.status == 200
  assert string.contains(simulate.read_body(response), "Denied")
  assert process.receive(reports, 1000) == Ok(Denied(token))
}

/// 承認待ちの一覧に無いトークンの承認・拒否は、Context の `approve` / `deny` を
/// 呼ばずに理由を添えた 404 にする。
pub fn deciding_an_unknown_token_is_not_found_test() {
  let reports = process.new_subject()
  let approve_response =
    post(reporting_context(reports), "/approve/other-token")
  let expected_reason =
    i18n.text(
      i18n.English,
      i18n.ApprovalRequestGone(engine.pending_ttl_minutes()),
    )
  assert approve_response.status == 404
  assert string.contains(simulate.read_body(approve_response), expected_reason)
  assert process.receive(reports, 100) == Error(Nil)

  let deny_response = post(reporting_context(reports), "/deny/other-token")
  assert deny_response.status == 404
  assert string.contains(simulate.read_body(deny_response), expected_reason)
  assert process.receive(reports, 100) == Error(Nil)
}

/// 承認待ちの一覧を得られなければ、承認ページの GET と、承認・拒否の POST は
/// 503 の `Bunker is not available` になり、理由を出す。approve と deny は
/// 呼ばれない。
pub fn pending_that_cannot_be_listed_is_unavailable_test() {
  let reports = process.new_subject()
  let reason = "account store unavailable: database is unreachable"
  let failing =
    admin.Context(..reporting_context(reports), pending: fn() { Error(reason) })

  let get_response = get(failing, "/approve/" <> token)
  assert get_response.status == 503
  let get_body = simulate.read_body(get_response)
  assert string.contains(get_body, "Bunker is not available")
  assert string.contains(get_body, reason)

  let approve_response = post(failing, "/approve/" <> token)
  assert approve_response.status == 503
  assert string.contains(simulate.read_body(approve_response), reason)

  let deny_response = post(failing, "/deny/" <> token)
  assert deny_response.status == 503
  assert string.contains(simulate.read_body(deny_response), reason)

  assert process.receive(reports, 100) == Error(Nil)
}

/// 承認・拒否・取り消しの失敗は、対象が無ければ 404、書き込まれていないことが
/// 確定していれば 409、受け付けられなければ 503 の `Bunker is not available`、
/// 反映されたか分からなければ 503 の `Change not confirmed` になる。
pub fn session_failures_are_shown_as_notice_pages_test() {
  let cases = [
    #(bunker.SessionNotFound("not found reason"), 404, "Not found"),
    #(bunker.SessionNotApplied("not applied reason"), 409, "Change not applied"),
    #(
      bunker.SessionNotReady("accounts are not loaded yet"),
      503,
      "Bunker is not available",
    ),
    #(
      bunker.SessionMaybeApplied(bunker.StoreDidNotConfirm),
      503,
      "Change not confirmed",
    ),
  ]
  use #(failure, status, heading) <- list.each(cases)
  let failing =
    admin.Context(
      ..context(),
      approve: fn(_token) { Error(failure) },
      deny: fn(_token) { Error(failure) },
      revoke: fn(_signer, _client) { Error(failure) },
    )
  let responses = [
    post(failing, "/approve/" <> token),
    post(failing, "/deny/" <> token),
    post_form(failing, "/sessions/revoke", [
      #("signer", signer),
      #("client", client),
    ]),
  ]
  list.each(responses, fn(response) {
    assert #(heading, response.status) == #(heading, status)
    assert string.contains(
      simulate.read_body(response),
      "<h1 class=\"text-2xl font-bold\">" <> heading <> "</h1>",
    )
  })
}

/// 反映されたか分からない失敗のページには、やり直す前にダッシュボードで確かめる
/// よう促す一文が付く。アカウントの変更の 202、プラグインの再有効化の 503、
/// `SessionMaybeApplied` の 503 のどれにも出て、対象が無い 404 には出ない。
pub fn unconfirmed_notices_ask_to_check_the_dashboard_test() {
  let hint = i18n.text(i18n.English, i18n.CheckDashboardBeforeRetrying)
  let with_hint = [
    post_form(
      failing_context(bunker.MaybeApplied(bunker.StoreDidNotConfirm)),
      action_path(dashboard.RotateSecret),
      [],
    ),
    post_form(
      admin.Context(..context(), reenable_plugin: fn(_name) {
        Error(admin.PluginNotAnswered(plugin_not_answered))
      }),
      "/plugins/reenable",
      [#("name", "broken")],
    ),
    post_form(
      admin.Context(..context(), revoke: fn(_signer, _client) {
        Error(bunker.SessionMaybeApplied(bunker.StoreDidNotConfirm))
      }),
      "/sessions/revoke",
      [#("signer", signer), #("client", client)],
    ),
  ]
  list.each(with_hint, fn(response) {
    assert string.contains(simulate.read_body(response), hint)
  })

  let not_found =
    post_form(
      admin.Context(..context(), revoke: fn(_signer, _client) {
        Error(bunker.SessionNotFound(session_not_approved))
      }),
      "/sessions/revoke",
      [#("signer", signer), #("client", client)],
    )
  assert !string.contains(simulate.read_body(not_found), hint)
}

/// 承認・拒否・取り消し・クライアントの接続のログ行は、署名者とクライアントの公開鍵を
/// 含む。
pub fn session_change_lines_name_the_signer_and_the_client_test() {
  assert admin.session_change_line(admin.ConnectionApproved, signer, client)
    == "approved the connection of client " <> client <> " to signer " <> signer
  assert admin.session_change_line(admin.ConnectionDenied, signer, client)
    == "denied the connection of client " <> client <> " to signer " <> signer
  assert admin.session_change_line(admin.SessionRevoked, signer, client)
    == "revoked the session of client " <> client <> " to signer " <> signer
  assert admin.session_change_line(admin.ClientConnected, signer, client)
    == "connected client " <> client <> " to signer " <> signer
}

/// 拒否は POST でしか受け付けない。
pub fn deny_rejects_other_methods_test() {
  assert get(context(), "/deny/" <> token).status == 405
}

/// 知らないパスは 404 の HTML で、理由を出し、パスを含めない。アカウントの一覧を
/// 引かない（503 にならない）ことで、`Context` を呼ばずに描画することを表す。
pub fn unknown_paths_are_not_found_test() {
  let response = get(with_accounts(Error(unavailable)), "/nope-path")
  assert response.status == 404
  let body = simulate.read_body(response)
  assert header(response, "content-type") == "text/html; charset=utf-8"
  assert string.contains(body, i18n.text(i18n.English, i18n.PageNotFound))
  assert !string.contains(body, "nope-path")
}

/// メソッドが違うリクエストは 405 の HTML で、`allow` を持ちメソッドとパスを本文に
/// 含めない。
pub fn method_not_allowed_pages_test() {
  let get_only_paths = ["/", "/accounts/new"]
  let post_only_paths = [
    "/language", "/theme", "/deny/tok", "/sessions/revoke", "/plugins/reenable",
    "/accounts/generate", "/accounts/import", "/accounts/register-generated",
  ]
  let both_methods_paths = [
    "/approve/tok",
    action_path(dashboard.EditLabel),
    "/relays/new",
    dashboard.relay_action_path(1, dashboard.EditRelayRoles),
    dashboard.relay_action_path(1, dashboard.DeleteRelay),
  ]
  let cases =
    list.flatten([
      list.map(post_only_paths, fn(path) { #(get(context(), path), "POST") }),
      list.map(get_only_paths, fn(path) { #(post(context(), path), "GET") }),
      list.map(both_methods_paths, fn(path) {
        #(
          simulate.request(http.Put, path)
            |> with_credentials("admin", password)
            |> admin.handle_request(context(), _),
          "GET, POST",
        )
      }),
    ])
  use #(response, allowed) <- list.each(cases)
  assert response.status == 405
  assert header(response, "allow") == allowed
  assert header(response, "content-type") == "text/html; charset=utf-8"
  let body = simulate.read_body(response)
  assert string.contains(
    body,
    i18n.text(i18n.English, i18n.MethodNotAllowedDetail),
  )
  assert string.contains(
    body,
    "<input name=\"return\" type=\"hidden\" value=\"/\">",
  )
}

/// 管理 UI のフォームからは送られない値（欄の欠落、未対応の言語とテーマ）は 400 の
/// HTML で、`FormNotReadable` の英文を出す。
pub fn bad_request_pages_test() {
  let responses = [
    post_form(context(), "/language", [#("language", "xx")]),
    post_form(context(), "/theme", [#("theme", "xx")]),
    post_form(context(), "/sessions/revoke", [#("signer", signer)]),
    post_form(context(), "/plugins/reenable", []),
  ]
  use response <- list.each(responses)
  assert response.status == 400
  assert header(response, "content-type") == "text/html; charset=utf-8"
  assert string.contains(
    simulate.read_body(response),
    i18n.text(i18n.English, i18n.FormNotReadable),
  )
}

/// 操作中に届かない応答は `text/plain` のまま。CSS への POST は 405、フォームの本文の
/// 無い登録は 415。401 と `/healthz` は他のテストが確かめる。
pub fn kept_plain_text_responses_test() {
  let method = post(context(), "/static/admin.css")
  assert method.status == 405
  assert simulate.read_body(method) == "Method not allowed"

  let unsupported_media =
    simulate.request(http.Post, "/accounts/import")
    |> with_credentials("admin", password)
    |> admin.handle_request(context(), _)
  assert unsupported_media.status == 415
  assert header(unsupported_media, "content-type") == "text/plain"
}

// --- リレーの追加 ---

/// GET は URL の欄が空で、両方のチェックボックスにチェックが入った状態で返す。
pub fn new_relay_page_checks_both_roles_test() {
  let body = simulate.read_body(get(context(), "/relays/new"))
  assert string.contains(
    body,
    "<form action=\"/relays/new\" class=\"flex flex-col gap-4\" method=\"post\">",
  )
  assert string.contains(
    body,
    "<input name=\"return\" type=\"hidden\" value=\"/relays/new\">",
  )
  assert string.contains(body, "name=\"url\"")
  assert string.contains(body, "value=\"\"")
  assert string.contains(body, "aria-describedby=\"relay-url-hint\"")
  assert string.contains(
    body,
    "<input checked class=\"checkbox border-base-content/60\" name=\"monitor\" type=\"checkbox\" value=\"on\">",
  )
  assert string.contains(
    body,
    "<input checked class=\"checkbox border-base-content/60\" name=\"bunker\" type=\"checkbox\" value=\"on\">",
  )
}

/// トリムした URL でリレーを追加し、ダッシュボードへ 303 で戻す。
pub fn add_relay_saves_the_trimmed_url_test() {
  let reports = process.new_subject()
  let response =
    post_form(reporting_context(reports), "/relays/new", [
      #("url", " wss://new.example "),
      #("monitor", "on"),
    ])
  assert response.status == 303
  assert header(response, "location") == "/"
  assert process.receive(reports, 1000)
    == Ok(RelayAdded(
      "wss://new.example",
      relay_list.Roles(monitor: True, bunker: False),
    ))
}

/// URL の規則に外れる値は 400 で `InvalidRelayUrl` を出し、送った URL とチェックを
/// 欄に保ち、Context を呼ばない。
pub fn add_relay_rejects_an_invalid_url_test() {
  let reports = process.new_subject()
  let invalid_urls = ["https://relay.example", "relay.example", "wss://"]
  use invalid_url <- list.each(invalid_urls)
  let response =
    post_form(reporting_context(reports), "/relays/new", [
      #("url", invalid_url),
      #("monitor", "on"),
    ])
  assert response.status == 400
  let body = simulate.read_body(response)
  assert string.contains(body, i18n.text(i18n.English, i18n.InvalidRelayUrl))
  assert string.contains(body, "value=\"" <> invalid_url <> "\"")
  assert string.contains(
    body,
    "<input checked class=\"checkbox border-base-content/60\" name=\"monitor\" type=\"checkbox\" value=\"on\">",
  )
  assert process.receive(reports, 100) == Error(Nil)
}

/// 用途を 1 つも選ばないと 400 で `RelayRoleRequired` を出し、URL を保ちつつ
/// チェックボックスはどちらも外れる。
pub fn add_relay_requires_a_role_test() {
  let reports = process.new_subject()
  let response =
    post_form(reporting_context(reports), "/relays/new", [
      #("url", "wss://relay.example"),
    ])
  assert response.status == 400
  let body = simulate.read_body(response)
  assert string.contains(body, i18n.text(i18n.English, i18n.RelayRoleRequired))
  assert string.contains(body, "value=\"wss://relay.example\"")
  assert !string.contains(body, "checked class=\"checkbox")
  assert process.receive(reports, 100) == Error(Nil)
}

/// Context が返す 4 変種ごとの状態コードと本文。重複と反映されたか分からない 2 つは
/// 訳した本文で、`RelayNotSaved` は英語の理由に日本語のページだけ前置きが付く。
pub fn add_relay_failures_test() {
  let not_saved_reason = "database is unreachable or rejected the connection"
  let expected_text = fn(language, failure) {
    case failure {
      admin.DuplicateRelay -> i18n.text(language, i18n.RelayAlreadyRegistered)
      admin.RelayNotSaved(reason) -> reason
      admin.RelayMaybeSaved -> i18n.text(language, i18n.StoreDidNotConfirm)
      admin.ConnectionsNotConfirmed ->
        i18n.text(language, i18n.RelayConnectionsNotConfirmed)
      admin.UnregisteredRelay -> i18n.text(language, i18n.RelayNotFound)
    }
  }
  let failures = [
    #(admin.DuplicateRelay, 409),
    #(admin.RelayNotSaved(not_saved_reason), 409),
    #(admin.RelayMaybeSaved, 202),
    #(admin.ConnectionsNotConfirmed, 202),
  ]
  let form = [#("url", "wss://relay.example"), #("monitor", "on")]
  use #(failure, status) <- list.each(failures)
  let failing =
    admin.Context(..context(), add_relay: fn(_url, _roles) { Error(failure) })
  let english = post_form(failing, "/relays/new", form)
  assert english.status == status
  assert string.contains(
    simulate.read_body(english),
    expected_text(i18n.English, failure),
  )

  let japanese =
    simulate.request(http.Post, "/relays/new")
    |> in_japanese
    |> with_credentials("admin", password)
    |> simulate.form_body(form)
    |> admin.handle_request(failing, _)
  assert japanese.status == status
  let japanese_body = simulate.read_body(japanese)
  assert string.contains(japanese_body, expected_text(i18n.Japanese, failure))
  case failure {
    admin.RelayNotSaved(_) -> {
      let assert Some(prefix) = i18n.lead(i18n.Japanese, i18n.CouldNotAddRelay)
      assert string.contains(japanese_body, prefix)
    }
    _ -> Nil
  }
}

// --- リレーの用途の編集と削除 ---

/// 用途の編集の GET は 200 で、フォームの action と return は自分のパス、URL を `dd` で
/// 出し、保存済みの用途（監視だけ）にチェックが入る。
pub fn edit_relay_page_checks_the_saved_roles_test() {
  let path = dashboard.relay_action_path(1, dashboard.EditRelayRoles)
  let response = get(context(), path)
  assert response.status == 200
  let body = simulate.read_body(response)
  assert string.contains(
    body,
    "<form action=\""
      <> path
      <> "\" class=\"flex flex-col gap-4\" method=\"post\">",
  )
  assert string.contains(
    body,
    "<input name=\"return\" type=\"hidden\" value=\"" <> path <> "\">",
  )
  assert string.contains(
    body,
    "<dd class=\"font-mono text-xs break-all\">wss://relay.example</dd>",
  )
  assert string.contains(
    body,
    "<input checked class=\"checkbox border-base-content/60\" name=\"monitor\" type=\"checkbox\" value=\"on\">",
  )
  assert !string.contains(
    body,
    "<input checked class=\"checkbox border-base-content/60\" name=\"bunker\" type=\"checkbox\" value=\"on\">",
  )
}

/// 用途の編集の POST は id とチェックを Context に渡し、ダッシュボードへ 303 で戻す。
pub fn update_relay_roles_saves_the_roles_test() {
  let reports = process.new_subject()
  let response =
    post_form(
      reporting_context(reports),
      dashboard.relay_action_path(2, dashboard.EditRelayRoles),
      [#("monitor", "on"), #("bunker", "on")],
    )
  assert response.status == 303
  assert header(response, "location") == "/"
  assert process.receive(reports, 1000)
    == Ok(RelayRolesUpdated(2, relay_list.Roles(monitor: True, bunker: True)))
}

/// 用途を 1 つも選ばない POST は 400 で `RelayRoleRequired` を出し、チェックは無く、
/// Context を呼ばない。
pub fn update_relay_roles_requires_a_role_test() {
  let reports = process.new_subject()
  let response =
    post_form(
      reporting_context(reports),
      dashboard.relay_action_path(1, dashboard.EditRelayRoles),
      [],
    )
  assert response.status == 400
  let body = simulate.read_body(response)
  assert string.contains(body, i18n.text(i18n.English, i18n.RelayRoleRequired))
  assert !string.contains(body, "checked class=\"checkbox")
  assert process.receive(reports, 100) == Error(Nil)
}

/// 削除のページは URL を `dd` で出し、送信ボタンは注意の重さ。POST は id を Context に
/// 渡し、ダッシュボードへ 303 で戻す。
pub fn delete_relay_page_and_submit_test() {
  let path = dashboard.relay_action_path(2, dashboard.DeleteRelay)
  let body = simulate.read_body(get(context(), path))
  assert string.contains(
    body,
    "<dd class=\"font-mono text-xs break-all\">wss://bunker.example</dd>",
  )
  assert string.contains(body, "btn-warning")

  let reports = process.new_subject()
  let response = post(reporting_context(reports), path)
  assert response.status == 303
  assert header(response, "location") == "/"
  assert process.receive(reports, 1000) == Ok(RelayDeleted(2))
}

/// 一覧に無い id への操作の GET と POST は 404 で `RelayNotFound` を出し、Context の
/// 変更を呼ばない。
pub fn relay_action_for_an_unknown_id_is_not_found_test() {
  let reports = process.new_subject()
  let paths = [
    dashboard.relay_action_path(99, dashboard.EditRelayRoles),
    dashboard.relay_action_path(99, dashboard.DeleteRelay),
  ]
  use path <- list.each(paths)
  let get_response = get(reporting_context(reports), path)
  assert #(path, get_response.status) == #(path, 404)
  assert string.contains(
    simulate.read_body(get_response),
    i18n.text(i18n.English, i18n.RelayNotFound),
  )
  let post_response = post(reporting_context(reports), path)
  assert #(path, post_response.status) == #(path, 404)
  assert process.receive(reports, 100) == Error(Nil)
}

/// 整数でない id は、DB の一覧を引かずに 404 の `PageNotFound` にする。
pub fn relay_action_with_a_non_integer_id_is_not_found_test() {
  let failing =
    admin.Context(..context(), registered_relays: fn() { Error("boom") })
  let response = get(failing, "/relays/abc/edit")
  assert response.status == 404
  assert string.contains(
    simulate.read_body(response),
    i18n.text(i18n.English, i18n.PageNotFound),
  )
}

/// DB の一覧を得られなければ、操作の GET は 503 で `RelaysNotAvailable` と理由を出す。
pub fn relay_action_without_registered_relays_is_unavailable_test() {
  let failing =
    admin.Context(..context(), registered_relays: fn() { Error("boom") })
  let paths = [
    dashboard.relay_action_path(1, dashboard.EditRelayRoles),
    dashboard.relay_action_path(1, dashboard.DeleteRelay),
  ]
  use path <- list.each(paths)
  let response = get(failing, path)
  assert #(path, response.status) == #(path, 503)
  let body = simulate.read_body(response)
  assert string.contains(body, i18n.text(i18n.English, i18n.RelaysNotAvailable))
  assert string.contains(body, "boom")
}

/// Context が返す変種ごとの状態コードと本文。編集と削除のどちらでも、対象の行が無い
/// （`UnregisteredRelay`）は 404、反映されたか分からない 2 つは訳した本文で 202、
/// `RelayNotSaved` は日本語のページだけ前置き（`CouldNotSaveRelay`、`CouldNotDeleteRelay`）が
/// 付く。
pub fn relay_change_failures_test() {
  let not_saved_reason = "database is unreachable or rejected the connection"
  let expected_text = fn(language, failure) {
    case failure {
      admin.UnregisteredRelay -> i18n.text(language, i18n.RelayNotFound)
      admin.RelayNotSaved(reason) -> reason
      admin.RelayMaybeSaved -> i18n.text(language, i18n.StoreDidNotConfirm)
      admin.ConnectionsNotConfirmed ->
        i18n.text(language, i18n.RelayConnectionsNotConfirmed)
      admin.DuplicateRelay -> i18n.text(language, i18n.RelayAlreadyRegistered)
    }
  }
  let failures = [
    #(admin.UnregisteredRelay, 404),
    #(admin.RelayNotSaved(not_saved_reason), 409),
    #(admin.RelayMaybeSaved, 202),
    #(admin.ConnectionsNotConfirmed, 202),
  ]
  let cases = [
    #(
      dashboard.relay_action_path(1, dashboard.EditRelayRoles),
      [#("monitor", "on")],
      i18n.CouldNotSaveRelay,
    ),
    #(
      dashboard.relay_action_path(1, dashboard.DeleteRelay),
      [],
      i18n.CouldNotDeleteRelay,
    ),
  ]
  use #(path, form, lead) <- list.each(cases)
  use #(failure, status) <- list.each(failures)
  let failing =
    admin.Context(
      ..context(),
      update_relay_roles: fn(_relay, _roles) { Error(failure) },
      delete_relay: fn(_relay) { Error(failure) },
    )
  let english = post_form(failing, path, form)
  assert #(path, failure, english.status) == #(path, failure, status)
  assert string.contains(
    simulate.read_body(english),
    expected_text(i18n.English, failure),
  )

  let japanese =
    simulate.request(http.Post, path)
    |> in_japanese
    |> with_credentials("admin", password)
    |> simulate.form_body(form)
    |> admin.handle_request(failing, _)
  assert #(path, failure, japanese.status) == #(path, failure, status)
  let japanese_body = simulate.read_body(japanese)
  assert string.contains(japanese_body, expected_text(i18n.Japanese, failure))
  case failure {
    admin.RelayNotSaved(_) -> {
      let assert Some(prefix) = i18n.lead(i18n.Japanese, lead)
      assert string.contains(japanese_body, prefix)
    }
    _ -> Nil
  }
}

// --- クライアントの接続 ---

/// 有効な `nostrconnect://` の URI。クライアント公開鍵は 32 バイトの 16 進、`relay` と
/// `secret` を 1 つずつ持つ。
const connect_uri = "nostrconnect://1111111111111111111111111111111111111111111111111111111111111111?relay=wss://relay.example&secret=abcdef"

/// URI に現れるクライアント公開鍵。
const connect_client_pubkey = "1111111111111111111111111111111111111111111111111111111111111111"

/// GET は 200 で、署名者の選択欄に登録済みの署名者が選択済みで出る。
pub fn connect_client_page_lists_accounts_test() {
  let response = get(context(), "/sessions/connect")
  assert response.status == 200
  let body = simulate.read_body(response)
  assert string.contains(
    body,
    "name=\"" <> dashboard.nostrconnect_uri_field <> "\"",
  )
  assert string.contains(body, "<option selected value=\"" <> signer <> "\">")
}

/// `nostrconnect://` で始まらない URI の POST は 400 で、送った URI をフォームに残し、
/// Context を呼ばない。
pub fn connect_client_rejects_a_bad_uri_test() {
  let reports = process.new_subject()
  let response =
    post_form(reporting_context(reports), "/sessions/connect", [
      #("uri", "not-a-uri"),
      #("signer", signer),
    ])
  assert response.status == 400
  let body = simulate.read_body(response)
  assert string.contains(body, i18n.text(i18n.English, i18n.NotNostrconnectUri))
  assert string.contains(body, ">not-a-uri</textarea>")
  assert process.receive(reports, 100) == Error(Nil)
}

/// 一覧に無い署名者への POST は 400 で、Context の `connect_client` を呼ばない。
pub fn connect_client_rejects_an_unknown_signer_test() {
  let reports = process.new_subject()
  let response =
    post_form(reporting_context(reports), "/sessions/connect", [
      #("uri", connect_uri),
      #("signer", unknown_client),
    ])
  assert response.status == 400
  assert string.contains(
    simulate.read_body(response),
    i18n.text(i18n.English, i18n.SigningAccountNotFound),
  )
  assert process.receive(reports, 100) == Error(Nil)
}

/// 正しい URI の POST は Context の `connect_client` を呼び、303 でダッシュボードへ
/// 戻る。渡す値は URI のクライアント公開鍵と、フォームで選んだ署名者。
pub fn connect_client_opens_the_session_test() {
  let reports = process.new_subject()
  let response =
    post_form(reporting_context(reports), "/sessions/connect", [
      #("uri", connect_uri),
      #("signer", signer),
    ])
  assert response.status == 303
  assert header(response, "location") == "/"
  let assert Ok(ClientConnectRequested(request: connect_request, signer: sent)) =
    process.receive(reports, 1000)
  assert connect_request.client == connect_client_pubkey
  assert sent == signer
}

/// `connect_client` が受け付けなかった、または反映されていない失敗は、フォームを
/// 描き直す状態コードになる。`RelayNotRegistered` はリレーの変更の失敗と同じ
/// `relay_failure_response` に渡る。
pub fn connect_client_redraws_on_failure_test() {
  let failures = [
    #(admin.RelayNotConnected, 503),
    #(admin.RelayNotRegistered(admin.DuplicateRelay), 409),
  ]
  use #(failure, status) <- list.each(failures)
  let failing =
    admin.Context(..context(), connect_client: fn(_request, _signer) {
      Error(failure)
    })
  let response =
    post_form(failing, "/sessions/connect", [
      #("uri", connect_uri),
      #("signer", signer),
    ])
  assert response.status == status
  assert string.contains(
    simulate.read_body(response),
    "name=\"" <> dashboard.nostrconnect_uri_field <> "\"",
  )
}

/// バンカーが反映されたか確かめられなかったときは、202 の「変更を確認できませんでした」の
/// ページになる。
pub fn connect_client_reports_an_unconfirmed_change_test() {
  let failing =
    admin.Context(..context(), connect_client: fn(_request, _signer) {
      Error(
        admin.SessionNotOpened(bunker.SessionMaybeApplied(
          bunker.StoreDidNotConfirm,
        )),
      )
    })
  let response =
    post_form(failing, "/sessions/connect", [
      #("uri", connect_uri),
      #("signer", signer),
    ])
  assert response.status == 202
  let body = simulate.read_body(response)
  assert string.contains(body, i18n.text(i18n.English, i18n.ChangeNotConfirmed))
  assert string.contains(body, i18n.text(i18n.English, i18n.StoreDidNotConfirm))
}

// --- 静的ファイルと通知の色 ---

/// ページはビルドした CSS とスクリプトを読む。どちらも認証の後に置き、ファイルの種類の
/// `content-type` で返す（`nosniff` の下では、スクリプトは JS の型でないと実行されない）。
pub fn static_files_are_served_behind_authentication_test() {
  let page = simulate.read_body(get(context(), "/"))
  assert string.contains(
    page,
    "<link href=\"/static/admin.css\" rel=\"stylesheet\"><script src=\"/static/admin.js\" type=\"module\"></script>",
  )
  let files = [
    #("/static/admin.css", "text/css; charset=utf-8", ".btn{"),
    #("/static/admin.js", "text/javascript; charset=utf-8", "const actions = {"),
  ]
  use #(path, content_type, excerpt) <- list.each(files)
  let response = get(context(), path)
  assert response.status == 200
  assert header(response, "content-type") == content_type
  assert string.contains(simulate.read_body(response), excerpt)
  let anonymous =
    simulate.request(http.Get, path)
    |> admin.handle_request(context(), _)
  assert anonymous.status == 401
}

/// 配信するのはスタイルシートとスクリプトだけで、GET 以外は受け付けない。
pub fn only_the_static_files_are_served_test() {
  assert get(context(), "/static/other.css").status == 404
  assert get(context(), "/static/other.js").status == 404
  assert get(context(), "/static").status == 404
  assert post(context(), "/static/admin.css").status == 405
  assert post(context(), "/static/admin.js").status == 405
}

/// 通知ページの理由の囲みは、カードの中に結果ごとの色で出す。承認と拒否はどちらも 200
/// なので、状態コードではなく経路で色が決まる。
pub fn notices_are_colored_by_outcome_test() {
  let rotate = action_path(dashboard.RotateSecret)
  let notices = [
    #(
      post(context(), "/approve/" <> token),
      "alert alert-soft alert-success text-base-content",
    ),
    #(post(context(), "/deny/" <> token), "alert alert-soft text-base-content"),
    #(
      post(context(), "/approve/other-token"),
      "alert alert-soft alert-error text-base-content",
    ),
    #(
      post(
        failing_context(bunker.MaybeApplied(bunker.StoreDidNotConfirm)),
        rotate,
      ),
      "alert alert-soft alert-warning text-base-content",
    ),
    #(
      post(
        failing_context(bunker.NotReady("accounts are not loaded yet")),
        rotate,
      ),
      "alert alert-soft alert-warning text-base-content",
    ),
    #(
      post_form(context(), "/sessions/revoke", [
        #("signer", signer),
        #("client", unknown_client),
      ]),
      "alert alert-soft alert-error text-base-content",
    ),
    #(
      post_form(not_answering_context(), "/sessions/revoke", [
        #("signer", signer),
        #("client", client),
      ]),
      "alert alert-soft alert-warning text-base-content",
    ),
  ]
  list.each(notices, fn(entry) {
    let #(response, class) = entry
    assert string.contains(
      simulate.read_body(response),
      "<div class=\"card-body gap-4 p-4 sm:p-6\"><div class=\""
        <> class
        <> "\">",
    )
  })
}

// --- 表示のテーマ ---

/// 応答のページの `<html>` の `data-theme` の値。`System` では出ないので `None`。
fn page_theme(response: Response(wisp.Body)) -> Option(String) {
  let assert Ok(#(_before, rest)) =
    string.split_once(simulate.read_body(response), "<html")
  let assert Ok(#(tag, _after)) = string.split_once(rest, ">")
  case string.split_once(tag, "data-theme=\"") {
    Ok(#(_before, rest)) -> {
      let assert Ok(#(theme, _after)) = string.split_once(rest, "\"")
      Some(theme)
    }
    Error(Nil) -> None
  }
}

/// テーマの切り替えの POST を、同じオリジンのブラウザーから送ったリクエスト。
fn theme_switch_request(fields: List(#(String, String))) -> wisp.Request {
  simulate.browser_request(http.Post, "/theme")
  |> with_credentials("admin", password)
  |> simulate.form_body(fields)
}

/// 表示のテーマは、切り替えで保存した cookie から決め、cookie が無いか対応していない
/// 値ならブラウザーの設定（`data-theme` を出さない）にする。
pub fn theme_follows_the_cookie_test() {
  let cases = [
    #([], None),
    #([#("cookie", "nostr_no_su_theme=light")], Some("light")),
    #([#("cookie", "nostr_no_su_theme=dark")], Some("dark")),
    #([#("cookie", "nostr_no_su_theme=system")], None),
    #([#("cookie", "nostr_no_su_theme=blue")], None),
  ]
  use #(headers, theme) <- list.each(cases)
  let response =
    list.fold(
      headers,
      simulate.request(http.Get, "/") |> with_credentials("admin", password),
      fn(request, header) { request.set_header(request, header.0, header.1) },
    )
    |> admin.handle_request(context(), _)
  assert #(headers, page_theme(response)) == #(headers, theme)
}

/// テーマの切り替えは、選んだテーマを cookie に保存し、フォームが送った戻り先へ 303 で戻す。
pub fn theme_switch_saves_the_theme_and_returns_test() {
  let cases = [
    #(
      "light",
      "nostr_no_su_theme=light; Max-Age=31536000; Path=/; HttpOnly; SameSite=Lax",
    ),
    #(
      "dark",
      "nostr_no_su_theme=dark; Max-Age=31536000; Path=/; HttpOnly; SameSite=Lax",
    ),
  ]
  use #(theme, cookie) <- list.each(cases)
  let response =
    theme_switch_request([#("theme", theme), #("return", "/accounts/new")])
    |> admin.handle_request(context(), _)
  assert response.status == 303
  assert header(response, "location") == "/accounts/new"
  assert header(response, "set-cookie") == cookie
  assert header(response, "cache-control") == "no-store"
}

/// ブラウザーの設定への切り替えは cookie を消す。
pub fn theme_switch_to_the_browser_setting_clears_the_cookie_test() {
  let response =
    theme_switch_request([#("theme", "system"), #("return", "/")])
    |> admin.handle_request(context(), _)
  assert response.status == 303
  assert header(response, "set-cookie")
    == "nostr_no_su_theme=; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Max-Age=0; Path=/; HttpOnly; SameSite=Lax"
}

/// 対応していないテーマ、GET、別のオリジンからの切り替え、資格情報の無い切り替えは
/// 受け付けず、cookie を保存しない。
pub fn theme_switch_rejects_invalid_requests_test() {
  let rejected = [
    #(
      theme_switch_request([#("theme", "blue"), #("return", "/")])
        |> admin.handle_request(context(), _),
      400,
    ),
    #(
      theme_switch_request([#("return", "/")])
        |> admin.handle_request(context(), _),
      400,
    ),
    #(get(context(), "/theme"), 405),
    #(
      theme_switch_request([#("theme", "dark"), #("return", "/")])
        |> request.set_header("origin", "http://evil.example")
        |> admin.handle_request(context(), _),
      400,
    ),
    #(
      simulate.browser_request(http.Post, "/theme")
        |> simulate.form_body([#("theme", "dark"), #("return", "/")])
        |> admin.handle_request(context(), _),
      401,
    ),
  ]
  use #(response, status) <- list.each(rejected)
  assert response.status == status
  assert list.key_find(response.headers, "set-cookie") == Error(Nil)
}

/// 切り替えたテーマは、GET のページにも、秘密鍵を出す `NoSwitch` のページにも保たれる。
pub fn switched_theme_carries_across_pages_test() {
  let switch = theme_switch_request([#("theme", "dark"), #("return", "/")])
  let switched = admin.handle_request(context(), switch)
  let new_account =
    simulate.browser_request(http.Get, "/accounts/new")
    |> with_credentials("admin", password)
    |> simulate.session(switch, switched)
    |> admin.handle_request(context(), _)
  assert page_theme(new_account) == Some("dark")
  let generated =
    simulate.browser_request(http.Post, "/accounts/generate")
    |> with_credentials("admin", password)
    |> simulate.session(switch, switched)
    |> admin.handle_request(context(), _)
  assert page_theme(generated) == Some("dark")
}

/// 秘密鍵を描画するページにはテーマと言語の切り替えを出さず、ほかのページには出す。
pub fn pages_with_a_private_key_have_no_switches_test() {
  let hidden = [
    post(context(), "/accounts/generate"),
    post_form(context(), "/accounts/import", [
      #("nsec", spec_nsec),
      #("label", "work"),
    ]),
    post_form(context(), "/accounts/register-generated", [
      #("nsec", spec_nsec),
      #("label", "a\tb"),
    ]),
    post_form(context(), action_path(dashboard.RevealPrivateKey), [
      #("password", password),
    ]),
  ]
  list.each(hidden, fn(response) {
    assert response.status == 200 || response.status == 400
    let body = simulate.read_body(response)
    assert string.contains(
      body,
      "<div class=\"navbar-end w-auto gap-2\"></div>",
    )
    assert !string.contains(body, "action=\"/theme\"")
    assert !string.contains(body, "action=\"/language\"")
  })
  let shown = [
    get(context(), "/"),
    get(context(), "/accounts/new"),
    get(context(), "/approve/" <> token),
    post(context(), "/approve/" <> token),
    post_form(
      failing_context(bunker.MaybeApplied(bunker.StoreDidNotConfirm)),
      action_path(dashboard.RotateSecret),
      [],
    ),
    ..list.map(account_actions.all, fn(action) {
      get(context(), action_path(action))
    })
  ]
  list.each(shown, fn(response) {
    let body = simulate.read_body(response)
    assert string.contains(body, "action=\"/theme\"")
    assert string.contains(body, "action=\"/language\"")
  })
}
