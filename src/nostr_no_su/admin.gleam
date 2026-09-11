//// 管理 UI の HTTP サーバー（wisp / mist）。
////
//// ハンドラーは状態を自分で取りに行かず、`Context` に注入された関数から受け取る。
//// これによりルートはアクターを起動せずにテストでき、描画は「スナップショット →
//// HTML」の純粋関数（`admin/dashboard`）に閉じ込められる。
////
//// 認証は HTTP Basic（ユーザー名 `admin`）。平文 HTTP なので、外部へ公開する
//// ときはリバースプロキシーで TLS を終端すること。資格情報はブラウザーが自動で
//// 送るため、状態を変えるルートは CSRF から守る必要がある。

import gleam/bit_array
import gleam/crypto
import gleam/http
import gleam/int
import gleam/list
import gleam/otp/static_supervisor.{type Supervisor}
import gleam/otp/supervision.{type ChildSpecification}
import gleam/string
import mist
import nostr_no_su/admin/dashboard
import nostr_no_su/bunker/engine.{type Session}
import nostr_no_su/log
import wisp.{type Request, type Response}
import wisp/wisp_mist

/// 管理 UI が出すログ行の接頭辞。
pub const log_prefix = "admin"

/// Basic 認証のユーザー名。設定するのはパスワードだけにする。
const username = "admin"

/// 401 応答で提示する認証領域。
const realm = "nostr-no-su"

/// ハンドラーが必要とするものすべて。パスワード以外の状態（アカウント、リレー、
/// プラグイン、セッション、承認待ち）はアクターに問い合わせる関数で受け取り、
/// 表示のたびに現在の値を読む。
pub type Context {
  Context(
    password: String,
    /// アカウントの一覧。バンカーが無効、読み込み中、応答なしのときは表示する
    /// 理由を返す。
    accounts: fn() -> Result(List(dashboard.AccountRow), String),
    relays: fn() -> List(dashboard.RelayRow),
    plugins: fn() -> List(dashboard.PluginRow),
    sessions: fn() -> List(Session),
    revoke: fn(String, String) -> Nil,
    pending: fn() -> List(dashboard.PendingRow),
    approve: fn(String) -> Result(Nil, String),
    deny: fn(String) -> Result(Nil, String),
  )
}

/// スーパービジョンツリー用の子仕様。mist 自身がスーパーバイザーなので、
/// サブツリーとしてそのままぶら下げる。
pub fn supervised(
  bind: String,
  port: Int,
  context: Context,
) -> ChildSpecification(Supervisor) {
  mist.supervised(server(bind, port, context))
}

/// 指定のアドレスとポートで待ち受ける mist の設定。secret_key_base は wisp が
/// 要求するが、cookie の署名も暗号化も使わないため起動ごとの乱数でよい。
fn server(
  bind: String,
  port: Int,
  context: Context,
) -> mist.Builder(mist.Connection, mist.ResponseData) {
  handle_request(context, _)
  |> wisp_mist.handler(wisp.random_string(64))
  |> mist.new
  |> mist.bind(bind)
  |> mist.port(port)
  |> mist.after_start(fn(port, _scheme, address) {
    log.println(log_prefix, "listening on " <> listening_url(address, port))
  })
}

/// 実際に待ち受けているアドレスの表示。IPv6 アドレスは URL 内で角括弧に入れる。
fn listening_url(address: mist.IpAddress, port: Int) -> String {
  let host = case address {
    mist.IpV6(..) -> "[" <> mist.ip_address_to_string(address) <> "]"
    mist.IpV4(..) -> mist.ip_address_to_string(address)
  }
  "http://" <> host <> ":" <> int.to_string(port)
}

/// リクエストを 1 件処理する。`/healthz` だけ認証なしで通し、それ以外は Basic
/// 認証を通ってからルーティングする。
pub fn handle_request(context: Context, request: Request) -> Response {
  use <- wisp.rescue_crashes
  use request <- wisp.handle_head(request)
  // Basic 認証の資格情報はブラウザーが自動送信するため、別オリジンのフォームから
  // の POST を弾く。`Origin` も `Referer` も無いリクエスト（curl 等）は通る。
  use request <- wisp.csrf_known_header_protection(request)
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
    ["approve", token] -> approve_connection(context, request, token)
    ["deny", token] -> deny_connection(context, request, token)
    segments if segments == dashboard.revoke_segments ->
      revoke_session(context, request)
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
    accounts: context.accounts(),
    pending: context.pending(),
    relays: context.relays(),
    sessions: context.sessions(),
    plugins: context.plugins(),
  )
  |> dashboard.render
  |> wisp.html_response(200)
  // secret 入りの `bunker://` URI を含むため、どこにも保存させない。
  |> wisp.set_header("cache-control", "no-store")
}

/// 承認ページ。GET は接続要求の内容を出し、POST は承認する。クライアントは
/// `auth_url` として渡されたこの URL を開く。
fn approve_connection(
  context: Context,
  request: Request,
  token: String,
) -> Response {
  case request.method {
    http.Get -> show_approval(context, token)
    http.Post -> decision_response(context.approve(token), "Approved")
    _ -> wisp.method_not_allowed(allowed: [http.Get, http.Post])
  }
}

/// 接続要求を 1 件拒否する。
fn deny_connection(
  context: Context,
  request: Request,
  token: String,
) -> Response {
  use <- wisp.require_method(request, http.Post)
  decision_response(context.deny(token), "Denied")
}

/// 承認待ち 1 件の確認画面。処理済み、あるいは失効した token は 404。
fn show_approval(context: Context, token: String) -> Response {
  case list.find(context.pending(), fn(entry) { entry.token == token }) {
    Error(Nil) -> wisp.not_found()
    Ok(entry) -> wisp.html_response(dashboard.approval_page(entry), 200)
  }
}

/// 承認・拒否の結果。クライアントは応答イベントを待っているので、ここでは人間に
/// 終わったことだけを伝える。処理できなかった要求（不明・失効・処理済み、あるいは
/// バンカーが動いていない）は、区別せず理由を添えた 404 にする。
fn decision_response(outcome: Result(Nil, String), done: String) -> Response {
  case outcome {
    Ok(Nil) ->
      dashboard.notice_page(done, done <> ". You can close this window.")
      |> wisp.html_response(200)
    Error(reason) ->
      dashboard.notice_page("Not found", reason) |> wisp.html_response(404)
  }
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
/// よう定数時間比較を使う。認証スキームの照合は RFC 7235 に従い大文字小文字を
/// 区別しない。
fn authenticated(password: String, request: Request) -> Bool {
  case list.key_find(request.headers, "authorization") {
    Ok(header) ->
      case string.split_once(header, " ") {
        Ok(#(scheme, offered)) ->
          string.lowercase(scheme) == "basic"
          && matches_password(offered, password)
        Error(Nil) -> False
      }
    Error(Nil) -> False
  }
}

/// base64 で符号化された資格情報が `admin:<password>` と一致するかどうか。
fn matches_password(offered: String, password: String) -> Bool {
  case bit_array.base64_decode(offered) {
    Ok(credentials) ->
      crypto.secure_compare(
        credentials,
        bit_array.from_string(username <> ":" <> password),
      )
    Error(Nil) -> False
  }
}

/// 401。ブラウザーに資格情報の入力を促すため `WWW-Authenticate` を付ける。
fn unauthorized() -> Response {
  wisp.response(401)
  |> wisp.set_header(
    "www-authenticate",
    "Basic realm=\"" <> realm <> "\", charset=\"UTF-8\"",
  )
  |> wisp.set_header("content-type", "text/plain")
  |> wisp.string_body("Unauthorized")
}
