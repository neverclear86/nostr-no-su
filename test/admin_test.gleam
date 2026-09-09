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

/// フェイクの `revoke` がテストへ報告する内容。
type Revoked {
  Revoked(signer: String, client: String)
}

/// 状態をすべて即値で持つ Context。アクターを起動せずにルートを検証できる。
fn test_context(revoked: Subject(Revoked)) -> admin.Context {
  admin.Context(
    password: password,
    accounts: [
      dashboard.Account(
        signer: signer,
        uri: "bunker://" <> signer <> "?secret=x",
      ),
    ],
    plugins: ["console_logger"],
    storage_enabled: True,
    relays: fn() {
      [
        dashboard.Relay(
          role: dashboard.Monitor,
          url: "wss://relay.example",
          status: relay_connection.Connected,
        ),
        dashboard.Relay(
          role: dashboard.Bunker,
          url: "wss://bunker.example",
          status: relay_connection.Disconnected,
        ),
      ]
    },
    sessions: fn() { [engine.Session(signer: signer, client: client)] },
    revoke: fn(signer, client) {
      process.send(revoked, Revoked(signer: signer, client: client))
    },
  )
}

/// 報告を捨てる Context。取り消しを観測しないテスト向け。
fn context() -> admin.Context {
  test_context(process.new_subject())
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

/// 資格情報のないリクエストは 401 になり、ブラウザに入力を促すヘッダーが付く。
pub fn dashboard_requires_credentials_test() {
  let response =
    simulate.request(http.Get, "/")
    |> admin.handle_request(context(), _)
  assert response.status == 401
  assert string.starts_with(header(response, "www-authenticate"), "Basic ")
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
  assert string.contains(body, "connected")
  assert string.contains(body, "disconnected")
  assert string.contains(body, "console_logger")
  assert string.contains(body, "enabled")
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
    |> admin.handle_request(test_context(revoked), _)
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
    |> admin.handle_request(test_context(revoked), _)
  assert response.status == 400
  assert process.receive(revoked, 100) == Error(Nil)
}

/// 取り消しは POST でしか受け付けない。
pub fn revoke_rejects_other_methods_test() {
  let response = get(context(), "/sessions/revoke")
  assert response.status == 405
}

/// 知らないパスは 404。認証は先に通っている。
pub fn unknown_paths_are_not_found_test() {
  assert get(context(), "/nope").status == 404
}
