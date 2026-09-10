import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/list
import gleam/string
import nostr_no_su/admin
import nostr_no_su/admin/dashboard
import nostr_no_su/bunker/engine
import nostr_no_su/relay_connection
import wisp
import wisp/simulate

const password = "s3cr3t-password"

const signer = "aaaa1111"

const client = "bbbb2222"

/// 承認待ちのトークン。フェイクの承認・拒否はこれだけを知っている。
const token = "tok-1"

/// アカウントの接続 URI（secret 入りと、承認を経るもの）。
const uri = "bunker://aaaa1111?relay=x&secret=s"

const auth_uri = "bunker://aaaa1111?relay=x"

/// フェイクのハンドラーがテストへ報告する内容。
type Report {
  Revoked(signer: String, client: String)
  Approved(token: String)
  Denied(token: String)
}

/// 状態をすべて即値で持つ Context。アクターを起動せずにルートを検証できる。
/// 監視リレーの URL だけはエスケープの検証のために差し替えられる。
fn test_context(
  reports: Subject(Report),
  monitor_relay_url: String,
) -> admin.Context {
  admin.Context(
    password: password,
    accounts: [
      dashboard.AccountRow(signer: signer, uri: uri, auth_uri: auth_uri),
    ],
    plugins: ["console_logger"],
    event_logger_enabled: True,
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
    sessions: fn() { [engine.Session(signer: signer, client: client)] },
    revoke: fn(signer, client) {
      process.send(reports, Revoked(signer: signer, client: client))
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

/// 認証済みの POST リクエストを 1 件処理する。本文は空で、承認・拒否はパスの
/// トークンだけで決まる。
fn post(context: admin.Context, path: String) -> Response(wisp.Body) {
  simulate.request(http.Post, path)
  |> with_credentials("admin", password)
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
  |> with_credentials("admin", password)
  |> admin.handle_request(context, _)
}

/// 応答ヘッダーの値。存在しなければテストを失敗させる。
fn header(response: Response(wisp.Body), name: String) -> String {
  let assert Ok(value) = list.key_find(response.headers, name)
  value
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
  // セル単位で見る。"connected" だけでは "disconnected" にも一致してしまう。
  assert string.contains(body, "<td>monitor</td>")
  assert string.contains(body, "<td>connected</td>")
  assert string.contains(body, "<td>bunker</td>")
  assert string.contains(body, "<td>disconnected</td>")
  assert string.contains(body, "<td>console_logger</td>")
  assert string.contains(body, "Event logger: enabled")
}

/// 状態に含まれる HTML は、そのまま出さずにエスケープする。リレー URL も
/// クライアント pubkey も外から来た文字列になりうる。
pub fn dashboard_escapes_html_test() {
  let context = test_context(process.new_subject(), "ws://evil/\"><b>xss</b>")
  let response =
    simulate.request(http.Get, "/")
    |> with_credentials("admin", password)
    |> admin.handle_request(context, _)
  let body = simulate.read_body(response)
  assert string.contains(body, "&quot;&gt;&lt;b&gt;xss&lt;/b&gt;")
  assert !string.contains(body, "<b>xss</b>")
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
    simulate.request(http.Post, "/sessions/revoke")
    |> with_credentials("admin", password)
    |> simulate.form_body([#("signer", signer), #("client", client)])
    |> admin.handle_request(reporting_context(revoked), _)
  assert response.status == 303
  assert header(response, "location") == "/"
  assert process.receive(revoked, 1000)
    == Ok(Revoked(signer: signer, client: client))
}

/// フィールドが欠けた取り消しは 400 になり、取り消しは行われない。
pub fn revoke_without_fields_is_a_bad_request_test() {
  let revoked = process.new_subject()
  let response =
    simulate.request(http.Post, "/sessions/revoke")
    |> with_credentials("admin", password)
    |> simulate.form_body([#("signer", signer)])
    |> admin.handle_request(reporting_context(revoked), _)
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
  assert string.contains(body, "<code>" <> auth_uri <> "</code>")
  assert string.contains(body, "action=\"/approve/" <> token <> "\"")
  assert string.contains(body, "action=\"/deny/" <> token <> "\"")
  assert string.contains(body, "<td>12s</td>")
}

/// 承認ページには、誰が誰に接続しようとしているかが出る。
pub fn approval_page_shows_the_request_test() {
  let response = get(context(), "/approve/" <> token)
  assert response.status == 200
  let body = simulate.read_body(response)
  assert string.contains(body, signer)
  assert string.contains(body, client)
  assert string.contains(body, "<td>12s</td>")
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

/// 知らないパスは 404。認証は先に通っている。
pub fn unknown_paths_are_not_found_test() {
  assert get(context(), "/nope").status == 404
}
