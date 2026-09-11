//// 管理 UI の HTTP サーバー（wisp / mist）。
////
//// ハンドラーは状態を自分で取りに行かず、`Context` に注入された関数から受け取る。
//// これによりルートはアクターを起動せずにテストでき、描画は「スナップショット →
//// HTML」の純粋関数（`admin/dashboard`）に閉じ込められる。
////
//// 認証は HTTP Basic（ユーザー名 `admin`）。平文 HTTP なので、外部へ公開する
//// ときはリバースプロキシーで TLS を終端すること。資格情報はブラウザーが自動で
//// 送るため、状態を変えるルートは CSRF から守る必要がある。
////
//// アカウントの登録、削除、secret の作り直し、ラベルの編集、秘密鍵の再表示もここで
//// 扱う。秘密鍵（nsec）はクエリー文字列にもリダイレクト先にもログにも載せず、POST の
//// 本文と、その応答の本文だけで運ぶ。サーバーは生成した鍵を保持しない。認証済みの
//// 応答はどれも secret か秘密鍵を含みうるので、`protect` で保存と枠への埋め込みを
//// 禁じる。

import gleam/bit_array
import gleam/crypto
import gleam/http
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/static_supervisor.{type Supervisor}
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import gleam/string
import mist
import nostr_no_su/admin/dashboard
import nostr_no_su/bunker.{type ChangeFailure}
import nostr_no_su/bunker/account.{type Account}
import nostr_no_su/bunker/engine.{type Session}
import nostr_no_su/log
import nostr_no_su/nostr/nip19
import wisp.{type Request, type Response}
import wisp/wisp_mist

/// 管理 UI が出すログ行の接頭辞。
pub const log_prefix = "admin"

/// Basic 認証のユーザー名。設定するのはパスワードだけにする。
const username = "admin"

/// 401 応答で提示する認証領域。
const realm = "nostr-no-su"

/// 秘密鍵の再表示で、再入力したパスワードが違うときの理由。
const incorrect_password = "incorrect password"

/// ラベルが制御文字を含むときの理由。
const label_has_control_characters = "label must not contain control characters"

/// 変更が反映されたか分からないときのページの見出し。
const change_unconfirmed_title = "Change not confirmed"

/// アカウントを扱えないときのページの見出し。
const accounts_unavailable_title = "Accounts are not available"

/// ハンドラーが必要とするものすべて。パスワード以外の状態（アカウント、リレー、
/// プラグイン、セッション、承認待ち）はアクターに問い合わせる関数で受け取り、
/// 表示のたびに現在の値を読む。
pub type Context {
  Context(
    password: String,
    /// アカウントの一覧。バンカーが無効、読み込み中、応答なしのときは表示する
    /// 理由を返す。
    accounts: fn() -> Result(List(dashboard.AccountRow), String),
    /// アカウントを登録する。secret はバンカーが生成する。
    add_account: fn(Account, String) -> Result(Nil, ChangeFailure),
    /// アカウントを削除する。
    remove_account: fn(String) -> Result(Nil, ChangeFailure),
    /// 接続 secret を作り直す。
    rotate_secret: fn(String) -> Result(Nil, ChangeFailure),
    /// ラベルを差し替える。
    update_label: fn(String, String) -> Result(Nil, ChangeFailure),
    /// 再表示のために、署名者の秘密鍵を nsec の文字列で問い合わせる。`Ok` の値は
    /// 秘密鍵そのもの。
    nsec: fn(String) -> Result(String, String),
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
      route(context, request, segments) |> protect
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
    segments if segments == dashboard.new_account_segments ->
      show_new_account(request)
    segments if segments == dashboard.generate_account_segments ->
      generate_account(request)
    segments if segments == dashboard.import_account_segments ->
      import_account(context, request)
    segments if segments == dashboard.register_generated_segments ->
      register_generated_account(context, request)
    segments ->
      case dashboard.parse_account_action_path(segments) {
        Ok(#(signer, action)) ->
          account_action(context, request, signer, action)
        Error(Nil) -> wisp.not_found()
      }
  }
}

/// 認証済みの応答すべてに付けるヘッダー。どのページも secret か秘密鍵を含みうるので
/// 保存させず、状態を変えるボタンを他のサイトの枠に埋め込ませない。枠の中の POST は
/// 管理 UI と同じオリジンから送られるので、CSRF の検査では防げない。
fn protect(response: Response) -> Response {
  response
  |> wisp.set_header("cache-control", "no-store")
  |> wisp.set_header("x-frame-options", "DENY")
  |> wisp.set_header("content-security-policy", "frame-ancestors 'none'")
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

/// アカウントの登録画面。
fn show_new_account(request: Request) -> Response {
  use <- wisp.require_method(request, http.Get)
  dashboard.new_account_page(None) |> wisp.html_response(200)
}

/// 鍵を生成し、確認ページで nsec を 1 回だけ表示する。ここでは登録しないので、
/// 再読み込みで再送されても別の鍵の確認ページが出るだけで、何も登録されない。
/// 本文を読まないので、フォームの本文が無い POST も受け付ける。
fn generate_account(request: Request) -> Response {
  use <- wisp.require_method(request, http.Post)
  account.generate(crypto.strong_random_bytes)
  |> account.nsec
  |> dashboard.generated_key_page(None)
  |> wisp.html_response(200)
}

/// nsec 入力によるアカウントの登録。完了ページで nsec を 1 回だけ表示する。
fn import_account(context: Context, request: Request) -> Response {
  let reject_label = fn(_account, reason) {
    dashboard.new_account_page(Some(reason))
  }
  use account, label <- register(context, request, reject_label)
  dashboard.registered_page(account.npub(account), label, account.nsec(account))
  |> wisp.html_response(200)
}

/// 生成の確認ページから送られた鍵の登録。nsec は確認ページで表示済みなので描画せず、
/// ダッシュボードへ 303 で戻す。ラベルだけが規則に反するときは、生成した鍵を失わない
/// よう、送られた nsec の確認ページを理由付きで返す（この POST の応答の本文だけに出る）。
fn register_generated_account(context: Context, request: Request) -> Response {
  let reject_label = fn(generated, reason) {
    dashboard.generated_key_page(account.nsec(generated), Some(reason))
  }
  use _account, _label <- register(context, request, reject_label)
  wisp.redirect(to: "/")
}

/// 登録の 2 つのルートが共有する検査と失敗の経路。nsec が不正なら 400 で登録画面を
/// 返し、ラベルだけが不正なら 400 で `reject_label` が描画するページを返す。バンカーの
/// 失敗は `change_failure_response` に渡す。登録できたときだけ `on_success` を呼ぶので、
/// 反映されたか分からないときに nsec を描画する経路は無い。
fn register(
  context: Context,
  request: Request,
  reject_label: fn(Account, String) -> String,
  on_success: fn(Account, String) -> Response,
) -> Response {
  use <- wisp.require_method(request, http.Post)
  use form <- wisp.require_form(request)
  case parse_private_key(form) {
    Error(reason) ->
      dashboard.new_account_page(Some(reason)) |> wisp.html_response(400)
    Ok(account) ->
      case parse_label(form_value(form, dashboard.label_field)) {
        Error(reason) ->
          reject_label(account, reason) |> wisp.html_response(400)
        Ok(label) ->
          case context.add_account(account, label) {
            Ok(Nil) -> on_success(account, label)
            Error(failure) ->
              change_failure_response(failure, fn(reason) {
                dashboard.new_account_page(Some(reason))
              })
          }
      }
  }
}

/// フォームの nsec を検査し、登録するアカウントにする。理由は入力を含まない固定の文言。
fn parse_private_key(form: wisp.FormData) -> Result(Account, String) {
  form_value(form, dashboard.nsec_field)
  |> nip19.decode(nip19.Nsec)
  |> result.map_error(nip19.describe)
  |> result.try(account.from_privkey)
}

/// フォームの値。欄が無ければ空文字列として扱い、以降の検査で拒否させる。
fn form_value(form: wisp.FormData, name: String) -> String {
  list.key_find(form.values, name) |> result.unwrap("")
}

/// ラベルを検査する。前後の空白を除き、符号位置が多すぎるものと制御文字（Unicode の
/// Cc）を含むものを拒否する。長さを書記素クラスターで数えないのは、結合文字を続けた
/// 文字列が長さ 1 のまま任意のバイト数になり、上限にならないからである。
fn parse_label(raw: String) -> Result(String, String) {
  let label = string.trim(raw)
  let code_points = string.to_utf_codepoints(label)
  case
    list.length(code_points) > dashboard.max_label_code_points,
    list.any(code_points, is_control_character)
  {
    True, _ ->
      Error(
        "label must be at most "
        <> int.to_string(dashboard.max_label_code_points)
        <> " characters",
      )
    False, True -> Error(label_has_control_characters)
    False, False -> Ok(label)
  }
}

/// Unicode の Cc（C0、DEL、C1）の符号位置かどうか。`string.trim` は途中の C1 を
/// 残すので、明示的に拒否するために使う。
fn is_control_character(code_point: UtfCodepoint) -> Bool {
  let code = string.utf_codepoint_to_int(code_point)
  code <= 0x1f || { code >= 0x7f && code <= 0x9f }
}

/// アカウント 1 件への操作。一覧から行を引いてから、GET は操作のページを、POST は
/// 操作を実行する。
fn account_action(
  context: Context,
  request: Request,
  signer: String,
  action: dashboard.AccountAction,
) -> Response {
  use row <- with_account(context, signer)
  case request.method, action {
    http.Get, _ ->
      dashboard.account_action_page(row, action, None)
      |> wisp.html_response(200)
    http.Post, dashboard.EditLabel -> update_label(context, request, row)
    http.Post, dashboard.RotateSecret ->
      apply_account_change(row, action, context.rotate_secret(row.signer))
    http.Post, dashboard.DeleteAccount ->
      apply_account_change(row, action, context.remove_account(row.signer))
    http.Post, dashboard.RevealPrivateKey ->
      reveal_private_key(context, request, row)
    _, _ -> wisp.method_not_allowed(allowed: [http.Get, http.Post])
  }
}

/// 一覧から署名者の行を引く。一覧を得られなければ 503、無ければ 404。どちらも
/// `signer` を応答に含めない。以降のログとバンカーへの呼び出しには、呼び出し側が
/// 渡した文字列ではなく、一覧の行の値を使う。
fn with_account(
  context: Context,
  signer: String,
  next: fn(dashboard.AccountRow) -> Response,
) -> Response {
  case context.accounts() {
    Error(reason) -> accounts_unavailable(reason)
    Ok(rows) ->
      case list.find(rows, fn(row) { row.signer == signer }) {
        Ok(row) -> next(row)
        Error(Nil) -> wisp.not_found()
      }
  }
}

/// ラベルの差し替え。ラベルが規則に反すれば 400 で編集のページを返す。
fn update_label(
  context: Context,
  request: Request,
  row: dashboard.AccountRow,
) -> Response {
  use form <- wisp.require_form(request)
  case parse_label(form_value(form, dashboard.label_field)) {
    Error(reason) ->
      dashboard.account_action_page(row, dashboard.EditLabel, Some(reason))
      |> wisp.html_response(400)
    Ok(label) ->
      apply_account_change(
        row,
        dashboard.EditLabel,
        context.update_label(row.signer, label),
      )
  }
}

/// 変更の結果。成功ならダッシュボードへ 303 で戻し（再読み込みで変更を再送させない）、
/// 失敗なら `change_failure_response` に渡す。
fn apply_account_change(
  row: dashboard.AccountRow,
  action: dashboard.AccountAction,
  outcome: Result(Nil, ChangeFailure),
) -> Response {
  case outcome {
    Ok(Nil) -> wisp.redirect(to: "/")
    Error(failure) ->
      change_failure_response(failure, fn(reason) {
        dashboard.account_action_page(row, action, Some(reason))
      })
  }
}

/// 変更の失敗の応答。反映されなかったなら `render` で操作の画面を 409 で返し、
/// 受け付けられなかったなら 503、反映されたか分からないなら 202 の通知ページにする。
/// 202 にするのは、反映されたかもしれない変更を「拒否された」と見せると、利用者が
/// 同じ変更をやり直し、secret の作り直しならもう一度作り直してしまうからである。
fn change_failure_response(
  failure: ChangeFailure,
  render: fn(String) -> String,
) -> Response {
  case failure {
    bunker.NotApplied(reason) -> render(reason) |> wisp.html_response(409)
    bunker.NotReady(reason) -> accounts_unavailable(reason)
    bunker.MaybeApplied(reason) ->
      dashboard.notice_page(change_unconfirmed_title, reason)
      |> wisp.html_response(202)
  }
}

/// アカウントを扱えないときの 503 の通知ページ。一覧を得られない、変更を受け付け
/// られない、nsec の問い合わせが失敗した場合に共通で使う。
fn accounts_unavailable(reason: String) -> Response {
  dashboard.notice_page(accounts_unavailable_title, reason)
  |> wisp.html_response(503)
}

/// 管理パスワードの再入力を照合し、一致したときだけ nsec を問い合わせて表示する。
/// ログに出すのは一覧の行の npub だけで、パスワードも nsec も出さない。
fn reveal_private_key(
  context: Context,
  request: Request,
  row: dashboard.AccountRow,
) -> Response {
  use form <- wisp.require_form(request)
  case
    is_admin_password(
      form_value(form, dashboard.password_field),
      context.password,
    )
  {
    False -> {
      log.println(
        log_prefix,
        "rejected a private key reveal for "
          <> row.npub
          <> ": "
          <> incorrect_password,
      )
      dashboard.account_action_page(
        row,
        dashboard.RevealPrivateKey,
        Some(incorrect_password),
      )
      |> wisp.html_response(403)
    }
    True ->
      case context.nsec(row.signer) {
        Ok(nsec) -> {
          log.println(log_prefix, "revealed the private key of " <> row.npub)
          dashboard.private_key_page(row, nsec) |> wisp.html_response(200)
        }
        Error(reason) -> accounts_unavailable(reason)
      }
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

/// リクエストが正しい Basic 認証の資格情報を持つかどうか。認証スキームの照合は
/// RFC 7235 に従い大文字小文字を区別しない。
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

/// base64 で符号化された資格情報が `admin:<password>` と一致するかどうか。RFC 7617
/// に従い最初の `:` で分ける（ユーザー名は `:` を含めない）ので、パスワードは `:` を
/// 含んでよい。ユーザー名は公開された固定値なので定数時間では比べない。
fn matches_password(offered: String, password: String) -> Bool {
  case bit_array.base64_decode(offered) |> result.try(bit_array.to_string) {
    Ok(credentials) ->
      case string.split_once(credentials, ":") {
        Ok(#(user, offered_password)) ->
          user == username && is_admin_password(offered_password, password)
        Error(Nil) -> False
      }
    Error(Nil) -> False
  }
}

/// 入力されたパスワードが管理パスワードと一致するか。一致した文字数が応答時間に
/// 現れないよう定数時間で比べる。Basic 認証と秘密鍵の再表示の両方が使う。
fn is_admin_password(offered: String, password: String) -> Bool {
  crypto.secure_compare(
    bit_array.from_string(offered),
    bit_array.from_string(password),
  )
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
