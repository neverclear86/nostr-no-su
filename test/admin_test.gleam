//// 管理 UI のルートのテスト。`Context` に偽の関数を注入し、アクターを起動せずに
//// 応答を確かめる。

import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{Some}
import gleam/string
import nostr_no_su/admin
import nostr_no_su/admin/dashboard
import nostr_no_su/bunker
import nostr_no_su/bunker/account
import nostr_no_su/bunker/engine
import nostr_no_su/nostr/nip19
import nostr_no_su/plugin_runner
import nostr_no_su/relay_connection
import support/account_actions
import support/nip46_client.{account_for}
import wisp
import wisp/simulate

const password = "s3cr3t-password"

/// 登録済みのアカウントの署名者。BIP-340 の公式ベクター 0 の公開鍵。
const signer = "f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9"

/// 登録済みのアカウントの npub。
const signer_npub = "npub1lycg5qvjtrp3qjf5f7zl382j9x6nrjz9sdhenvyxq8c3808qxmus6gq266"

/// 登録済みのアカウントの nsec（BIP-340 の公式ベクター 0 の秘密鍵）。
const signer_nsec = "nsec1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqps52s3re"

/// 未登録のアカウントとして登録に使う、NIP-19 の仕様の nsec。
const spec_nsec = "nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5"

/// `spec_nsec` の秘密鍵の 16 進。
const spec_key = "67dea2ed018072d675f5415ecfaed7d2597555e202d85b3d65ea4e58d2d92ffa"

const client = "bbbb2222"

/// 承認済みのセッションを持たないクライアント。
const unknown_client = "cccc3333"

/// フェイクの取り消しが、承認済みでない組に返す理由。
const session_not_approved = "session is not approved"

/// フェイクの取り消しが、バンカーの無応答として返す理由。
const not_answered = "the bunker did not respond"

/// 無効化されたプラグインの理由。プラグイン由来の文字列なので HTML への埋め込み
/// でエスケープされなければならない。
const disabled_reason = "error:<script>alert(1)</script>"

/// 承認待ちのトークン。フェイクの承認・拒否はこれだけを知っている。
const token = "tok-1"

/// アカウントの接続 URI（secret 入りと、承認を経るもの）。
const uri = "bunker://f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9?relay=x&secret=s"

const auth_uri = "bunker://f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9?relay=x"

/// アカウントのラベル。
const label = "main account"

/// DB の障害でアカウントの一覧を得られないときの理由。本物の一覧の文言に合わせる。
const unavailable = "account store unavailable: database is unreachable or rejected the connection"

/// フェイクのハンドラーがテストへ報告する内容。
type Report {
  Revoked(signer: String, client: String)
  Approved(token: String)
  Denied(token: String)
  Added(signer: String, label: String)
  Removed(signer: String)
  Rotated(signer: String)
  Relabeled(signer: String, label: String)
  NsecRequested(signer: String)
}

/// 指定したラベルを持つ、登録済みのアカウントの行。
fn account_row(row_label: String) -> dashboard.AccountRow {
  dashboard.AccountRow(
    signer: signer,
    npub: signer_npub,
    label: row_label,
    uri: uri,
    auth_uri: auth_uri,
  )
}

/// 状態をすべて即値で持つ Context。アクターを起動せずにルートを検証できる。
/// 監視リレーの URL だけはエスケープの検証のために差し替えられる。アカウントの変更は
/// 報告したうえで成功し、登録済みの公開鍵の追加だけを拒否する。
fn test_context(
  reports: Subject(Report),
  monitor_relay_url: String,
) -> admin.Context {
  admin.Context(
    password: password,
    accounts: fn() { Ok([account_row(label)]) },
    add_account: fn(added, added_label) {
      let added_signer = account.pubkey_hex(added)
      process.send(reports, Added(added_signer, added_label))
      case added_signer == signer {
        True -> Error(bunker.NotApplied("account is already registered"))
        False -> Ok(Nil)
      }
    },
    remove_account: fn(removed) {
      process.send(reports, Removed(removed))
      Ok(Nil)
    },
    rotate_secret: fn(rotated) {
      process.send(reports, Rotated(rotated))
      Ok(Nil)
    },
    update_label: fn(relabeled, new_label) {
      process.send(reports, Relabeled(relabeled, new_label))
      Ok(Nil)
    },
    nsec: fn(requested) {
      process.send(reports, NsecRequested(requested))
      Ok(signer_nsec)
    },
    relays: fn() {
      [
        dashboard.RelayRow(
          role: dashboard.MonitorRelay,
          url: monitor_relay_url,
          status: relay_connection.Connected,
        ),
        dashboard.RelayRow(
          role: dashboard.BunkerRelay,
          url: "wss://bunker.example",
          status: relay_connection.Disconnected,
        ),
      ]
    },
    plugins: fn() {
      [
        dashboard.PluginRow(
          name: "console_logger",
          status: Some(plugin_runner.Running),
        ),
        // 無効化の理由はプラグイン由来の文字列なので、素のまま出てはならない。
        dashboard.PluginRow(
          name: "broken",
          status: Some(plugin_runner.Disabled(
            reason: disabled_reason,
            dropped: 3,
          )),
        ),
      ]
    },
    sessions: fn() { [engine.Session(signer: signer, client: client)] },
    revoke: fn(revoked_signer, revoked_client) {
      process.send(
        reports,
        Revoked(signer: revoked_signer, client: revoked_client),
      )
      case revoked_signer == signer && revoked_client == client {
        True -> Ok(Nil)
        False -> Error(bunker.SessionNotFound(session_not_approved))
      }
    },
    pending: fn() {
      [
        dashboard.PendingRow(
          token: token,
          signer: signer,
          client: client,
          age_seconds: 12,
        ),
      ]
    },
    approve: fn(decided) {
      record_decision(reports, Approved(decided), decided)
    },
    deny: fn(decided) { record_decision(reports, Denied(decided), decided) },
  )
}

/// 承認・拒否のフェイク。テストへ報告したうえで、知っているトークンだけを成功と
/// して扱う。
fn record_decision(
  reports: Subject(Report),
  report: Report,
  decided: String,
) -> Result(Nil, String) {
  process.send(reports, report)
  case decided == token {
    True -> Ok(Nil)
    False -> Error("unknown or expired approval request")
  }
}

/// 状態を変える操作を報告する Context。
fn reporting_context(reports: Subject(Report)) -> admin.Context {
  test_context(reports, "wss://relay.example")
}

/// 報告を捨てる Context。操作を観測しないテスト向け。
fn context() -> admin.Context {
  reporting_context(process.new_subject())
}

/// アカウントの変更がすべて指定した失敗を返す Context。
fn failing_context(failure: bunker.ChangeFailure) -> admin.Context {
  admin.Context(
    ..context(),
    add_account: fn(_added, _label) { Error(failure) },
    remove_account: fn(_signer) { Error(failure) },
    rotate_secret: fn(_signer) { Error(failure) },
    update_label: fn(_signer, _label) { Error(failure) },
  )
}

/// 認証済みの POST リクエストを 1 件処理する。本文は空で、承認・拒否はパスの
/// トークンだけで決まる。
fn post(context: admin.Context, path: String) -> Response(wisp.Body) {
  simulate.request(http.Post, path)
  |> with_credentials("admin", context.password)
  |> admin.handle_request(context, _)
}

/// 認証済みのフォームの POST リクエストを 1 件処理する。
fn post_form(
  context: admin.Context,
  path: String,
  fields: List(#(String, String)),
) -> Response(wisp.Body) {
  simulate.request(http.Post, path)
  |> with_credentials("admin", context.password)
  |> simulate.form_body(fields)
  |> admin.handle_request(context, _)
}

/// Basic 認証のヘッダーを付けたリクエスト。
fn with_credentials(
  request: wisp.Request,
  user: String,
  password: String,
) -> wisp.Request {
  let credentials =
    bit_array.from_string(user <> ":" <> password)
    |> bit_array.base64_encode(True)
  request.set_header(request, "authorization", "Basic " <> credentials)
}

/// 認証済みの GET リクエストを 1 件処理する。
fn get(context: admin.Context, path: String) -> Response(wisp.Body) {
  simulate.request(http.Get, path)
  |> with_credentials("admin", context.password)
  |> admin.handle_request(context, _)
}

/// 応答ヘッダーの値。存在しなければテストを失敗させる。
fn header(response: Response(wisp.Body), name: String) -> String {
  let assert Ok(value) = list.key_find(response.headers, name)
  value
}

/// 登録済みのアカウントへの操作のパス。
fn action_path(action: dashboard.AccountAction) -> String {
  dashboard.account_action_path(signer, action)
}

/// 生成の確認ページの隠しフィールドの nsec。
fn hidden_nsec(body: String) -> String {
  let assert Ok(#(_before, rest)) =
    string.split_once(body, "name=\"nsec\" type=\"hidden\" value=\"")
  let assert Ok(#(nsec, _after)) = string.split_once(rest, "\"")
  nsec
}

/// nsec から作ったアカウントの公開鍵の 16 進。
fn nsec_signer(nsec: String) -> String {
  let assert Ok(privkey) = nip19.decode(nsec, nip19.Nsec)
  let assert Ok(decoded) = account.from_privkey(privkey)
  account.pubkey_hex(decoded)
}

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
  assert string.contains(body, "<td class=\"whitespace-nowrap\">monitor</td>")
  assert string.contains(
    body,
    "<span class=\"badge badge-sm badge-success whitespace-nowrap\">connected</span>",
  )
  assert string.contains(body, "<td class=\"whitespace-nowrap\">bunker</td>")
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

/// バンカーが応答しない取り消しは 503 で、理由とダッシュボードへのリンクを出す。
pub fn revoke_that_is_not_answered_is_unavailable_test() {
  let response =
    post_form(not_answering_context(), "/sessions/revoke", [
      #("signer", signer),
      #("client", client),
    ])
  assert response.status == 503
  let body = simulate.read_body(response)
  assert string.contains(body, "Change not confirmed")
  assert string.contains(body, not_answered)
  assert string.contains(body, "Back to dashboard")
}

/// 取り消しにバンカーが応答しない Context。
fn not_answering_context() -> admin.Context {
  admin.Context(..context(), revoke: fn(_signer, _client) {
    Error(bunker.NotAnswered(not_answered))
  })
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

/// ダッシュボードには承認待ちと、承認を経る接続 URI も出る。
pub fn dashboard_shows_pending_connections_test() {
  let body = simulate.read_body(get(context(), "/"))
  assert string.contains(body, "value=\"" <> auth_uri <> "\"")
  assert string.contains(body, "action=\"/approve/" <> token <> "\"")
  assert string.contains(body, "action=\"/deny/" <> token <> "\"")
  assert string.contains(body, "<dd class=\"break-words\">12s</dd>")
}

/// 承認ページには、誰が誰に接続しようとしているかが出る。
pub fn approval_page_shows_the_request_test() {
  let response = get(context(), "/approve/" <> token)
  assert response.status == 200
  let body = simulate.read_body(response)
  assert string.contains(body, signer)
  assert string.contains(body, client)
  assert string.contains(body, "<dd class=\"break-words\">12s</dd>")
}

/// 知らない、あるいは失効したトークンの承認ページは 404。
pub fn approval_page_for_an_unknown_token_is_not_found_test() {
  assert get(context(), "/approve/other-token").status == 404
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

/// 処理できなかった承認・拒否は 404。承認待ちはすでに無い。
pub fn deciding_an_unknown_token_is_not_found_test() {
  assert post(context(), "/approve/other-token").status == 404
  assert post(context(), "/deny/other-token").status == 404
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

/// 拒否は POST でしか受け付けない。
pub fn deny_rejects_other_methods_test() {
  assert get(context(), "/deny/" <> token).status == 405
}

/// 指定したアカウントの一覧を返す Context。
fn with_accounts(
  accounts: Result(List(dashboard.AccountRow), String),
) -> admin.Context {
  admin.Context(..context(), accounts: fn() { accounts })
}

/// ダッシュボードのアカウントの節には、ラベルが出る。
pub fn dashboard_shows_account_labels_test() {
  let body = simulate.read_body(get(context(), "/"))
  assert string.contains(
    body,
    "<p class=\"font-semibold break-words\">" <> label <> "</p>",
  )
}

/// アカウントの節の理由とラベルは、どちらもエスケープする。ラベルは利用者の入力で、
/// 理由には外から来た文字列が混ざりうる。
pub fn dashboard_escapes_account_labels_and_reasons_test() {
  let script = "<script>alert(1)</script>"
  let escaped = "&lt;script&gt;alert(1)&lt;/script&gt;"
  let labelled =
    simulate.read_body(get(with_accounts(Ok([account_row(script)])), "/"))
  assert string.contains(
    labelled,
    "<p class=\"font-semibold break-words\">" <> escaped <> "</p>",
  )
  assert !string.contains(labelled, script)

  let failing = simulate.read_body(get(with_accounts(Error(script)), "/"))
  assert string.contains(
    failing,
    "<div class=\"alert\"><span><span lang=\"en\">"
      <> escaped
      <> "</span></span></div>",
  )
  assert !string.contains(failing, script)
}

/// アカウントが 1 件も無ければ、その旨を出す。
pub fn dashboard_shows_that_no_accounts_are_registered_test() {
  let body = simulate.read_body(get(with_accounts(Ok([])), "/"))
  assert string.contains(body, "No accounts registered.")
}

/// 知らないパスは 404。認証は先に通っている。
pub fn unknown_paths_are_not_found_test() {
  assert get(context(), "/nope").status == 404
}

// --- アカウントの登録 ---

/// nsec とラベルの POST で登録し、完了ページに正規の nsec と npub を 1 回出す。
/// ラベルは前後の空白を除いて渡す。
pub fn import_registers_an_account_test() {
  let reports = process.new_subject()
  let response =
    post_form(reporting_context(reports), "/accounts/import", [
      #("nsec", spec_nsec),
      #("label", " work "),
    ])
  assert response.status == 200
  let body = simulate.read_body(response)
  let registered = account_for(spec_key)
  assert string.contains(body, spec_nsec)
  assert string.contains(body, account.npub(registered))
  assert process.receive(reports, 1000)
    == Ok(Added(account.pubkey_hex(registered), "work"))
}

/// 前後に空白を付けて大文字にした nsec でも、完了ページの nsec は小文字の正規の表記。
pub fn import_normalizes_the_nsec_test() {
  let sent = " " <> string.uppercase(spec_nsec) <> "\n"
  let body =
    simulate.read_body(
      post_form(context(), "/accounts/import", [#("nsec", sent)]),
    )
  assert string.contains(body, spec_nsec)
  assert !string.contains(body, string.uppercase(spec_nsec))
}

/// チェックサムの壊れた nsec は 400 で、送った文字列を応答に含めず、登録しない。
pub fn import_rejects_an_invalid_nsec_test() {
  let reports = process.new_subject()
  let broken = string.drop_end(spec_nsec, 1) <> "4"
  let response =
    post_form(reporting_context(reports), "/accounts/import", [
      #("nsec", broken),
    ])
  assert response.status == 400
  let body = simulate.read_body(response)
  assert string.contains(body, "invalid bech32 checksum")
  assert !string.contains(body, broken)
  assert process.receive(reports, 100) == Error(Nil)
}

/// npub は nsec として受け付けない。
pub fn import_rejects_an_npub_test() {
  let response =
    post_form(context(), "/accounts/import", [#("nsec", signer_npub)])
  assert response.status == 400
  assert string.contains(simulate.read_body(response), "expected nsec prefix")
}

/// 範囲外の秘密鍵（0）の nsec は 400。
pub fn import_rejects_an_out_of_range_key_test() {
  let zero = "nsec1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqwkhnav"
  let response = post_form(context(), "/accounts/import", [#("nsec", zero)])
  assert response.status == 400
  assert string.contains(
    simulate.read_body(response),
    "private key not in valid range",
  )
}

/// 登録済みの鍵は 409 で、理由と、別のマスターキーの行についての案内と、
/// ダッシュボードへのリンクを出す。nsec は出さない。
pub fn import_rejects_a_registered_account_test() {
  let response =
    post_form(context(), "/accounts/import", [#("nsec", signer_nsec)])
  assert response.status == 409
  let body = simulate.read_body(response)
  assert string.contains(body, "account is already registered")
  assert string.contains(body, "different master key")
  assert string.contains(
    body,
    "<a class=\"link\" href=\"/\">Back to dashboard</a>",
  )
  assert !string.contains(body, signer_nsec)
}

/// 反映されたか分からない登録は 202 の通知ページで、nsec を出さない。
pub fn import_that_may_have_been_applied_is_accepted_test() {
  let response =
    post_form(
      failing_context(bunker.MaybeApplied(bunker.change_may_have_been_applied)),
      "/accounts/import",
      [#("nsec", spec_nsec)],
    )
  assert response.status == 202
  let body = simulate.read_body(response)
  assert string.contains(body, bunker.change_may_have_been_applied)
  assert string.contains(body, "Back to dashboard")
  assert !string.contains(body, spec_nsec)
}

/// 変更を受け付けられないときの登録は 503 で、nsec を出さない。
pub fn import_while_accounts_are_not_ready_is_unavailable_test() {
  let response =
    post_form(
      failing_context(bunker.NotReady("accounts are not loaded yet")),
      "/accounts/import",
      [#("nsec", spec_nsec)],
    )
  assert response.status == 503
  let body = simulate.read_body(response)
  assert string.contains(body, "accounts are not loaded yet")
  assert !string.contains(body, spec_nsec)
}

/// 符号位置が 100 を超えるラベルと、制御文字を含むラベルは 400 で、登録しない。
/// 結合文字を続けたラベルは書記素クラスターでは 1 だが、符号位置で数えて拒否する。
pub fn import_rejects_a_label_over_the_code_point_limit_test() {
  let reports = process.new_subject()
  let labels = [
    #(string.repeat("a", 101), "label must be at most 100 characters"),
    #(
      "e" <> string.repeat("\u{0301}", 100),
      "label must be at most 100 characters",
    ),
    #("a\nb", "label must not contain control characters"),
    #("a\u{009B}b", "label must not contain control characters"),
  ]
  list.each(labels, fn(entry) {
    let #(sent, reason) = entry
    let response =
      post_form(reporting_context(reports), "/accounts/import", [
        #("nsec", spec_nsec),
        #("label", sent),
      ])
    assert response.status == 400
    assert string.contains(simulate.read_body(response), reason)
  })
  assert process.receive(reports, 100) == Error(Nil)
}

/// 前後に空白を付けた 100 符号位置のラベルは通り、空白を除いた値で登録する。
pub fn import_accepts_a_label_at_the_code_point_limit_test() {
  let reports = process.new_subject()
  let limit = string.repeat("a", 100)
  let response =
    post_form(reporting_context(reports), "/accounts/import", [
      #("nsec", spec_nsec),
      #("label", "  " <> limit <> " "),
    ])
  assert response.status == 200
  assert process.receive(reports, 1000)
    == Ok(Added(nsec_signer(spec_nsec), limit))
}

/// 欄の無いフォームは 400、フォームの本文が無い POST は 415 で、どちらも登録しない。
pub fn import_without_fields_is_rejected_test() {
  let reports = process.new_subject()
  let empty = post_form(reporting_context(reports), "/accounts/import", [])
  assert empty.status == 400
  assert string.contains(simulate.read_body(empty), "missing bech32 separator")
  assert post(reporting_context(reports), "/accounts/import").status == 415
  assert process.receive(reports, 100) == Error(Nil)
}

/// 完了ページのラベルはエスケープして出す。
pub fn registered_page_escapes_the_label_test() {
  let body =
    simulate.read_body(
      post_form(context(), "/accounts/import", [
        #("nsec", spec_nsec),
        #("label", "<script>x</script>"),
      ]),
    )
  assert string.contains(body, "&lt;script&gt;x&lt;/script&gt;")
  assert !string.contains(body, "<script>x</script>")
}

/// 鍵の生成は登録せず、確認ページの隠しフィールドに有効な nsec を入れて、生成した鍵の
/// 登録へ送るフォームを返す。生成のたびに違う鍵になる。本文の無い POST も受け付ける。
pub fn generate_does_not_register_test() {
  let reports = process.new_subject()
  let response = post(reporting_context(reports), "/accounts/generate")
  assert response.status == 200
  let body = simulate.read_body(response)
  assert string.contains(body, "action=\"/accounts/register-generated\"")
  let generated = hidden_nsec(body)
  let assert Ok(privkey) = nip19.decode(generated, nip19.Nsec)
  let assert Ok(_account) = account.from_privkey(privkey)
  let again =
    simulate.read_body(post(reporting_context(reports), "/accounts/generate"))
  assert hidden_nsec(again) != generated
  assert process.receive(reports, 100) == Error(Nil)
}

/// 確認ページの nsec とラベルで生成した鍵を登録すると、nsec を描画せずに
/// ダッシュボードへ 303 で戻る。
pub fn generated_key_can_be_registered_test() {
  let reports = process.new_subject()
  let generated =
    hidden_nsec(simulate.read_body(post(context(), "/accounts/generate")))
  let response =
    post_form(reporting_context(reports), "/accounts/register-generated", [
      #("nsec", generated),
      #("label", "fresh"),
    ])
  assert response.status == 303
  assert header(response, "location") == "/"
  assert !string.contains(simulate.read_body(response), generated)
  assert process.receive(reports, 1000)
    == Ok(Added(nsec_signer(generated), "fresh"))
}

/// 生成した鍵の登録は、nsec 入力による登録と同じ失敗の経路を通り、どの本文にも nsec を
/// 出さない。
pub fn register_generated_shares_the_failure_paths_test() {
  let path = "/accounts/register-generated"
  let spec = [#("nsec", spec_nsec)]
  let responses = [
    #(post_form(context(), path, [#("nsec", "nsec1invalid")]), 400),
    #(post_form(context(), path, [#("nsec", signer_nsec)]), 409),
    #(
      post_form(
        failing_context(bunker.NotReady("accounts are not loaded yet")),
        path,
        spec,
      ),
      503,
    ),
    #(
      post_form(
        failing_context(bunker.MaybeApplied(bunker.change_may_have_been_applied)),
        path,
        spec,
      ),
      202,
    ),
  ]
  list.each(responses, fn(entry) {
    let #(response, status) = entry
    assert response.status == status
    let body = simulate.read_body(response)
    assert !string.contains(body, spec_nsec)
    assert !string.contains(body, signer_nsec)
  })
}

/// 生成した鍵の登録でラベルだけが規則に反すると、生成した鍵を失わないよう、送られた
/// nsec の確認ページを理由付きで 400 で返す。登録はしない。
pub fn register_generated_with_an_invalid_label_keeps_the_key_test() {
  let reports = process.new_subject()
  let generated =
    hidden_nsec(simulate.read_body(post(context(), "/accounts/generate")))
  let response =
    post_form(reporting_context(reports), "/accounts/register-generated", [
      #("nsec", generated),
      #("label", "a\tb"),
    ])
  assert response.status == 400
  let body = simulate.read_body(response)
  assert hidden_nsec(body) == generated
  assert string.contains(body, "action=\"/accounts/register-generated\"")
  assert string.contains(
    body,
    "<div class=\"alert alert-error\" role=\"alert\"><span>label must not contain control characters</span></div>",
  )
  assert !string.contains(body, "a\tb")
  assert header(response, "cache-control") == "no-store"
  assert process.receive(reports, 100) == Error(Nil)
}

/// 生成した鍵の登録で nsec が不正なら、ラベルの不正を問わず登録画面を 400 で返す。
pub fn register_generated_with_an_invalid_nsec_returns_to_the_registration_page_test() {
  let response =
    post_form(context(), "/accounts/register-generated", [
      #("nsec", "nsec1invalid"),
      #("label", "a\tb"),
    ])
  assert response.status == 400
  let body = simulate.read_body(response)
  assert string.contains(body, "action=\"/accounts/import\"")
  assert !string.contains(body, "action=\"/accounts/register-generated\"")
}

/// nsec 入力による登録でラベルが規則に反すると、登録画面を返し、nsec を出さない。
pub fn import_with_an_invalid_label_does_not_echo_the_nsec_test() {
  let response =
    post_form(context(), "/accounts/import", [
      #("nsec", spec_nsec),
      #("label", "a\tb"),
    ])
  assert response.status == 400
  let body = simulate.read_body(response)
  assert string.contains(body, "action=\"/accounts/import\"")
  assert !string.contains(body, spec_nsec)
}

/// 登録の POST のルートは GET を受け付けない。
pub fn registration_routes_reject_other_methods_test() {
  let paths = [
    "/accounts/import", "/accounts/generate", "/accounts/register-generated",
  ]
  list.each(paths, fn(path) {
    assert get(context(), path).status == 405
  })
}

/// 登録画面の nsec の欄は伏せ字で、自動入力を求めない。
pub fn new_account_page_has_secret_inputs_test() {
  let response = get(context(), "/accounts/new")
  assert response.status == 200
  assert string.contains(
    simulate.read_body(response),
    "<input autocomplete=\"off\" class=\"input w-full font-mono border-base-content/60\" name=\"nsec\" required type=\"password\">",
  )
}

// --- 秘密鍵の再表示 ---

/// 再表示のページはパスワードを求めるだけで、nsec を問い合わせない。
pub fn reveal_page_asks_for_the_password_test() {
  let reports = process.new_subject()
  let response =
    get(reporting_context(reports), action_path(dashboard.RevealPrivateKey))
  assert response.status == 200
  let body = simulate.read_body(response)
  assert string.contains(
    body,
    "<input autocomplete=\"off\" class=\"input w-full font-mono border-base-content/60\" name=\"password\" required type=\"password\">",
  )
  assert !string.contains(body, signer_nsec)
  assert process.receive(reports, 100) == Error(Nil)
}

/// パスワードが違えば 403 で、nsec もパスワードも出さず、nsec を問い合わせない。
/// Basic 認証の入力を促すヘッダーも付けない。
pub fn reveal_with_a_wrong_password_is_forbidden_test() {
  let reports = process.new_subject()
  let response =
    post_form(
      reporting_context(reports),
      action_path(dashboard.RevealPrivateKey),
      [#("password", "wrong-guess")],
    )
  assert response.status == 403
  let body = simulate.read_body(response)
  assert string.contains(body, "incorrect password")
  assert !string.contains(body, signer_nsec)
  assert !string.contains(body, "wrong-guess")
  assert list.key_find(response.headers, "www-authenticate") == Error(Nil)
  assert process.receive(reports, 100) == Error(Nil)
}

/// 正しいパスワードなら、一覧の署名者の nsec を問い合わせて表示する。
pub fn reveal_with_the_password_shows_the_nsec_test() {
  let reports = process.new_subject()
  let response =
    post_form(
      reporting_context(reports),
      action_path(dashboard.RevealPrivateKey),
      [#("password", password)],
    )
  assert response.status == 200
  assert string.contains(simulate.read_body(response), signer_nsec)
  assert process.receive(reports, 1000) == Ok(NsecRequested(signer))
}

/// nsec の問い合わせが失敗したら 503 の通知ページにする。
pub fn reveal_failure_is_unavailable_test() {
  let failing =
    admin.Context(..context(), nsec: fn(_signer) {
      Error("accounts are not loaded yet")
    })
  let response =
    post_form(failing, action_path(dashboard.RevealPrivateKey), [
      #("password", password),
    ])
  assert response.status == 503
  let body = simulate.read_body(response)
  assert string.contains(body, "accounts are not loaded yet")
  assert string.contains(body, "Back to dashboard")
}

/// 一覧に無い署名者は GET も POST も 404 で、パスの値を応答に含めず、何も呼ばない。
pub fn reveal_for_an_unknown_signer_is_not_found_test() {
  let reports = process.new_subject()
  let path = "/accounts/%3Cscript%3Eunknown/private-key"
  let responses = [
    get(reporting_context(reports), path),
    post_form(reporting_context(reports), path, [#("password", password)]),
  ]
  list.each(responses, fn(response) {
    assert response.status == 404
    assert !string.contains(simulate.read_body(response), "%3Cscript%3Eunknown")
  })
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

// --- 削除、secret の作り直し、ラベル ---

/// 削除のページは、鍵を失うことを伝え、エスケープしたラベルと npub を出す。
pub fn delete_page_warns_about_losing_the_key_test() {
  let labelled = with_accounts(Ok([account_row("<b>x</b>")]))
  let body =
    simulate.read_body(get(labelled, action_path(dashboard.DeleteAccount)))
  assert string.contains(body, signer_npub)
  assert string.contains(body, "&lt;b&gt;x&lt;/b&gt;")
  assert string.contains(body, "the account is lost")
  assert string.contains(body, "action=\"/accounts/" <> signer <> "/delete\"")
}

/// 削除の POST は Context を呼び、ダッシュボードへ 303 で戻す。
pub fn delete_calls_the_context_and_redirects_test() {
  let reports = process.new_subject()
  let response =
    post(reporting_context(reports), action_path(dashboard.DeleteAccount))
  assert response.status == 303
  assert header(response, "location") == "/"
  assert process.receive(reports, 1000) == Ok(Removed(signer))
}

/// secret の作り直しのページは、古い URI での新規の接続が拒否され、承認済みの
/// セッションが残ることを伝える。
pub fn rotate_page_explains_the_effect_test() {
  let body =
    simulate.read_body(get(context(), action_path(dashboard.RotateSecret)))
  assert string.contains(
    body,
    "old connection URI are no longer accepted without approval",
  )
  assert string.contains(body, "sessions that are already approved remain")
}

/// secret の作り直しの POST は Context を呼び、ダッシュボードへ 303 で戻す。
pub fn rotate_calls_the_context_and_redirects_test() {
  let reports = process.new_subject()
  let response =
    post(reporting_context(reports), action_path(dashboard.RotateSecret))
  assert response.status == 303
  assert process.receive(reports, 1000) == Ok(Rotated(signer))
}

/// ラベルの POST は Context を呼び、ダッシュボードへ 303 で戻す。
pub fn label_update_calls_the_context_and_redirects_test() {
  let reports = process.new_subject()
  let response =
    post_form(reporting_context(reports), action_path(dashboard.EditLabel), [
      #("label", "new"),
    ])
  assert response.status == 303
  assert process.receive(reports, 1000) == Ok(Relabeled(signer, "new"))
}

/// 規則に反するラベルは 400 で、編集の欄には保存済みのラベルを入れ、Context を
/// 呼ばない。
pub fn label_update_rejects_an_invalid_label_test() {
  let reports = process.new_subject()
  let response =
    post_form(reporting_context(reports), action_path(dashboard.EditLabel), [
      #("label", "a\nb"),
    ])
  assert response.status == 400
  let body = simulate.read_body(response)
  assert string.contains(body, "label must not contain control characters")
  assert string.contains(body, "value=\"" <> label <> "\"")
  assert process.receive(reports, 100) == Error(Nil)
}

/// ラベルの編集の欄には `maxlength` を付けず、新しいアカウントの欄には付ける。
pub fn label_edit_form_has_no_maxlength_test() {
  let edit =
    simulate.read_body(get(context(), action_path(dashboard.EditLabel)))
  assert string.contains(
    edit,
    "autocomplete=\"off\" class=\"input w-full border-base-content/60\" name=\"label\" type=\"text\" value=\""
      <> label
      <> "\"",
  )
  assert !string.contains(edit, "maxlength")
  let new = simulate.read_body(get(context(), "/accounts/new"))
  assert string.contains(new, "maxlength=\"100\" name=\"label\"")
}

/// 削除、secret の作り直し、ラベルの POST の失敗は、反映されていなければ 409、
/// 受け付けられなければ 503、反映されたか分からなければ 202 になり、理由と
/// ダッシュボードへのリンクを出す。
pub fn account_change_failures_map_to_status_codes_test() {
  let failures = [
    #(bunker.NotApplied("account is not registered"), 409),
    #(bunker.NotReady("accounts are not loaded yet"), 503),
    #(bunker.MaybeApplied(bunker.change_may_have_been_applied), 202),
  ]
  let changes = [
    #(dashboard.DeleteAccount, []),
    #(dashboard.RotateSecret, []),
    #(dashboard.EditLabel, [#("label", "new")]),
  ]
  use #(failure, status) <- list.each(failures)
  use #(action, fields) <- list.each(changes)
  let response =
    post_form(failing_context(failure), action_path(action), fields)
  assert #(action, response.status) == #(action, status)
  let body = simulate.read_body(response)
  assert string.contains(body, failure.reason)
  assert string.contains(
    body,
    "<a class=\"link\" href=\"/\">Back to dashboard</a>",
  )
}

/// 一覧に無い署名者（削除済みなど）への削除、secret の作り直し、ラベルの POST は 404 で、
/// Context の変更を呼ばない。反映済みの削除を再送した場合もこの経路になる。
pub fn changes_to_an_unlisted_signer_are_not_found_test() {
  let reports = process.new_subject()
  let emptied =
    admin.Context(..reporting_context(reports), accounts: fn() { Ok([]) })
  let changes = [
    #(dashboard.DeleteAccount, []),
    #(dashboard.RotateSecret, []),
    #(dashboard.EditLabel, [#("label", "new")]),
  ]
  list.each(changes, fn(entry) {
    let #(action, fields) = entry
    let response = post_form(emptied, action_path(action), fields)
    assert #(action, response.status) == #(action, 404)
  })
  assert process.receive(reports, 100) == Error(Nil)
}

/// 知らない操作のセグメントは 404。
pub fn unknown_account_action_is_not_found_test() {
  assert get(context(), "/accounts/" <> signer <> "/nope").status == 404
  assert post(context(), "/accounts/" <> signer <> "/nope").status == 404
}

/// アカウントの一覧を得られなければ、操作の GET と POST は 503 で理由を出す。
pub fn account_pages_need_the_account_list_test() {
  let failing = with_accounts(Error(unavailable))
  let responses =
    list.append(
      list.map(account_actions.all, fn(action) {
        get(failing, action_path(action))
      }),
      [post(failing, action_path(dashboard.DeleteAccount))],
    )
  list.each(responses, fn(response) {
    assert response.status == 503
    let body = simulate.read_body(response)
    assert string.contains(body, unavailable)
    assert string.contains(body, "Back to dashboard")
  })
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
      assert simulate.read_body(response) == "Bad request: Invalid origin"
    }
  }
}

/// 認証済みの応答はどれも保存させず、枠への埋め込みを禁じる。
pub fn authenticated_responses_are_not_stored_test() {
  let context = context()
  let reveal = action_path(dashboard.RevealPrivateKey)
  let with_password = [#("password", password)]
  let spec = [#("nsec", spec_nsec)]
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
    post_form(context, "/accounts/import", [#("nsec", signer_nsec)]),
    post_form(
      failing_context(bunker.MaybeApplied(bunker.change_may_have_been_applied)),
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

// --- ダッシュボードのアカウントの節 ---

/// アカウントの節には、npub、読み取り専用の欄の URI、4 つの操作のリンク、登録の
/// リンクが出る。
pub fn dashboard_lists_account_actions_test() {
  let body = simulate.read_body(get(context(), "/"))
  assert string.contains(body, signer_npub)
  assert string.contains(
    body,
    "<input aria-label=\"Connection URI\" class=\"input join-item w-full min-w-0 font-mono text-xs border-base-content/60\" readonly type=\"text\" value=\""
      <> wisp.escape_html(uri)
      <> "\">",
  )
  assert string.contains(body, "href=\"/accounts/new\"")
  list.each(account_actions.all, fn(action) {
    assert string.contains(body, "href=\"" <> action_path(action) <> "\"")
  })
}

/// URI に `"` が含まれても、`value` の属性値の外に出ない。
pub fn dashboard_escapes_a_uri_attribute_test() {
  let row =
    dashboard.AccountRow(..account_row(label), uri: "bunker://x?\"><b>xss</b>")
  let body = simulate.read_body(get(with_accounts(Ok([row])), "/"))
  assert string.contains(
    body,
    "value=\"bunker://x?&quot;&gt;&lt;b&gt;xss&lt;/b&gt;\"",
  )
  assert !string.contains(body, "<b>xss</b>")
}

/// 一覧を得られないときは登録のリンクを出さない。
pub fn dashboard_hides_add_account_without_accounts_test() {
  let failing = simulate.read_body(get(with_accounts(Error(unavailable)), "/"))
  assert !string.contains(failing, "Add account")
  let empty = simulate.read_body(get(with_accounts(Ok([])), "/"))
  assert string.contains(empty, "Add account")
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
    #(post(context(), "/approve/" <> token), "alert alert-success"),
    #(post(context(), "/deny/" <> token), "alert"),
    #(post(context(), "/approve/other-token"), "alert alert-error"),
    #(
      post(
        failing_context(bunker.MaybeApplied(bunker.change_may_have_been_applied)),
        rotate,
      ),
      "alert alert-warning",
    ),
    #(
      post(
        failing_context(bunker.NotReady("accounts are not loaded yet")),
        rotate,
      ),
      "alert alert-warning",
    ),
    #(
      post_form(context(), "/sessions/revoke", [
        #("signer", signer),
        #("client", unknown_client),
      ]),
      "alert alert-error",
    ),
    #(
      post_form(not_answering_context(), "/sessions/revoke", [
        #("signer", signer),
        #("client", client),
      ]),
      "alert alert-warning",
    ),
  ]
  list.each(notices, fn(entry) {
    let #(response, class) = entry
    assert string.contains(
      simulate.read_body(response),
      "<div class=\"card-body gap-4 p-4 sm:p-6\"><div class=\""
        <> class
        <> "\"><span>",
    )
  })
}

// --- 表示の言語 ---

/// 応答のページの `<html lang>` の値。
fn page_language(response: Response(wisp.Body)) -> String {
  let assert Ok(#(_before, rest)) =
    string.split_once(simulate.read_body(response), "<html lang=\"")
  let assert Ok(#(language, _after)) = string.split_once(rest, "\"")
  language
}

/// `Accept-Language` で日本語を求めるリクエスト。
fn in_japanese(request: wisp.Request) -> wisp.Request {
  request.set_header(request, "accept-language", "ja")
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
    language_switch_request([#("language", "ja"), #("return", "/accounts/new")])
    |> admin.handle_request(context(), _)
  assert response.status == 303
  assert header(response, "location") == "/accounts/new"
  assert header(response, "set-cookie")
    == "nostr_no_su_language=ja; Max-Age=31536000; Path=/; HttpOnly; SameSite=Lax"
  assert header(response, "cache-control") == "no-store"
}

/// 戻り先は、同じサイトのパスとして組み立て直す。別のオリジンを指す値は、このサイトの
/// パスかダッシュボードになる。
pub fn language_switch_returns_only_within_the_site_test() {
  let cases = [
    #("/", "/"),
    #(action_path(dashboard.EditLabel), action_path(dashboard.EditLabel)),
    #("/approve/" <> token, "/approve/" <> token),
    #("//evil.example/x", "/evil.example/x"),
    #("/\\evil.example", "/%5Cevil.example"),
    #(
      "/approve/tok-1?next=//evil.example",
      "/approve/tok-1%3Fnext%3D/evil.example",
    ),
    #(
      "/accounts/new\r\nSet-Cookie: x=1",
      "/accounts/new%0D%0ASet-Cookie%3A%20x%3D1",
    ),
    #("https://evil.example/", "/"),
    #("evil.example", "/"),
    #("", "/"),
  ]
  use #(sent, location) <- list.each(cases)
  let response =
    language_switch_request([#("language", "en"), #("return", sent)])
    |> admin.handle_request(context(), _)
  assert #(sent, header(response, "location")) == #(sent, location)
}

/// 対応していない言語、GET、別のオリジンからの切り替え、資格情報の無い切り替えは受け付けず、
/// cookie を保存しない。
pub fn language_switch_rejects_invalid_requests_test() {
  let rejected = [
    #(
      language_switch_request([#("language", "fr"), #("return", "/")])
        |> admin.handle_request(context(), _),
      400,
    ),
    #(
      language_switch_request([#("return", "/")])
        |> admin.handle_request(context(), _),
      400,
    ),
    #(get(context(), "/language"), 405),
    #(
      language_switch_request([#("language", "ja"), #("return", "/")])
        |> request.set_header("origin", "http://evil.example")
        |> admin.handle_request(context(), _),
      400,
    ),
    #(
      simulate.browser_request(http.Post, "/language")
        |> simulate.form_body([#("language", "ja"), #("return", "/")])
        |> admin.handle_request(context(), _),
      401,
    ),
  ]
  use #(response, status) <- list.each(rejected)
  assert response.status == status
  assert list.key_find(response.headers, "set-cookie") == Error(Nil)
}

/// 切り替えた言語は、GET のページにも、ブラウザーから送った POST の応答のページにも保たれる。
pub fn switched_language_carries_across_pages_test() {
  let switch = language_switch_request([#("language", "ja"), #("return", "/")])
  let switched = admin.handle_request(context(), switch)
  let new_account =
    simulate.browser_request(http.Get, "/accounts/new")
    |> with_credentials("admin", password)
    |> simulate.session(switch, switched)
    |> admin.handle_request(context(), _)
  assert page_language(new_account) == "ja"
  let rejected =
    simulate.browser_request(http.Post, "/accounts/import")
    |> with_credentials("admin", password)
    |> simulate.session(switch, switched)
    |> simulate.form_body([#("nsec", string.drop_end(spec_nsec, 1) <> "4")])
    |> admin.handle_request(context(), _)
  assert rejected.status == 400
  assert string.contains(
    simulate.read_body(rejected),
    "<span>bech32 のチェックサムが一致しません。</span>",
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

/// 秘密鍵を描画するページには言語の切り替えを出さず、ほかのページには出す。
pub fn pages_with_a_private_key_have_no_language_switch_test() {
  let hidden = [
    post(context(), "/accounts/generate"),
    post_form(context(), "/accounts/import", [#("nsec", spec_nsec)]),
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
    assert string.contains(body, "<div class=\"navbar-end\"></div>")
    assert !string.contains(body, "action=\"/language\"")
  })
  let shown = [
    get(context(), "/"),
    get(context(), "/accounts/new"),
    get(context(), "/approve/" <> token),
    post(context(), "/approve/" <> token),
    post_form(
      failing_context(bunker.MaybeApplied(bunker.change_may_have_been_applied)),
      action_path(dashboard.RotateSecret),
      [],
    ),
    ..list.map(account_actions.all, fn(action) {
      get(context(), action_path(action))
    })
  ]
  list.each(shown, fn(response) {
    assert string.contains(simulate.read_body(response), "action=\"/language\"")
  })
}

/// 日本語のページでも、バンカーから届く理由は英語のまま `lang="en"` で出す。フォームの上と
/// アカウントの節では、何ができなかったかを日本語で前に置き、通知ページは見出しが前置きを
/// 兼ねる。
pub fn japanese_pages_keep_reasons_from_the_bunker_in_english_test() {
  let registered =
    simulate.request(http.Post, "/accounts/import")
    |> with_credentials("admin", password)
    |> in_japanese
    |> simulate.form_body([#("nsec", signer_nsec)])
    |> admin.handle_request(context(), _)
  assert registered.status == 409
  assert string.contains(
    simulate.read_body(registered),
    "<span>登録できませんでした。<span lang=\"en\">account is already registered</span></span>",
  )
  let unavailable_body =
    simulate.request(http.Get, "/")
    |> with_credentials("admin", password)
    |> in_japanese
    |> admin.handle_request(with_accounts(Error(unavailable)), _)
    |> simulate.read_body
  assert string.contains(
    unavailable_body,
    "<span>アカウントの一覧を表示できません。<span lang=\"en\">"
      <> unavailable
      <> "</span></span>",
  )
  let unconfirmed =
    simulate.request(http.Post, action_path(dashboard.RotateSecret))
    |> with_credentials("admin", password)
    |> in_japanese
    |> admin.handle_request(
      failing_context(bunker.MaybeApplied(bunker.change_may_have_been_applied)),
      _,
    )
    |> simulate.read_body
  assert string.contains(
    unconfirmed,
    "<h1 class=\"text-2xl font-bold\">変更を確認できませんでした</h1>",
  )
  assert string.contains(
    unconfirmed,
    "<span><span lang=\"en\">"
      <> bunker.change_may_have_been_applied
      <> "</span></span>",
  )
}

/// 通知ページで言語を切り替えた後はダッシュボードを開く。一覧を得られない 503 でも、パスの
/// 署名者を戻り先に含めない。
pub fn notice_pages_return_to_the_dashboard_test() {
  let response =
    get(
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
