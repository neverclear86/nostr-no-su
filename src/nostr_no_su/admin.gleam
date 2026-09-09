//// 管理 UI の HTTP サーバー（wisp / mist）。
////
//// ハンドラーは状態を自分で取りに行かず、`Context` に注入された関数から受け取る。
//// おかげでルートはアクターを起動せずにテストでき、描画は「スナップショット →
//// HTML」の純粋関数（`admin/dashboard`）に閉じ込められる。
////
//// 認証は HTTP Basic（ユーザー名 `admin`）。平文 HTTP なので、外部へ公開する
//// ときはリバースプロキシで TLS を終端すること。

import gleam/bit_array
import gleam/crypto
import gleam/http
import gleam/int
import gleam/io
import gleam/list
import gleam/otp/static_supervisor.{type Supervisor}
import gleam/otp/supervision.{type ChildSpecification}
import mist
import nostr_no_su/admin/dashboard
import nostr_no_su/bunker/engine.{type Session}
import wisp.{type Request, type Response}
import wisp/wisp_mist

/// Basic 認証のユーザー名。設定するのはパスワードだけにする。
const username = "admin"

/// 401 応答で提示する認証領域。
const realm = "nostr-no-su"

/// すべてのインターフェースで待ち受ける。mist の既定は `localhost` で、それだと
/// コンテナーの外へポートを公開しても届かない。
const interface = "0.0.0.0"

/// ハンドラーが必要とするものすべて。動かないもの（アカウント、プラグイン名）は
/// 値で、アクターに問い合わせるものは関数で受け取る。
pub type Context {
  Context(
    password: String,
    accounts: List(dashboard.Account),
    plugins: List(String),
    storage_enabled: Bool,
    relays: fn() -> List(dashboard.Relay),
    sessions: fn() -> List(Session),
    revoke: fn(String, String) -> Nil,
  )
}

/// スーパービジョンツリー用の子仕様。mist 自身がスーパーバイザーなので、
/// サブツリーとしてそのままぶら下げる。
pub fn supervised(
  port: Int,
  context: Context,
) -> ChildSpecification(Supervisor) {
  mist.supervised(server(port, context))
}

/// 指定ポートで待ち受ける mist の設定。secret_key_base は wisp が要求するが、
/// cookie の署名も暗号化も使わないため起動ごとの乱数でよい。
fn server(
  port: Int,
  context: Context,
) -> mist.Builder(mist.Connection, mist.ResponseData) {
  handle_request(context, _)
  |> wisp_mist.handler(wisp.random_string(64))
  |> mist.new
  |> mist.bind(interface)
  |> mist.port(port)
  |> mist.after_start(fn(port, _scheme, _address) {
    io.println(
      "[admin] listening on http://" <> interface <> ":" <> int.to_string(port),
    )
  })
}

/// リクエストを 1 件処理する。`/healthz` だけ認証なしで通し、それ以外は Basic
/// 認証を通ってからルーティングする。
pub fn handle_request(context: Context, request: Request) -> Response {
  use <- wisp.rescue_crashes
  use request <- wisp.handle_head(request)
  case wisp.path_segments(request) {
    ["healthz"] -> healthz(request)
    segments -> {
      use <- require_password(context, request)
      route(context, request, segments)
    }
  }
}

/// 認証済みのルート。
fn route(
  context: Context,
  request: Request,
  segments: List(String),
) -> Response {
  case segments {
    [] -> show_dashboard(context, request)
    ["sessions", "revoke"] -> revoke_session(context, request)
    _ -> wisp.not_found()
  }
}

/// コンテナーの healthcheck 用。認証なしで到達できるため、状態は一切返さない。
fn healthz(request: Request) -> Response {
  use <- wisp.require_method(request, http.Get)
  wisp.ok() |> wisp.string_body("ok")
}

/// ダッシュボード。表示に必要な状態をここで集め、描画は純粋関数へ渡す。
fn show_dashboard(context: Context, request: Request) -> Response {
  use <- wisp.require_method(request, http.Get)
  dashboard.Snapshot(
    accounts: context.accounts,
    relays: context.relays(),
    sessions: context.sessions(),
    plugins: context.plugins,
    storage_enabled: context.storage_enabled,
  )
  |> dashboard.render
  |> wisp.html_response(200)
}

/// セッションを 1 件取り消してダッシュボードへ戻す。再読み込みで取り消しが
/// 再送されないよう 303 でリダイレクトする。
fn revoke_session(context: Context, request: Request) -> Response {
  use <- wisp.require_method(request, http.Post)
  use form <- wisp.require_form(request)
  case
    list.key_find(form.values, "signer"),
    list.key_find(form.values, "client")
  {
    Ok(signer), Ok(client) -> {
      context.revoke(signer, client)
      wisp.redirect(to: "/")
    }
    _, _ -> wisp.bad_request("signer and client are required")
  }
}

/// Basic 認証を要求する。資格情報が無い、あるいは一致しないときは 401 を返す。
fn require_password(
  context: Context,
  request: Request,
  next: fn() -> Response,
) -> Response {
  case authenticated(context.password, request) {
    True -> next()
    False -> unauthorized()
  }
}

/// リクエストが正しい Basic 認証の資格情報を持つかどうか。デコードした
/// `user:password` を期待値と丸ごと比べ、一致した文字数が応答時間に現れない
/// よう定数時間比較を使う。
fn authenticated(password: String, request: Request) -> Bool {
  case list.key_find(request.headers, "authorization") {
    Ok("Basic " <> offered) ->
      case bit_array.base64_decode(offered) {
        Ok(credentials) ->
          crypto.secure_compare(
            credentials,
            bit_array.from_string(username <> ":" <> password),
          )
        Error(Nil) -> False
      }
    _ -> False
  }
}

/// 401。ブラウザに資格情報の入力を促すため `WWW-Authenticate` を付ける。
fn unauthorized() -> Response {
  wisp.response(401)
  |> wisp.set_header(
    "www-authenticate",
    "Basic realm=\"" <> realm <> "\", charset=\"UTF-8\"",
  )
  |> wisp.string_body("Unauthorized")
}
