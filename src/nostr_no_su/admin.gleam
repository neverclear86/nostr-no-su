//// 管理 UI の HTTP サーバー（wisp / mist）。
////
//// ハンドラーは状態を自分で取りに行かず、`Context` に注入された関数から受け取る。
//// これによりルートはアクターを起動せずにテストでき、描画は「スナップショット →
//// HTML」の純粋関数（`admin/dashboard`、`admin/account_pages`、`admin/relay_pages`、
//// `admin/connect_pages`）に閉じ込められる。
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
////
//// ページの言語は、認証を通った後に、言語の切り替えで保存した cookie、
//// `Accept-Language`、既定の言語（英語）の順に決める（`request_language`）。次は
//// text/plain のまま応答する（表示の言語を決める前か、HTML を返す相手がいないため）。
//// ログの文言も英語のままにする。
////
//// - 401（ブラウザーは本文ではなく認証のダイアログを出す）
//// - `/healthz` の 200 と 405（コンテナーの healthcheck が読む）
//// - 静的ファイル（CSS、JS）への GET 以外の 405
//// - `wisp.require_form` の 400 / 413 / 415（管理 UI のフォームの操作では届かない）
//// - `wisp.rescue_crashes` の 500（不具合でしか起きず、詳細はログにある）
////
//// CSRF の検査で弾いた 400 は認証の前で返るが、言語とテーマは cookie と
//// `Accept-Language` から決められるので、通知ページの HTML にする
//// （`require_same_origin`）。
////
//// 認証に失敗した要求（401）は、理由だけを `[admin]` の 1 行でログに出し、資格情報、
//// パス、送信元は出さない。遅延やロックアウトは入れない（単一利用者がループバックか
//// VPN の内側で使う前提）。
////
//// テーマは言語と同じく認証の後に、切り替えで保存した cookie から決め（`request_theme`）、
//// 無ければブラウザーの設定に従う。CSRF の 400 のページだけ、認証の前に cookie から
//// 決める。

import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/http
import gleam/http/cookie
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/static_supervisor.{type Supervisor}
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import gleam/string
import gleam/uri
import mist
import nostr_no_su/admin/account_pages
import nostr_no_su/admin/connect_pages
import nostr_no_su/admin/dashboard
import nostr_no_su/admin/i18n.{type Language}
import nostr_no_su/admin/relay_pages
import nostr_no_su/admin/view
import nostr_no_su/bunker.{type ChangeFailure, type SessionFailure}
import nostr_no_su/bunker/account.{type Account}
import nostr_no_su/bunker/engine
import nostr_no_su/bunker/nostrconnect
import nostr_no_su/bunker/vault
import nostr_no_su/log
import nostr_no_su/nostr/nip19
import nostr_no_su/relay_client
import nostr_no_su/relay_list
import nostr_no_su/relay_store
import nostr_no_su/task
import nostr_no_su/time
import wisp.{type Request, type Response}
import wisp/wisp_mist

/// 管理 UI が出すログ行の接頭辞。
pub const log_prefix = "admin"

/// 通知ページから切り替えた後に開くパス。404 / 405 / フォームの値の 400 と、承認・拒否や
/// 変更の結果の通知ページはすべてここへ戻す（Origin の不一致の 400 は `view.NoSwitch` で
/// 切り替えを出さない）。
const return_to_dashboard = view.SwitchReturningTo("/")

/// Basic 認証のユーザー名。設定するのはパスワードだけにする。
const username = "admin"

/// 401 応答で提示する認証領域。
const realm = "nostr-no-su"

/// 認証済みの応答に付ける CSP。スクリプトは管理 UI のオリジンのファイル（`/static/admin.js`）だけを
/// 実行させ、インラインのスクリプトとイベント属性を実行させない。`img-src data:` は、daisyUI の CSS が
/// ボタンなどの背景に指定する data: の SVG（`--fx-noise`）を読ませるためである（テーマの `--noise`
/// が 0 なので描画には出ないが、禁じると読み込みのたびに CSP の違反が報告される）。
const content_security_policy = "default-src 'none'; script-src 'self'; style-src 'self'; img-src data:; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"

/// 秘密鍵の再表示で、再入力したパスワードが違うときにログに出す理由。画面の文言は
/// `i18n.IncorrectPassword` で、ログは英語のままにする。
const incorrect_password = "incorrect password"

/// 言語の切り替えで選んだ言語を保存する cookie の名前。cookie はポートで分かれず、同じ
/// ホストで動く別のアプリにも送られるので、製品の名前を付ける。
const language_cookie = "nostr_no_su_language"

/// テーマの切り替えで選んだテーマを保存する cookie の名前。
const theme_cookie = "nostr_no_su_theme"

/// 言語とテーマの cookie の属性。
///
/// - どのページでも読むので `Path=/` にし、JS から読まないので `HttpOnly` を付ける
/// - `SameSite=Lax` にする。クライアントが別のサイトから開く承認ページ（`auth_url`）にも
///   送られるようにするためで、`Strict` だと送られない
/// - `Secure` を付けない。ループバック以外のホストを平文 HTTP で開くと（`ADMIN_BIND` で
///   LAN に公開したときなど）、ブラウザーが `Secure` の cookie を保存しないからで、値は
///   秘密ではない。`wisp.set_cookie` はホストが `localhost` などでなければ `Secure` を
///   付けるので使わない
/// - 365 日保つ。値は言語コードのままで、署名しない（`secret_key_base` は起動ごとの乱数で、
///   署名すると再起動で読めなくなる。改ざんされても表示の言語かテーマが変わるだけである）
const preference_cookie_attributes = cookie.Attributes(
  max_age: Some(31_536_000),
  domain: None,
  path: Some("/"),
  secure: False,
  http_only: True,
  same_site: Some(cookie.Lax),
)

/// リレーの追加、用途の変更、削除が反映されなかった理由。
pub type RelayChangeFailure {
  /// 同じ URL が登録済み。書き込まれていない。
  DuplicateRelay
  /// 書き込まれていないことが確定したほかの DB の失敗。英語の理由を持つ。
  RelayNotSaved(reason: String)
  /// DB に書き込まれたか分からない。
  RelayMaybeSaved
  /// DB には書けたが、接続の一覧が変更を確かめられなかった。
  ConnectionsNotConfirmed
  /// 対象の行が DB に無い。書き込まれていない。
  UnregisteredRelay
}

/// `nostrconnect://` の接続が成立しなかった理由。
pub type NostrconnectFailure {
  /// URI のリレーを DB に登録できなかった、または接続を開けなかった。
  RelayNotRegistered(failure: RelayChangeFailure)
  /// 上限まで待っても、URI のリレーがどれも応答の発行先にならなかった。
  RelayNotConnected
  /// セッションを開けなかった。
  SessionNotOpened(failure: SessionFailure)
}

/// ハンドラーが必要とするものすべて。パスワード以外の状態（アカウント、リレー、
/// プラグイン、セッション、承認待ち）はアクターに問い合わせる関数で受け取り、
/// 表示のたびに現在の値を読む。
pub type Context {
  Context(
    password: String,
    /// アカウントの一覧。読み込み中、応答なしのときは表示する理由を返す。
    accounts: fn() -> Result(List(dashboard.AccountRow), String),
    /// 直近の読み込みで飛ばされた行の一覧。読み込み中、応答なしのときは表示する
    /// 理由を返す。
    skipped: fn() -> Result(List(dashboard.SkippedRow), String),
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
    /// DB からの読み直しを要求する。バンカーが応答しないときは表示する理由を返す。
    reload_accounts: fn() -> Result(Nil, String),
    /// リレーの一覧。締め切りを渡す。`relay_list` が応答しない、DB を読めないときは
    /// 表示する理由を返し、期限内に用途の状態を得られない接続は応答なしとして返す。
    relays: fn(task.Deadline) -> Result(List(dashboard.RelayRow), String),
    /// リレーを DB に登録し、接続を開く。
    add_relay: fn(String, relay_list.Roles) -> Result(Nil, RelayChangeFailure),
    /// DB の `relays` の全行。読めなければ理由を返す。
    registered_relays: fn() -> Result(List(relay_store.Relay), String),
    /// 用途を DB に書き、接続を変える。
    update_relay_roles: fn(relay_store.Relay, relay_list.Roles) ->
      Result(Nil, RelayChangeFailure),
    /// 行を DB から消し、接続を閉じる。
    delete_relay: fn(relay_store.Relay) -> Result(Nil, RelayChangeFailure),
    /// 解釈済みの `nostrconnect://` の情報から、URI のリレーを登録してセッションを開く。
    connect_client: fn(nostrconnect.ConnectRequest, String) ->
      Result(Nil, NostrconnectFailure),
    /// プラグインの一覧。締め切りを渡す。期限内に状態を得られないプラグインは
    /// 応答なしとして返す。
    plugins: fn(task.Deadline) -> List(dashboard.PluginRow),
    /// 無効になったプラグインを名前で再有効化する。
    reenable_plugin: fn(String) -> Result(Nil, ReenableFailure),
    /// 承認済みセッションの一覧。読み込み中、応答なしのときは表示する理由を返す。
    sessions: fn() -> Result(List(dashboard.SessionRow), String),
    /// セッション（署名者, クライアント）を 1 件取り消す。
    revoke: fn(String, String) -> Result(Nil, SessionFailure),
    /// 承認待ちの一覧。読み込み中、応答なしのときは表示する理由を返す。
    pending: fn() -> Result(List(dashboard.PendingRow), String),
    approve: fn(String) -> Result(Nil, SessionFailure),
    deny: fn(String) -> Result(Nil, SessionFailure),
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
/// 要求するが、cookie の署名も暗号化も使わない（言語とテーマの cookie も署名しない）
/// ため起動ごとの乱数でよい。
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
    log.write(
      log.Notice,
      log_prefix,
      "listening on " <> listening_url(address, port),
    )
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
/// 認証を通ってから、表示の言語を決めてルーティングする。Basic 認証の資格情報は
/// ブラウザーが自動送信するため、別オリジンのフォームからの POST は通知ページの 400 で
/// 弾く（`require_same_origin`）。
pub fn handle_request(context: Context, request: Request) -> Response {
  use <- wisp.rescue_crashes
  use request <- wisp.handle_head(request)
  use request <- require_same_origin(request)
  case wisp.path_segments(request) {
    ["healthz"] -> healthz(request)
    segments -> {
      use <- require_password(context, request)
      route(
        context,
        request,
        request_language(request),
        request_theme(request),
        segments,
      )
      |> protect
    }
  }
}

/// 別オリジンのフォームから送られた POST を通知ページの 400 で弾く。`Origin` も
/// `Referer` も無いリクエスト（curl 等）は通る。
///
/// `wisp.csrf_known_header_protection` を 2 回使う。1 回目は `next` を素通りの応答に
/// して検査の結果だけを得て、400 なら通知ページを返す。400 でなければ 2 回目に本物の
/// `next` を渡す（`Origin` も `Referer` も無い要求の cookie の除去は、この 2 回目で
/// 効く）。拒否された要求は cookie を除かれないので、通知ページの言語とテーマは
/// 同じサイトの cookie から通常どおり決められる。この検査は認証の前にあるため、
/// 通知ページには明示的に `protect` を掛ける。
fn require_same_origin(
  request: Request,
  next: fn(Request) -> Response,
) -> Response {
  case wisp.csrf_known_header_protection(request, fn(_) { wisp.ok() }).status {
    400 ->
      dashboard.notice_page(
        request_language(request),
        request_theme(request),
        view.NoSwitch,
        i18n.BadRequest,
        i18n.Translated(i18n.OriginMismatch),
        view.Failure,
        [],
      )
      |> wisp.html_response(400)
      |> protect
    _ -> wisp.csrf_known_header_protection(request, next)
  }
}

/// 認証済みのルート。
fn route(
  context: Context,
  request: Request,
  language: Language,
  theme: view.Theme,
  segments: List(String),
) -> Response {
  case segments {
    [] -> show_dashboard(context, request, language, theme)
    segments
      if segments == view.stylesheet_segments
      || segments == view.script_segments
    -> static_file(request, language, theme)
    segments if segments == view.language_segments ->
      switch_language(request, language, theme)
    segments if segments == view.theme_segments ->
      switch_theme(request, language, theme)
    [first, token] if first == dashboard.approve_segment ->
      approve_connection(context, request, language, theme, token)
    [first, token] if first == dashboard.deny_segment ->
      deny_connection(context, request, language, theme, token)
    segments if segments == dashboard.revoke_segments ->
      revoke_session(context, request, language, theme)
    segments if segments == dashboard.connect_segments ->
      connect_client(context, request, language, theme)
    segments if segments == dashboard.reenable_plugin_segments ->
      reenable_plugin(context, request, language, theme)
    segments if segments == dashboard.reload_accounts_segments ->
      reload_accounts(context, request, language, theme)
    segments if segments == dashboard.new_account_segments ->
      show_new_account(request, language, theme)
    segments if segments == dashboard.new_relay_segments ->
      new_relay(context, request, language, theme)
    segments if segments == dashboard.generate_account_segments ->
      generate_account(request, language, theme)
    segments if segments == dashboard.import_account_segments ->
      import_account(context, request, language, theme)
    segments if segments == dashboard.register_generated_segments ->
      register_generated_account(context, request, language, theme)
    segments ->
      case
        dashboard.parse_account_action_path(segments),
        dashboard.parse_relay_action_path(segments)
      {
        Ok(#(signer, action)), _ ->
          account_action(context, request, language, theme, signer, action)
        _, Ok(#(id, action)) ->
          relay_action(context, request, language, theme, id, action)
        Error(Nil), Error(Nil) ->
          not_found_notice(language, theme, i18n.Translated(i18n.PageNotFound))
      }
  }
}

/// 認証済みの応答すべてに付けるヘッダー。どのページも secret か秘密鍵を含みうるので
/// 保存させず、状態を変えるボタンを他のサイトの枠に埋め込ませない。枠の中の POST は
/// 管理 UI と同じオリジンから送られるので、CSRF の検査では防げない。実行するスクリプトを
/// CSP（`content_security_policy`）で管理 UI のファイルに限り、`content-type` を推測させない。
/// URL（承認の token、署名者の公開鍵）を `Referer` で別のオリジンへ渡さない。`no-referrer` に
/// しないのは、ブラウザーが同じオリジンへの POST の `Origin` を `null` にし、CSRF の検査
/// （`wisp.csrf_known_header_protection`）がすべての POST を拒否するからである。
fn protect(response: Response) -> Response {
  response
  |> wisp.set_header("cache-control", "no-store")
  |> wisp.set_header("x-frame-options", "DENY")
  |> wisp.set_header("content-security-policy", content_security_policy)
  |> wisp.set_header("x-content-type-options", "nosniff")
  |> wisp.set_header("referrer-policy", "same-origin")
}

/// 処理できなかった要求の通知ページの HTML。トーンは `view.Failure` にし、切り替えた
/// 後はダッシュボードを開く（`return_to_dashboard`）。状態コードとヘッダーは呼び出し側が
/// 付ける。
fn failure_page(
  language: Language,
  theme: view.Theme,
  title: i18n.Message,
  message: i18n.Reason,
) -> String {
  dashboard.notice_page(
    language,
    theme,
    return_to_dashboard,
    title,
    message,
    view.Failure,
    [],
  )
}

/// 見出し `NotFound` の 404 の通知ページ。本文は呼び出し側が決め、パスや署名者を
/// 含めない。
fn not_found_notice(
  language: Language,
  theme: view.Theme,
  message: i18n.Reason,
) -> Response {
  failure_page(language, theme, i18n.NotFound, message)
  |> wisp.html_response(404)
}

/// 405 の通知ページ。`allow` の整形は `wisp.method_not_allowed` に任せ、本文だけを
/// HTML にする。メソッドとパスを本文に含めない。
fn method_not_allowed(
  language: Language,
  theme: view.Theme,
  allowed: List(http.Method),
) -> Response {
  wisp.method_not_allowed(allowed:)
  |> wisp.html_body(failure_page(
    language,
    theme,
    i18n.MethodNotAllowed,
    i18n.Translated(i18n.MethodNotAllowedDetail),
  ))
}

/// `wisp.require_method` と同じく、メソッドが違えば `method_not_allowed` を返す。
fn require_method(
  request: Request,
  method: http.Method,
  language: Language,
  theme: view.Theme,
  next: fn() -> Response,
) -> Response {
  case request.method == method {
    True -> next()
    False -> method_not_allowed(language, theme, [method])
  }
}

/// 管理 UI のフォームからは送られない値（欄の欠落、未対応の言語とテーマ）の 400 の
/// 通知ページ。
fn bad_request(language: Language, theme: view.Theme) -> Response {
  failure_page(
    language,
    theme,
    i18n.BadRequest,
    i18n.Translated(i18n.FormNotReadable),
  )
  |> wisp.html_response(400)
}

/// コンテナーの healthcheck 用。認証なしで到達できるため、状態は一切返さない。
fn healthz(request: Request) -> Response {
  use <- wisp.require_method(request, http.Get)
  wisp.ok() |> wisp.string_body("ok")
}

/// 管理 UI の静的ファイル（ビルドした `priv/static/admin.css` と、手で書く
/// `priv/static/admin.js`）。ページと同じく認証の後に置くので、`protect` のヘッダーが付き、
/// ブラウザーは保存しない（更新しても古いファイルが残らない）。パスが
/// `view.stylesheet_segments` か `view.script_segments` に一致したときだけ届き、
/// `serve_static` は要求のパスを `priv` からの相対パスとしてファイルを引く。無いファイルは
/// 404 の通知ページ、GET 以外は `text/plain` の 405（CSS と JS への GET 以外は管理 UI
/// から送られない）にする。
fn static_file(
  request: Request,
  language: Language,
  theme: view.Theme,
) -> Response {
  use <- wisp.require_method(request, http.Get)
  let assert Ok(priv) = wisp.priv_directory("nostr_no_su")
  use <- wisp.serve_static(request, under: "", from: priv)
  not_found_notice(language, theme, i18n.Translated(i18n.PageNotFound))
}

/// 表示の言語。言語の切り替えで保存した cookie、`Accept-Language`、既定の言語の順に
/// 決め、対応していない値は無視する。`Origin` も `Referer` も無い POST では、CSRF の検査
/// （`wisp.csrf_known_header_protection`）が cookie を取り除くので、cookie は使われない。
fn request_language(request: Request) -> Language {
  request.get_cookies(request)
  |> list.key_find(language_cookie)
  |> result.try(i18n.from_code)
  |> result.lazy_or(fn() {
    request.get_header(request, "accept-language")
    |> result.try(i18n.from_accept_language)
  })
  |> result.unwrap(i18n.default_language)
}

/// 表示のテーマ。切り替えで保存した cookie の値から決め、cookie が無いか対応していない
/// 値ならブラウザーの設定にする。`Origin` も `Referer` も無い POST では CSRF の検査が
/// cookie を取り除くので、ブラウザーの設定になる。
fn request_theme(request: Request) -> view.Theme {
  request.get_cookies(request)
  |> list.key_find(theme_cookie)
  |> result.try(view.theme_from_code)
  |> result.unwrap(view.System)
}

/// 言語の切り替え。選んだ言語を cookie に保存し（ブラウザーの設定では cookie を消す）、
/// フォームが送った戻り先へ 303 で戻す。cookie を変えるので POST だけを受け付け、ほかの
/// POST と同じく CSRF の検査の下に置く。フォームが送るのは言語と戻り先のパスだけで、
/// 秘密鍵を運ばない。
fn switch_language(
  request: Request,
  language: Language,
  theme: view.Theme,
) -> Response {
  use <- require_method(request, http.Post, language, theme)
  use form <- wisp.require_form(request)
  case view.language_choice_from_code(form_value(form, view.language_field)) {
    Error(Nil) -> bad_request(language, theme)
    Ok(choice) ->
      wisp.redirect(to: return_path(form_value(form, view.return_field)))
      |> set_preference_cookie(language_cookie, language_cookie_value(choice))
  }
}

/// テーマの切り替え。選んだテーマを cookie に保存し（ブラウザーの設定では cookie を
/// 消す）、フォームが送った戻り先へ 303 で戻す。cookie を変えるので POST だけを受け付け、
/// ほかの POST と同じく CSRF の検査の下に置く。
fn switch_theme(
  request: Request,
  language: Language,
  theme: view.Theme,
) -> Response {
  use <- require_method(request, http.Post, language, theme)
  use form <- wisp.require_form(request)
  case view.theme_from_code(form_value(form, view.theme_field)) {
    Error(Nil) -> bad_request(language, theme)
    Ok(chosen) ->
      wisp.redirect(to: return_path(form_value(form, view.return_field)))
      |> set_preference_cookie(theme_cookie, theme_cookie_value(chosen))
  }
}

/// cookie に保存する値。ブラウザーの設定は保存しない。
fn theme_cookie_value(theme: view.Theme) -> Option(String) {
  case theme {
    view.System -> None
    view.Light | view.Dark -> Some(view.theme_code(theme))
  }
}

/// cookie に保存する値。ブラウザーの設定は保存しない。
fn language_cookie_value(choice: view.LanguageChoice) -> Option(String) {
  case choice {
    view.BrowserLanguage -> None
    view.ChosenLanguage(_) -> Some(view.language_choice_code(choice))
  }
}

/// テーマか言語の選択を cookie に反映する。値が無ければ（ブラウザーの設定）cookie を消す。
fn set_preference_cookie(
  response: Response,
  name: String,
  value: Option(String),
) -> Response {
  case value {
    None -> response.expire_cookie(response, name, preference_cookie_attributes)
    Some(value) ->
      response.set_cookie(response, name, value, preference_cookie_attributes)
  }
}

/// テーマか言語を切り替えた後に開くパス。`/` で始まる値をパスとクエリーに分け、
/// パスはセグメントごと、クエリーはキーと値ごとにパーセントエンコードしてから
/// 組み立て直すので、`//host` や `/\host` のような別のオリジンを指す形にならない。
/// クエリーを分解できないときは捨てる。`/` で始まらない値はダッシュボードにする。
fn return_path(raw: String) -> String {
  case raw {
    "/" <> rest -> {
      let #(path, query) =
        string.split_once(rest, "?") |> result.unwrap(#(rest, ""))
      return_segments(path) <> return_query(query)
    }
    _ -> "/"
  }
}

/// パスの空のセグメントを除いてセグメントごとにパーセントエンコードし、
/// `/` で始まるパスに組み立てる。
fn return_segments(path: String) -> String {
  string.split(path, "/")
  |> list.filter(fn(segment) { segment != "" })
  |> list.map(uri.percent_encode)
  |> string.join("/")
  |> string.append("/", _)
}

/// クエリーのうちキーが空の組を除き、キーと値ごとにパーセントエンコードして
/// `?` 付きで返す。残る組が無いときと分解できないときは空文字列を返す。
fn return_query(query: String) -> String {
  case
    uri.parse_query(query)
    |> result.map(list.filter(_, fn(pair) { pair.0 != "" }))
  {
    Ok([_, ..] as pairs) -> "?" <> uri.query_to_string(pairs)
    _ -> ""
  }
}

/// ダッシュボードの 6 つの節に共通の締め切り。バンカーの問い合わせと接続の状態の
/// 問い合わせ（どちらも 5 秒）と同値なので、相手が答えないときどちらが先に切れるかは
/// ミリ秒の端数で決まる。バンカーの節はどちらでも同じ囲みになり、文言が上流の英語の
/// 理由か締め切り超過の訳文かだけが変わる。リレーの行は、接続の問い合わせが先に
/// 切れれば切断、締め切りが先なら応答なしのバッジになる。どちらでも行は残り、用途の
/// 状態を待つ時間は締め切りで止まる（`relay_list` の応答と DB の読み込みは締め切りの
/// 外で、`app.relay_rows` の Doc のとおり最悪 18 秒になる）。
const snapshot_deadline_ms = 5000

/// ダッシュボードが表示する状態を、共通の締め切りの下で集める。締め切りを自分で
/// 守れない accounts・skipped・pending・sessions を先に `task.start` で起動し、
/// 続けて `context.plugins`、`context.relays` を呼び出し元のプロセスで実行してから、
/// 最後に 4 つのタスクを残り時間で `task.await` する。plugins と relays は内部で
/// 複数の問い合わせを同じ締め切りで待つため、これらも別プロセスにすると内側の
/// 締め切りと外側の `await` が同時に切れる競争になり、間に合った行だけを出す
/// （`dashboard.RoleState` の `Unanswered` など）動きが観測できなくなる。呼び出し元で
/// 実行すればこの競争は無い。描画時点の時刻（相対表示に使う）もここで取る。単体テストが
/// 呼べるよう公開する。
pub fn snapshot(
  context: Context,
  deadline: task.Deadline,
) -> dashboard.Snapshot {
  let accounts = task.start(context.accounts)
  let skipped = task.start(context.skipped)
  let pending = task.start(context.pending)
  let sessions = task.start(context.sessions)
  let plugins = context.plugins(deadline)
  let relays = context.relays(deadline)
  dashboard.Snapshot(
    accounts: within(task.await(accounts, deadline)),
    skipped: within(task.await(skipped, deadline)),
    pending: within(task.await(pending, deadline)),
    relays: result.map_error(relays, i18n.Untranslated),
    sessions: within(task.await(sessions, deadline)),
    plugins:,
    now: time.now_seconds(),
  )
}

/// タスクの結果を、ダッシュボードが表示する理由に写す。締め切りに間に合わなければ
/// 訳した「今は取得できません。」に、間に合っても得られなければ上流の英語の理由を
/// 訳さずに包む。
fn within(awaited: Result(Result(a, String), Nil)) -> Result(a, i18n.Reason) {
  case awaited {
    Ok(Ok(value)) -> Ok(value)
    Ok(Error(reason)) -> Error(i18n.Untranslated(reason))
    Error(Nil) -> Error(i18n.Translated(i18n.NotAvailable))
  }
}

/// ダッシュボード。表示に必要な状態をここで集め、描画は純粋関数へ渡す。
fn show_dashboard(
  context: Context,
  request: Request,
  language: Language,
  theme: view.Theme,
) -> Response {
  use <- require_method(request, http.Get, language, theme)
  snapshot(context, task.deadline_in(snapshot_deadline_ms))
  |> dashboard.render(language, theme, _)
  |> wisp.html_response(200)
}

/// 承認ページ。GET は接続要求の内容を出し、POST は承認する。クライアントは
/// `auth_url` として渡されたこの URL を開く。
fn approve_connection(
  context: Context,
  request: Request,
  language: Language,
  theme: view.Theme,
  token: String,
) -> Response {
  case request.method {
    http.Get -> {
      use entry <- with_pending(context, language, theme, token)
      let accounts = result.map_error(context.accounts(), i18n.Untranslated)
      wisp.html_response(
        dashboard.approval_page(language, theme, accounts, entry),
        200,
      )
    }
    http.Post -> {
      use entry <- with_pending(context, language, theme, token)
      decision_response(
        language,
        theme,
        context.approve(token),
        session_change_line(ConnectionApproved, entry.signer, entry.client),
        i18n.Approved,
        i18n.ApprovedCloseWindow,
        view.Success,
      )
    }
    _ -> method_not_allowed(language, theme, [http.Get, http.Post])
  }
}

/// 接続要求を 1 件拒否する。
fn deny_connection(
  context: Context,
  request: Request,
  language: Language,
  theme: view.Theme,
  token: String,
) -> Response {
  use <- require_method(request, http.Post, language, theme)
  use entry <- with_pending(context, language, theme, token)
  decision_response(
    language,
    theme,
    context.deny(token),
    session_change_line(ConnectionDenied, entry.signer, entry.client),
    i18n.Denied,
    i18n.DeniedCloseWindow,
    view.Neutral,
  )
}

/// 承認ページの表示と承認・拒否の前に、承認待ちの一覧からトークンの行を引く。
/// 一覧を得られなければ 503 の通知ページ、無ければ 404 の通知ページを返し、
/// 表示や承認・拒否を呼ばない。不明、失効、処理済みのトークンは一覧に無いので
/// 404 になる。404 の理由は失効の可能性を含む訳した文。ログに出す署名者とクライアントは、
/// トークンではなくこの行の値から取る。
fn with_pending(
  context: Context,
  language: Language,
  theme: view.Theme,
  token: String,
  next: fn(dashboard.PendingRow) -> Response,
) -> Response {
  case context.pending() {
    Error(reason) ->
      unavailable_notice(language, theme, i18n.BunkerNotAvailable, reason)
    Ok(rows) ->
      case list.find(rows, fn(entry) { entry.token == token }) {
        Ok(entry) -> next(entry)
        Error(Nil) ->
          not_found_notice(
            language,
            theme,
            i18n.Translated(
              i18n.ApprovalRequestGone(engine.pending_ttl_minutes()),
            ),
          )
      }
  }
}

/// 接続とセッションへの操作の種類。ログ行の言い回しを決める。
pub type SessionChange {
  ConnectionApproved
  ConnectionDenied
  SessionRevoked
  ClientConnected
}

/// プラグインの再有効化が失敗する 2 通り。
pub type ReenableFailure {
  /// 名前に一致するプラグインが無い。
  PluginNotFound(reason: String)
  /// ランナーが居ないか、期限内に応答しなかった。打ち切った後にランナーが
  /// 処理して反映することがある。
  PluginNotAnswered(reason: String)
}

/// 承認・拒否・取り消し・クライアントの接続 1 件のログ行の本文（接頭辞を除く）。値は
/// 署名者とクライアントの公開鍵だけで、承認ページのトークンを含めない。
pub fn session_change_line(
  change: SessionChange,
  signer: String,
  client: String,
) -> String {
  let done = case change {
    ConnectionApproved -> "approved the connection of client "
    ConnectionDenied -> "denied the connection of client "
    SessionRevoked -> "revoked the session of client "
    ClientConnected -> "connected client "
  }
  done <> client <> " to signer " <> signer
}

/// 承認・拒否の結果。クライアントは応答イベントを待っているので、ここでは人間に
/// 終わったことだけを伝える。処理できたときは `log_line` を 1 行ログに出す。処理
/// できなかった要求は `session_failure_response` に渡す。承認と拒否はどちらも 200
/// なので、処理できたときの見出し（`done`）、文（`message`）、通知の色（`tone`）は
/// 呼び出し側が渡す。
fn decision_response(
  language: Language,
  theme: view.Theme,
  outcome: Result(Nil, SessionFailure),
  log_line: String,
  done: i18n.Message,
  message: i18n.Message,
  tone: view.Tone,
) -> Response {
  case outcome {
    Ok(Nil) -> {
      log.write(log.Notice, log_prefix, log_line)
      dashboard.notice_page(
        language,
        theme,
        return_to_dashboard,
        done,
        i18n.Translated(message),
        tone,
        [],
      )
      |> wisp.html_response(200)
    }
    Error(failure) -> session_failure_response(language, theme, failure)
  }
}

/// セッションを 1 件取り消してダッシュボードへ戻す。再読み込みで取り消しが
/// 再送されないよう 303 でリダイレクトする。取り消せなかったときは
/// `session_failure_response` に渡す。
fn revoke_session(
  context: Context,
  request: Request,
  language: Language,
  theme: view.Theme,
) -> Response {
  use <- require_method(request, http.Post, language, theme)
  use form <- wisp.require_form(request)
  case
    list.key_find(form.values, dashboard.signer_field),
    list.key_find(form.values, dashboard.client_field)
  {
    Ok(signer), Ok(client) ->
      case context.revoke(signer, client) {
        Ok(Nil) -> {
          log.write(
            log.Notice,
            log_prefix,
            session_change_line(SessionRevoked, signer, client),
          )
          wisp.redirect(to: "/")
        }
        Error(failure) -> session_failure_response(language, theme, failure)
      }
    _, _ -> bad_request(language, theme)
  }
}

/// 承認・拒否・取り消しの失敗の応答。対象が無ければ 404、
/// 書き込まれていないことが確定していれば 409、受け付けられなければ 503 の
/// `BunkerNotAvailable`、反映されたか分からなければ 503 の `ChangeNotConfirmed`
/// の通知ページにする。「分からない」をアカウントの変更と違って 202 にしないのは、
/// 承認・拒否・取り消しは再送しても害が無い（反映済みなら 404 になる）ので、
/// やり直してよい一時的な失敗として返せるからである。
fn session_failure_response(
  language: Language,
  theme: view.Theme,
  failure: SessionFailure,
) -> Response {
  case failure {
    bunker.SessionNotFound(reason) ->
      not_found_notice(language, theme, i18n.Untranslated(reason))
    bunker.SessionNotApplied(reason) ->
      failure_page(
        language,
        theme,
        i18n.ChangeNotApplied,
        i18n.Untranslated(reason),
      )
      |> wisp.html_response(409)
    bunker.SessionNotReady(reason) ->
      unavailable_notice(language, theme, i18n.BunkerNotAvailable, reason)
    bunker.SessionMaybeApplied(cause) ->
      not_confirmed_notice(
        language,
        theme,
        i18n.Translated(not_confirmed_message(cause)),
        503,
      )
  }
}

/// クライアントの接続ページと、その送信。GET はフォームを 200 で出す（アカウントの
/// 一覧を引けなくてもカードの中に理由を出す）。POST は一覧を引けなければ同じページを
/// 503 で返し、引けたら URI を解釈し、選ばれた署名者が一覧にあることを確かめてから
/// セッションを開く。
fn connect_client(
  context: Context,
  request: Request,
  language: Language,
  theme: view.Theme,
) -> Response {
  case request.method {
    http.Get -> {
      let accounts = result.map_error(context.accounts(), i18n.Untranslated)
      connect_pages.connect_client_page(language, theme, accounts, "", "", None)
      |> wisp.html_response(200)
    }
    http.Post -> {
      use form <- wisp.require_form(request)
      let raw_uri = form_value(form, dashboard.nostrconnect_uri_field)
      let signer = form_value(form, dashboard.signer_field)
      let echoed_uri = without_control_characters(raw_uri)
      case context.accounts() {
        Error(reason) ->
          connect_pages.connect_client_page(
            language,
            theme,
            Error(i18n.Untranslated(reason)),
            echoed_uri,
            signer,
            None,
          )
          |> wisp.html_response(503)
        Ok(rows) -> {
          let redraw = fn(reason) {
            connect_pages.connect_client_page(
              language,
              theme,
              Ok(rows),
              echoed_uri,
              signer,
              Some(reason),
            )
          }
          case nostrconnect.parse(string.trim(raw_uri)) {
            Error(error) ->
              redraw(i18n.Translated(parse_message(error)))
              |> wisp.html_response(400)
            Ok(connect_request) ->
              case list.any(rows, fn(row) { row.signer == signer }) {
                False ->
                  redraw(i18n.Translated(i18n.SigningAccountNotFound))
                  |> wisp.html_response(400)
                True ->
                  connect_failure_response(
                    language,
                    theme,
                    context.connect_client(connect_request, signer),
                    signer,
                    connect_request.client,
                    redraw,
                  )
              }
          }
        }
      }
    }
    _ -> method_not_allowed(language, theme, [http.Get, http.Post])
  }
}

/// `nostrconnect.parse` の失敗を、フォームに出す文言に写す。`NoRelay` と
/// `InvalidRelayUrl` は直し方が同じなので同じ文言にまとめる。
fn parse_message(error: nostrconnect.ParseError) -> i18n.Message {
  case error {
    nostrconnect.NotNostrconnect -> i18n.NotNostrconnectUri
    nostrconnect.MalformedClientPubkey -> i18n.NostrconnectClientInvalid
    nostrconnect.MalformedQuery -> i18n.NostrconnectQueryInvalid
    nostrconnect.NoRelay | nostrconnect.InvalidRelayUrl(_) ->
      i18n.NostrconnectRelayInvalid
    nostrconnect.NoSecret -> i18n.NostrconnectSecretMissing
  }
}

/// クライアントの接続の結果。成功ならログを 1 行出し、ダッシュボードへ 303 で戻す。
/// 失敗はリレーの登録の失敗を `relay_failure_response` に渡し、それ以外は状態コードごとに
/// フォームを描き直すか「変更を確認できませんでした」の通知ページにする。
fn connect_failure_response(
  language: Language,
  theme: view.Theme,
  outcome: Result(Nil, NostrconnectFailure),
  signer: String,
  client: String,
  redraw: fn(i18n.Reason) -> String,
) -> Response {
  case outcome {
    Ok(Nil) -> {
      log.write(
        log.Notice,
        log_prefix,
        session_change_line(ClientConnected, signer, client),
      )
      wisp.redirect(to: "/")
    }
    Error(RelayNotRegistered(failure)) ->
      relay_failure_response(language, theme, failure, redraw)
    Error(RelayNotConnected) ->
      redraw(i18n.Translated(i18n.NostrconnectRelayNotConnected))
      |> wisp.html_response(503)
    Error(SessionNotOpened(bunker.SessionNotFound(reason)))
    | Error(SessionNotOpened(bunker.SessionNotApplied(reason))) ->
      redraw(i18n.Untranslated(reason)) |> wisp.html_response(409)
    Error(SessionNotOpened(bunker.SessionNotReady(reason))) ->
      redraw(i18n.Untranslated(reason)) |> wisp.html_response(503)
    Error(SessionNotOpened(bunker.SessionMaybeApplied(cause))) ->
      not_confirmed_notice(
        language,
        theme,
        i18n.Translated(not_confirmed_message(cause)),
        202,
      )
  }
}

/// 無効になったプラグインを再有効化してダッシュボードへ戻す。再読み込みで
/// 再送されないよう 303。失敗は取り消しと同じく 404 と 503。再有効化の 1 行は
/// ここではなくランナーがプラグインの接頭辞を付けて出す（`plugin_runner.reenable`）。
fn reenable_plugin(
  context: Context,
  request: Request,
  language: Language,
  theme: view.Theme,
) -> Response {
  use <- require_method(request, http.Post, language, theme)
  use form <- wisp.require_form(request)
  case list.key_find(form.values, dashboard.plugin_name_field) {
    Ok(plugin) ->
      case context.reenable_plugin(plugin) {
        Ok(Nil) -> wisp.redirect(to: "/")
        Error(failure) -> reenable_failure_response(language, theme, failure)
      }
    Error(Nil) -> bad_request(language, theme)
  }
}

/// 再有効化の失敗の応答。名前に一致するプラグインが無ければ取り消しと同じ 404、
/// ランナーが応答しなければ 503 の通知ページにする。
fn reenable_failure_response(
  language: Language,
  theme: view.Theme,
  failure: ReenableFailure,
) -> Response {
  case failure {
    PluginNotFound(reason) ->
      not_found_notice(language, theme, i18n.Untranslated(reason))
    PluginNotAnswered(reason) ->
      not_confirmed_notice(language, theme, i18n.Untranslated(reason), 503)
  }
}

/// DB からの読み直しを要求してダッシュボードへ戻す。再読み込みで再送されないよう
/// 303。バンカーが応答しないときは 503 の「バンカーを利用できません」。
fn reload_accounts(
  context: Context,
  request: Request,
  language: Language,
  theme: view.Theme,
) -> Response {
  use <- require_method(request, http.Post, language, theme)
  case context.reload_accounts() {
    Ok(Nil) -> wisp.redirect(to: "/")
    Error(reason) ->
      unavailable_notice(language, theme, i18n.BunkerNotAvailable, reason)
  }
}

/// アカウントの登録画面。
fn show_new_account(
  request: Request,
  language: Language,
  theme: view.Theme,
) -> Response {
  use <- require_method(request, http.Get, language, theme)
  account_pages.new_account_page(language, theme, "", None)
  |> wisp.html_response(200)
}

/// 鍵を生成し、確認ページで nsec を 1 回だけ表示する。ここでは登録しないので、
/// 再読み込みで再送されても別の鍵の確認ページが出るだけで、何も登録されない。
/// 本文を読まないので、フォームの本文が無い POST も受け付ける。
fn generate_account(
  request: Request,
  language: Language,
  theme: view.Theme,
) -> Response {
  use <- require_method(request, http.Post, language, theme)
  let generated = account.generate(crypto.strong_random_bytes)
  account_pages.generated_key_page(
    language,
    theme,
    account.npub(generated),
    account.nsec(generated),
    "",
    None,
  )
  |> wisp.html_response(200)
}

/// nsec 入力によるアカウントの登録。完了ページで nsec を 1 回だけ表示する。
fn import_account(
  context: Context,
  request: Request,
  language: Language,
  theme: view.Theme,
) -> Response {
  let reject_label = fn(_account, label, reason) {
    account_pages.new_account_page(
      language,
      theme,
      label,
      Some(i18n.Translated(reason)),
    )
  }
  let on_failure = fn(_account, label, failure) {
    change_failure_response(language, theme, failure, fn(reason) {
      account_pages.new_account_page(language, theme, label, Some(reason))
    })
  }
  use account, label <- register(
    context,
    request,
    language,
    theme,
    reject_label,
    on_failure,
  )
  account_pages.registered_page(
    language,
    theme,
    account.npub(account),
    label,
    account.nsec(account),
  )
  |> wisp.html_response(200)
}

/// 生成の確認ページから送られた鍵の登録。nsec は確認ページで表示済みなので描画せず、
/// ダッシュボードへ 303 で戻す。ラベルが規則に反するか、バンカーが登録に失敗したときは、
/// 生成した鍵を失わないよう、送られた nsec の確認ページを理由付きで返す（状態コードは
/// nsec 入力による登録と同じ。この POST の応答の本文だけに出る）。
fn register_generated_account(
  context: Context,
  request: Request,
  language: Language,
  theme: view.Theme,
) -> Response {
  let reject_label = fn(generated, label, reason) {
    account_pages.generated_key_page(
      language,
      theme,
      account.npub(generated),
      account.nsec(generated),
      label,
      Some(account_pages.InvalidLabel(reason)),
    )
  }
  let on_failure = fn(generated, label, failure) {
    let #(problem, status) = generated_key_problem(failure)
    account_pages.generated_key_page(
      language,
      theme,
      account.npub(generated),
      account.nsec(generated),
      label,
      Some(problem),
    )
    |> wisp.html_response(status)
  }
  use _account, _label <- register(
    context,
    request,
    language,
    theme,
    reject_label,
    on_failure,
  )
  wisp.redirect(to: "/")
}

/// 登録の 2 つのルートが共有する検査と失敗の経路。nsec が不正なら 400 で登録画面を
/// 返し、ラベルだけが不正なら 400 で `reject_label` が描画するページを返す。バンカーの
/// 失敗は `on_failure` に渡す。どの失敗でも、ラベルの欄には送られた値から制御文字を
/// 除いた値を入れる。nsec のフォームの値はそのまま反射しない。
fn register(
  context: Context,
  request: Request,
  language: Language,
  theme: view.Theme,
  reject_label: fn(Account, String, i18n.Message) -> String,
  on_failure: fn(Account, String, ChangeFailure) -> Response,
  on_success: fn(Account, String) -> Response,
) -> Response {
  use <- require_method(request, http.Post, language, theme)
  use form <- wisp.require_form(request)
  let raw_label = form_value(form, dashboard.label_field)
  let echoed_label = without_control_characters(raw_label)
  case parse_private_key(form) {
    Error(reason) ->
      account_pages.new_account_page(
        language,
        theme,
        echoed_label,
        Some(i18n.Translated(reason)),
      )
      |> wisp.html_response(400)
    Ok(account) ->
      case parse_label(raw_label) {
        Error(reason) ->
          reject_label(account, echoed_label, reason)
          |> wisp.html_response(400)
        Ok(label) ->
          case context.add_account(account, label) {
            Ok(Nil) -> on_success(account, label)
            Error(failure) -> on_failure(account, echoed_label, failure)
          }
      }
  }
}

/// フォームの nsec を検査し、登録するアカウントにする。理由は入力を含まない。
/// `nip19.decode` が鍵を 32 バイトに限るので、`account.from_privkey` が拒否するのは
/// 範囲外の鍵だけである。
fn parse_private_key(form: wisp.FormData) -> Result(Account, i18n.Message) {
  use privkey <- result.try(
    form_value(form, dashboard.nsec_field)
    |> nip19.decode(nip19.Nsec)
    |> result.map_error(i18n.InvalidNsec),
  )
  account.from_privkey(privkey)
  |> result.replace_error(i18n.PrivateKeyOutOfRange)
}

/// フォームの値。欄が無ければ空文字列として扱い、以降の検査で拒否させる。
fn form_value(form: wisp.FormData, name: String) -> String {
  list.key_find(form.values, name) |> result.unwrap("")
}

/// ラベルを検査する。送られた値のまま制御文字（Unicode の Cc）を含むものを拒否し、
/// 前後の空白を除いてから、空のものと符号位置が多すぎるものを拒否する。制御文字を
/// trim の前に検査するのは、前後の制御文字が trim で黙って消えないようにするため
/// である。長さを書記素クラスターで数えないのは、結合文字を続けた文字列が長さ 1 の
/// まま任意のバイト数になり、上限にならないからである。
fn parse_label(raw: String) -> Result(String, i18n.Message) {
  let label = string.trim(raw)
  case
    list.any(string.to_utf_codepoints(raw), is_control_character),
    label,
    list.length(string.to_utf_codepoints(label))
    > dashboard.max_label_code_points
  {
    True, _, _ -> Error(i18n.LabelHasControlCharacters)
    False, "", _ -> Error(i18n.LabelEmpty)
    False, _, True ->
      Error(i18n.LabelTooLong(max: dashboard.max_label_code_points))
    False, _, False -> Ok(label)
  }
}

/// 入力の誤りで戻したフォームの欄に入れる値を作る。制御文字は欄で見えず、残すと同じに
/// 見える欄を送り直して同じ 400 を繰り返すので除く。前後の空白は利用者が打った値として
/// 残す（サーバーが trim するので変える必要が無い）。
fn without_control_characters(raw: String) -> String {
  string.to_utf_codepoints(raw)
  |> list.filter(fn(code_point) { !is_control_character(code_point) })
  |> string.from_utf_codepoints
}

/// Unicode の Cc（C0、DEL、C1）の符号位置かどうか。`string.trim` は U+0085 や
/// 末尾の `\n` を黙って消すので、`parse_label` は trim の前の値をこれで検査する。
fn is_control_character(code_point: UtfCodepoint) -> Bool {
  let code = string.utf_codepoint_to_int(code_point)
  code <= 0x1f || { code >= 0x7f && code <= 0x9f }
}

/// リレーの追加のページと、その送信。
fn new_relay(
  context: Context,
  request: Request,
  language: Language,
  theme: view.Theme,
) -> Response {
  case request.method {
    http.Get ->
      relay_pages.new_relay_page(
        language,
        theme,
        "",
        relay_list.Roles(monitor: True, bunker: True),
        None,
      )
      |> wisp.html_response(200)
    http.Post -> add_relay(context, request, language, theme)
    _ -> method_not_allowed(language, theme, [http.Get, http.Post])
  }
}

/// リレーの追加。URL は前後の空白を除いて保存する。検査の順は URL、用途。
fn add_relay(
  context: Context,
  request: Request,
  language: Language,
  theme: view.Theme,
) -> Response {
  use form <- wisp.require_form(request)
  let raw_url = form_value(form, dashboard.relay_url_field)
  let roles = relay_roles(form)
  let echoed_url = without_control_characters(raw_url)
  let redraw = fn(reason) {
    relay_pages.new_relay_page(language, theme, echoed_url, roles, Some(reason))
  }
  case parse_relay_url(raw_url) {
    Error(reason) -> redraw(i18n.Translated(reason)) |> wisp.html_response(400)
    Ok(url) ->
      case roles.monitor || roles.bunker {
        False ->
          redraw(i18n.Translated(i18n.RelayRoleRequired))
          |> wisp.html_response(400)
        True ->
          relay_change_response(
            language,
            theme,
            context.add_relay(url, roles),
            redraw,
          )
      }
  }
}

/// URL の前後の空白を除き、`ws://` か `wss://` で始まり、`relay_client.to_request` が
/// 解釈できることを検査する。通れば trim した値を返す。
fn parse_relay_url(raw: String) -> Result(String, i18n.Message) {
  let trimmed = string.trim(raw)
  let has_scheme = case trimmed {
    "ws://" <> _ | "wss://" <> _ -> True
    _ -> False
  }
  case has_scheme, relay_client.to_request(trimmed) {
    True, Ok(_) -> Ok(trimmed)
    _, _ -> Error(i18n.InvalidRelayUrl)
  }
}

/// フォームの用途。チェックの無いチェックボックスは送られない。
fn relay_roles(form: wisp.FormData) -> relay_list.Roles {
  let checked = fn(name) { result.is_ok(list.key_find(form.values, name)) }
  relay_list.Roles(
    monitor: checked(dashboard.monitor_field),
    bunker: checked(dashboard.bunker_field),
  )
}

/// リレーの変更の失敗の応答。書き込まれていないことが確定していれば 409、DB には
/// 書けたが確かめられなければ 202 の通知ページにする。対象の行が DB に無ければ 404。
/// 202 にする理由は `change_failure_response` と同じで、確かめられない変更を「拒否された」と
/// 見せると利用者がやり直してしまうからである。
fn relay_failure_response(
  language: Language,
  theme: view.Theme,
  failure: RelayChangeFailure,
  render: fn(i18n.Reason) -> String,
) -> Response {
  case failure {
    DuplicateRelay ->
      render(i18n.Translated(i18n.RelayAlreadyRegistered))
      |> wisp.html_response(409)
    RelayNotSaved(reason) ->
      render(i18n.Untranslated(reason)) |> wisp.html_response(409)
    RelayMaybeSaved ->
      not_confirmed_notice(
        language,
        theme,
        i18n.Translated(i18n.StoreDidNotConfirm),
        202,
      )
    ConnectionsNotConfirmed ->
      not_confirmed_notice(
        language,
        theme,
        i18n.Translated(i18n.RelayConnectionsNotConfirmed),
        202,
      )
    UnregisteredRelay ->
      not_found_notice(language, theme, i18n.Translated(i18n.RelayNotFound))
  }
}

/// リレーの変更の結果。成功ならダッシュボードへ 303 で戻し（再読み込みで変更を再送させ
/// ない）、失敗なら `relay_failure_response` に渡す。追加、用途の変更、削除が使う。
fn relay_change_response(
  language: Language,
  theme: view.Theme,
  outcome: Result(Nil, RelayChangeFailure),
  render: fn(i18n.Reason) -> String,
) -> Response {
  case outcome {
    Ok(Nil) -> wisp.redirect(to: "/")
    Error(failure) -> relay_failure_response(language, theme, failure, render)
  }
}

/// DB の一覧から id の行を引く。一覧を得られなければ 503、無ければ 404。
fn with_relay(
  context: Context,
  language: Language,
  theme: view.Theme,
  id: Int,
  next: fn(relay_store.Relay) -> Response,
) -> Response {
  case context.registered_relays() {
    Error(reason) ->
      unavailable_notice(language, theme, i18n.RelaysNotAvailable, reason)
    Ok(rows) ->
      case list.find(rows, fn(row) { row.id == id }) {
        Ok(row) -> next(row)
        Error(Nil) ->
          not_found_notice(language, theme, i18n.Translated(i18n.RelayNotFound))
      }
  }
}

/// リレー 1 件への操作。DB の行を引いてから、GET は操作のページを、POST は変更を
/// 実行する。
fn relay_action(
  context: Context,
  request: Request,
  language: Language,
  theme: view.Theme,
  id: Int,
  action: dashboard.RelayAction,
) -> Response {
  use relay <- with_relay(context, language, theme, id)
  case request.method, action {
    http.Get, dashboard.EditRelayRoles ->
      relay_pages.relay_action_page(
        language,
        theme,
        relay,
        dashboard.EditRelayRoles,
        None,
        relay_states(context, id),
        None,
      )
      |> wisp.html_response(200)
    http.Get, dashboard.DeleteRelay ->
      relay_pages.relay_action_page(
        language,
        theme,
        relay,
        dashboard.DeleteRelay,
        None,
        None,
        None,
      )
      |> wisp.html_response(200)
    http.Post, dashboard.EditRelayRoles -> {
      use form <- wisp.require_form(request)
      let roles = relay_roles(form)
      let redraw = fn(reason) {
        relay_pages.relay_action_page(
          language,
          theme,
          relay,
          dashboard.EditRelayRoles,
          Some(roles),
          relay_states(context, id),
          Some(reason),
        )
      }
      case roles.monitor || roles.bunker {
        False ->
          redraw(i18n.Translated(i18n.RelayRoleRequired))
          |> wisp.html_response(400)
        True ->
          relay_change_response(
            language,
            theme,
            context.update_relay_roles(relay, roles),
            redraw,
          )
      }
    }
    http.Post, dashboard.DeleteRelay ->
      relay_change_response(
        language,
        theme,
        context.delete_relay(relay),
        fn(reason) {
          relay_pages.relay_action_page(
            language,
            theme,
            relay,
            dashboard.DeleteRelay,
            None,
            None,
            Some(reason),
          )
        },
      )
    _, _ -> method_not_allowed(language, theme, [http.Get, http.Post])
  }
}

/// リレー 1 件の用途の接続状態。一覧を得られないときと行が無いときは `None` にし、
/// 用途の編集のページはバッジを出さない。
fn relay_states(context: Context, id: Int) -> Option(dashboard.RelayRow) {
  case context.relays(task.deadline_in(snapshot_deadline_ms)) {
    Ok(rows) -> list.find(rows, fn(row) { row.id == id }) |> option.from_result
    Error(_) -> None
  }
}

/// アカウント 1 件への操作。アカウントの一覧に署名者があれば従来どおりの操作を、
/// 無ければ削除に限って読み込みで飛ばされた行の一覧から探す。一覧を得られなければ
/// 503。以降のログとバンカーへの呼び出しには、呼び出し側が渡した文字列ではなく、
/// 一覧の行の値を使う。
fn account_action(
  context: Context,
  request: Request,
  language: Language,
  theme: view.Theme,
  signer: String,
  action: dashboard.AccountAction,
) -> Response {
  case context.accounts() {
    Error(reason) ->
      unavailable_notice(language, theme, i18n.AccountsNotAvailable, reason)
    Ok(rows) ->
      case list.find(rows, fn(row) { row.signer == signer }) {
        Ok(row) ->
          registered_account_action(
            context,
            request,
            language,
            theme,
            row,
            action,
          )
        Error(Nil) ->
          unregistered_account_action(
            context,
            request,
            language,
            theme,
            signer,
            action,
          )
      }
  }
}

/// アカウントの一覧にある署名者への操作。GET は操作のページを、POST は操作を
/// 実行する。
fn registered_account_action(
  context: Context,
  request: Request,
  language: Language,
  theme: view.Theme,
  row: dashboard.AccountRow,
  action: dashboard.AccountAction,
) -> Response {
  case request.method, action {
    http.Get, _ ->
      account_pages.account_action_page(
        language,
        theme,
        row,
        action,
        None,
        None,
      )
      |> wisp.html_response(200)
    http.Post, dashboard.EditLabel ->
      update_label(context, request, language, theme, row)
    http.Post, dashboard.RotateSecret ->
      apply_account_change(
        language,
        theme,
        context.rotate_secret(row.signer),
        account_pages.account_action_page(language, theme, row, action, None, _),
      )
    http.Post, dashboard.DeleteAccount ->
      apply_account_change(
        language,
        theme,
        context.remove_account(row.signer),
        account_pages.account_action_page(language, theme, row, action, None, _),
      )
    http.Post, dashboard.RevealPrivateKey ->
      reveal_private_key(context, request, language, theme, row)
    _, _ -> method_not_allowed(language, theme, [http.Get, http.Post])
  }
}

/// アカウントの一覧に無い署名者への操作。読み込めない行（`MalformedPubkey`）を除く
/// 飛ばされた行の削除だけを扱い、それ以外の操作と、どちらの一覧にも無い署名者は
/// 404 にする。
fn unregistered_account_action(
  context: Context,
  request: Request,
  language: Language,
  theme: view.Theme,
  signer: String,
  action: dashboard.AccountAction,
) -> Response {
  case action {
    dashboard.DeleteAccount ->
      case context.skipped() {
        Error(reason) ->
          unavailable_notice(language, theme, i18n.AccountsNotAvailable, reason)
        Ok(rows) ->
          case
            list.find(rows, fn(row) {
              row.pubkey == signer && row.reason != vault.MalformedPubkey
            })
          {
            Ok(row) ->
              unreadable_account_action(context, request, language, theme, row)
            Error(Nil) ->
              not_found_notice(
                language,
                theme,
                i18n.Translated(i18n.AccountNotFound),
              )
          }
      }
    _ ->
      not_found_notice(language, theme, i18n.Translated(i18n.AccountNotFound))
  }
}

/// 読み込みで飛ばされた行の削除。GET は確認ページを、POST は削除を実行する。
fn unreadable_account_action(
  context: Context,
  request: Request,
  language: Language,
  theme: view.Theme,
  row: dashboard.SkippedRow,
) -> Response {
  case request.method {
    http.Get ->
      account_pages.unreadable_delete_page(language, theme, row, None)
      |> wisp.html_response(200)
    http.Post ->
      apply_account_change(
        language,
        theme,
        context.remove_account(row.pubkey),
        account_pages.unreadable_delete_page(language, theme, row, _),
      )
    _ -> method_not_allowed(language, theme, [http.Get, http.Post])
  }
}

/// ラベルの差し替え。ラベルが規則に反すれば 400 で編集のページを返す。400 と 409 の
/// 編集のページの欄には送られた値を入れる。
fn update_label(
  context: Context,
  request: Request,
  language: Language,
  theme: view.Theme,
  row: dashboard.AccountRow,
) -> Response {
  use form <- wisp.require_form(request)
  let raw_label = form_value(form, dashboard.label_field)
  let echoed_label = Some(without_control_characters(raw_label))
  case parse_label(raw_label) {
    Error(reason) ->
      account_pages.account_action_page(
        language,
        theme,
        row,
        dashboard.EditLabel,
        echoed_label,
        Some(i18n.Translated(reason)),
      )
      |> wisp.html_response(400)
    Ok(label) ->
      apply_account_change(
        language,
        theme,
        context.update_label(row.signer, label),
        account_pages.account_action_page(
          language,
          theme,
          row,
          dashboard.EditLabel,
          echoed_label,
          _,
        ),
      )
  }
}

/// 変更の結果。成功ならダッシュボードへ 303 で戻し（再読み込みで変更を再送させない）、
/// 失敗なら `change_failure_response` に渡す。`render` は失敗を再描画するページ
/// （`account_action_page` か `unreadable_delete_page` の部分適用）。
fn apply_account_change(
  language: Language,
  theme: view.Theme,
  outcome: Result(Nil, ChangeFailure),
  render: fn(Option(i18n.Reason)) -> String,
) -> Response {
  case outcome {
    Ok(Nil) -> wisp.redirect(to: "/")
    Error(failure) ->
      change_failure_response(language, theme, failure, fn(reason) {
        render(Some(reason))
      })
  }
}

/// 変更の失敗の応答。反映されなかったなら `render` で操作の画面を 409 で返し、
/// 受け付けられなかったなら 503、反映されたか分からないなら 202 の通知ページにする。
/// 202 にするのは、反映されたかもしれない変更を「拒否された」と見せると、利用者が
/// 同じ変更をやり直し、secret の作り直しならもう一度作り直してしまうからである。
/// 反映されたか分からない原因は訳す。ほかの理由は英語の文字列で届くので、
/// 訳さずに出す。
fn change_failure_response(
  language: Language,
  theme: view.Theme,
  failure: ChangeFailure,
  render: fn(i18n.Reason) -> String,
) -> Response {
  case failure {
    bunker.NotApplied(reason) ->
      render(i18n.Untranslated(reason)) |> wisp.html_response(409)
    bunker.NotReady(reason) ->
      unavailable_notice(language, theme, i18n.AccountsNotAvailable, reason)
    bunker.MaybeApplied(cause) ->
      not_confirmed_notice(
        language,
        theme,
        i18n.Translated(not_confirmed_message(cause)),
        202,
      )
  }
}

/// 生成した鍵の登録のバンカーの失敗を、確認ページの理由と状態コードに写す。状態コードは
/// `change_failure_response` と同じ対応にする。
fn generated_key_problem(
  failure: ChangeFailure,
) -> #(account_pages.GeneratedKeyProblem, Int) {
  case failure {
    bunker.NotApplied(reason) -> #(account_pages.NotApplied(reason), 409)
    bunker.NotReady(reason) -> #(account_pages.NotAccepted(reason), 503)
    bunker.MaybeApplied(cause) -> #(
      account_pages.NotConfirmed(not_confirmed_message(cause)),
      202,
    )
  }
}

/// 確かめられなかった原因を通知ページの本文の文言に写す。
fn not_confirmed_message(cause: bunker.NotConfirmed) -> i18n.Message {
  case cause {
    bunker.BunkerDidNotRespond -> i18n.BunkerDidNotRespond
    bunker.StoreDidNotConfirm -> i18n.StoreDidNotConfirm
  }
}

/// 変更が反映されたか確かめられなかったときの通知ページ。状態コードは呼び出し側が
/// 決める（アカウントの変更、リレーの変更、クライアントの接続は 202、承認・拒否・取り消しと
/// 再有効化は 503）。本文は呼び出し側が訳すかを決める。囲みの下に、ダッシュボードで確かめる
/// よう促す一文を添える。
fn not_confirmed_notice(
  language: Language,
  theme: view.Theme,
  reason: i18n.Reason,
  status: Int,
) -> Response {
  dashboard.notice_page(
    language,
    theme,
    return_to_dashboard,
    i18n.ChangeNotConfirmed,
    reason,
    view.Warning,
    [view.hint(i18n.text(language, i18n.CheckDashboardBeforeRetrying))],
  )
  |> wisp.html_response(status)
}

/// 受け付けられないときの 503 の通知ページ。一覧を得られない、変更や照会を受け
/// 付けられないときに共通で使う。見出しは呼び出し側が決める。
fn unavailable_notice(
  language: Language,
  theme: view.Theme,
  title: i18n.Message,
  reason: String,
) -> Response {
  dashboard.notice_page(
    language,
    theme,
    return_to_dashboard,
    title,
    i18n.Untranslated(reason),
    view.Warning,
    [],
  )
  |> wisp.html_response(503)
}

/// 管理パスワードの再入力を照合し、一致したときだけ nsec を問い合わせて表示する。
/// ログに出すのは一覧の行の npub だけで、パスワードも nsec も出さない。
fn reveal_private_key(
  context: Context,
  request: Request,
  language: Language,
  theme: view.Theme,
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
      log.write(
        log.Warning,
        log_prefix,
        "rejected a private key reveal for "
          <> row.npub
          <> ": "
          <> incorrect_password,
      )
      account_pages.account_action_page(
        language,
        theme,
        row,
        dashboard.RevealPrivateKey,
        None,
        Some(i18n.Translated(i18n.IncorrectPassword)),
      )
      |> wisp.html_response(403)
    }
    True ->
      case context.nsec(row.signer) {
        Ok(nsec) -> {
          log.write(
            log.Notice,
            log_prefix,
            "revealed the private key of " <> row.npub,
          )
          account_pages.private_key_page(language, theme, row, nsec)
          |> wisp.html_response(200)
        }
        Error(reason) ->
          unavailable_notice(language, theme, i18n.AccountsNotAvailable, reason)
      }
  }
}

/// Basic 認証に失敗した理由。ログ行の言い回しを決める。
pub type AuthenticationFailure {
  /// `Authorization` ヘッダーが無い。ブラウザーの最初のリクエストもこれになる。
  NoCredentials
  /// ヘッダーはあるが、Basic 認証の資格情報として読めない。
  MalformedCredentials
  /// 資格情報は読めたが、ユーザー名かパスワードが一致しない。
  WrongCredentials
}

/// Basic 認証を要求する。資格情報が無い、あるいは一致しないときは、失敗の理由を
/// 1 行ログに出してから 401 を返す。
fn require_password(
  context: Context,
  request: Request,
  next: fn() -> Response,
) -> Response {
  case authenticate(context.password, request) {
    Ok(Nil) -> next()
    Error(failure) -> {
      log.write(log.Warning, log_prefix, unauthorized_line(failure))
      unauthorized()
    }
  }
}

/// リクエストの Basic 認証の資格情報を照合する。認証スキームの照合は RFC 7235 に従い
/// 大文字小文字を区別しない。ユーザー名は公開された固定値なので定数時間では比べず、
/// 一致したときだけパスワードを定数時間で比べる。
pub fn authenticate(
  password: String,
  request: Request,
) -> Result(Nil, AuthenticationFailure) {
  use header <- result.try(
    list.key_find(request.headers, "authorization")
    |> result.replace_error(NoCredentials),
  )
  use #(user, offered) <- result.try(
    basic_credentials(header) |> result.replace_error(MalformedCredentials),
  )
  case user == username && is_admin_password(offered, password) {
    True -> Ok(Nil)
    False -> Error(WrongCredentials)
  }
}

/// `Authorization` ヘッダーの値を、Basic 認証のユーザー名とパスワードに分ける。RFC 7617
/// に従い最初の `:` で分ける（ユーザー名は `:` を含めない）ので、パスワードは `:` を含んでよい。
fn basic_credentials(header: String) -> Result(#(String, String), Nil) {
  use #(scheme, encoded) <- result.try(string.split_once(header, " "))
  use <- bool.guard(string.lowercase(scheme) != "basic", Error(Nil))
  use decoded <- result.try(bit_array.base64_decode(encoded))
  use credentials <- result.try(bit_array.to_string(decoded))
  string.split_once(credentials, ":")
}

/// 入力されたパスワードが管理パスワードと一致するか。一致した文字数が応答時間に
/// 現れないよう定数時間で比べる。Basic 認証と秘密鍵の再表示の両方が使う。
fn is_admin_password(offered: String, password: String) -> Bool {
  crypto.secure_compare(
    bit_array.from_string(offered),
    bit_array.from_string(password),
  )
}

/// Basic 認証に失敗した要求（401）1 件のログ行の本文（接頭辞を除く）。理由だけを
/// 含め、資格情報、パス、メソッド、送信元は含めない。パスは承認ページのトークンを
/// 含みうるからである。
pub fn unauthorized_line(failure: AuthenticationFailure) -> String {
  case failure {
    NoCredentials -> "rejected a request without credentials"
    MalformedCredentials -> "rejected a request with malformed credentials"
    WrongCredentials -> "rejected a request with wrong credentials"
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
