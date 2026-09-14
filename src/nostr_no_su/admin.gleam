//// 管理 UI の HTTP サーバー（wisp / mist）。
////
//// ハンドラーは状態を自分で取りに行かず、`Context` に注入された関数から受け取る。
//// これによりルートはアクターを起動せずにテストでき、描画は「スナップショット →
//// HTML」の純粋関数（`admin/dashboard` と `admin/account_pages`）に閉じ込められる。
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
import nostr_no_su/admin/dashboard
import nostr_no_su/admin/i18n.{type Language}
import nostr_no_su/admin/view
import nostr_no_su/bunker.{type ChangeFailure, type RevokeFailure}
import nostr_no_su/bunker/account.{type Account}
import nostr_no_su/bunker/engine.{type Session}
import nostr_no_su/log
import nostr_no_su/nostr/nip19
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

/// ハンドラーが必要とするものすべて。パスワード以外の状態（アカウント、リレー、
/// プラグイン、セッション、承認待ち）はアクターに問い合わせる関数で受け取り、
/// 表示のたびに現在の値を読む。
pub type Context {
  Context(
    password: String,
    /// アカウントの一覧。読み込み中、応答なしのときは表示する理由を返す。
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
    /// 無効になったプラグインを名前で再有効化する。
    reenable_plugin: fn(String) -> Result(Nil, ReenableFailure),
    sessions: fn() -> List(Session),
    /// セッション（署名者, クライアント）を 1 件取り消す。
    revoke: fn(String, String) -> Result(Nil, RevokeFailure),
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
    ["approve", token] ->
      approve_connection(context, request, language, theme, token)
    ["deny", token] -> deny_connection(context, request, language, theme, token)
    segments if segments == dashboard.revoke_segments ->
      revoke_session(context, request, language, theme)
    segments if segments == dashboard.reenable_plugin_segments ->
      reenable_plugin(context, request, language, theme)
    segments if segments == dashboard.new_account_segments ->
      show_new_account(request, language, theme)
    segments if segments == dashboard.generate_account_segments ->
      generate_account(request, language, theme)
    segments if segments == dashboard.import_account_segments ->
      import_account(context, request, language, theme)
    segments if segments == dashboard.register_generated_segments ->
      register_generated_account(context, request, language, theme)
    segments ->
      case dashboard.parse_account_action_path(segments) {
        Ok(#(signer, action)) ->
          account_action(context, request, language, theme, signer, action)
        Error(Nil) ->
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

/// ダッシュボード。表示に必要な状態をここで集め、描画は純粋関数へ渡す。
fn show_dashboard(
  context: Context,
  request: Request,
  language: Language,
  theme: view.Theme,
) -> Response {
  use <- require_method(request, http.Get, language, theme)
  dashboard.Snapshot(
    accounts: context.accounts(),
    pending: context.pending(),
    relays: context.relays(),
    sessions: context.sessions(),
    plugins: context.plugins(),
  )
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
      wisp.html_response(dashboard.approval_page(language, theme, entry), 200)
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

/// 承認ページの表示と承認・拒否の前に、承認待ちの一覧からトークンの行を引く。無ければ
/// 表示や承認・拒否を呼ばずに 404 の通知ページを返す。不明、失効、処理済みのほか、
/// バンカーが応答せず一覧が空のときも一致しない。ログに出す署名者とクライアントは、
/// トークンではなくこの行の値から取る。
fn with_pending(
  context: Context,
  language: Language,
  theme: view.Theme,
  token: String,
  next: fn(dashboard.PendingRow) -> Response,
) -> Response {
  case list.find(context.pending(), fn(entry) { entry.token == token }) {
    Ok(entry) -> next(entry)
    Error(Nil) ->
      not_found_notice(
        language,
        theme,
        i18n.Untranslated(engine.approval_request_not_found),
      )
  }
}

/// 接続とセッションへの操作の種類。ログ行の言い回しを決める。
pub type SessionChange {
  ConnectionApproved
  ConnectionDenied
  SessionRevoked
}

/// プラグインの再有効化が失敗する 2 通り。
pub type ReenableFailure {
  /// 名前に一致するプラグインが無い。
  PluginNotFound(reason: String)
  /// ランナーが居ないか、期限内に応答しなかった。打ち切った後にランナーが
  /// 処理して反映することがある。
  PluginNotAnswered(reason: String)
}

/// 承認・拒否・取り消し 1 件のログ行の本文（接頭辞を除く）。値は署名者とクライアントの
/// 公開鍵だけで、承認ページのトークンを含めない。
pub fn session_change_line(
  change: SessionChange,
  signer: String,
  client: String,
) -> String {
  let done = case change {
    ConnectionApproved -> "approved the connection of client "
    ConnectionDenied -> "denied the connection of client "
    SessionRevoked -> "revoked the session of client "
  }
  done <> client <> " to signer " <> signer
}

/// 承認・拒否の結果。クライアントは応答イベントを待っているので、ここでは人間に
/// 終わったことだけを伝える。処理できたときは `log_line` を 1 行ログに出す。処理
/// できなかった要求（一覧を引いた後に失効・処理済みになった、あるいはバンカーが
/// 動いていない）は、区別せず理由を添えた 404 にする。承認と拒否はどちらも 200
/// なので、処理できたときの見出し（`done`）、文（`message`）、通知の色（`tone`）は
/// 呼び出し側が渡す。
fn decision_response(
  language: Language,
  theme: view.Theme,
  outcome: Result(Nil, String),
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
      )
      |> wisp.html_response(200)
    }
    Error(reason) ->
      not_found_notice(language, theme, i18n.Untranslated(reason))
  }
}

/// セッションを 1 件取り消してダッシュボードへ戻す。再読み込みで取り消しが
/// 再送されないよう 303 でリダイレクトする。取り消せなかったときは
/// `revoke_failure_response` に渡す。
fn revoke_session(
  context: Context,
  request: Request,
  language: Language,
  theme: view.Theme,
) -> Response {
  use <- require_method(request, http.Post, language, theme)
  use form <- wisp.require_form(request)
  case
    list.key_find(form.values, "signer"),
    list.key_find(form.values, "client")
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
        Error(failure) -> revoke_failure_response(language, theme, failure)
      }
    _, _ -> bad_request(language, theme)
  }
}

/// 取り消しの失敗の応答。承認済みでない組は承認・拒否の失敗と同じ 404、バンカーが
/// 応答しなければ 503 の通知ページにする。応答が無いときはアカウントの変更と違って
/// 202 にしない。取り消しは再送しても害が無い（反映済みなら 404 になる）ので、
/// やり直してよい一時的な失敗として返す。
fn revoke_failure_response(
  language: Language,
  theme: view.Theme,
  failure: RevokeFailure,
) -> Response {
  case failure {
    bunker.SessionNotFound(reason) ->
      not_found_notice(language, theme, i18n.Untranslated(reason))
    bunker.NotAnswered ->
      not_confirmed_notice(
        language,
        theme,
        i18n.Translated(i18n.BunkerDidNotRespond),
        503,
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
  case list.key_find(form.values, "name") {
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

/// アカウントの登録画面。
fn show_new_account(
  request: Request,
  language: Language,
  theme: view.Theme,
) -> Response {
  use <- require_method(request, http.Get, language, theme)
  account_pages.new_account_page(language, theme, None)
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
  account.generate(crypto.strong_random_bytes)
  |> account.nsec
  |> account_pages.generated_key_page(language, theme, _, None)
  |> wisp.html_response(200)
}

/// nsec 入力によるアカウントの登録。完了ページで nsec を 1 回だけ表示する。
fn import_account(
  context: Context,
  request: Request,
  language: Language,
  theme: view.Theme,
) -> Response {
  let reject_label = fn(_account, reason) {
    account_pages.new_account_page(
      language,
      theme,
      Some(i18n.Translated(reason)),
    )
  }
  use account, label <- register(
    context,
    request,
    language,
    theme,
    reject_label,
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
/// ダッシュボードへ 303 で戻す。ラベルだけが規則に反するときは、生成した鍵を失わない
/// よう、送られた nsec の確認ページを理由付きで返す（この POST の応答の本文だけに出る）。
fn register_generated_account(
  context: Context,
  request: Request,
  language: Language,
  theme: view.Theme,
) -> Response {
  let reject_label = fn(generated, reason) {
    account_pages.generated_key_page(
      language,
      theme,
      account.nsec(generated),
      Some(reason),
    )
  }
  use _account, _label <- register(
    context,
    request,
    language,
    theme,
    reject_label,
  )
  wisp.redirect(to: "/")
}

/// 登録の 2 つのルートが共有する検査と失敗の経路。nsec が不正なら 400 で登録画面を
/// 返し、ラベルだけが不正なら 400 で `reject_label` が描画するページを返す。バンカーの
/// 失敗は `change_failure_response` に渡す。登録できたときだけ `on_success` を呼ぶので、
/// 反映されたか分からないときに nsec を描画する経路は無い。
fn register(
  context: Context,
  request: Request,
  language: Language,
  theme: view.Theme,
  reject_label: fn(Account, i18n.Message) -> String,
  on_success: fn(Account, String) -> Response,
) -> Response {
  use <- require_method(request, http.Post, language, theme)
  use form <- wisp.require_form(request)
  case parse_private_key(form) {
    Error(reason) ->
      account_pages.new_account_page(
        language,
        theme,
        Some(i18n.Translated(reason)),
      )
      |> wisp.html_response(400)
    Ok(account) ->
      case parse_label(form_value(form, dashboard.label_field)) {
        Error(reason) ->
          reject_label(account, reason) |> wisp.html_response(400)
        Ok(label) ->
          case context.add_account(account, label) {
            Ok(Nil) -> on_success(account, label)
            Error(failure) ->
              change_failure_response(language, theme, failure, fn(reason) {
                account_pages.new_account_page(language, theme, Some(reason))
              })
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

/// Unicode の Cc（C0、DEL、C1）の符号位置かどうか。`string.trim` は U+0085 や
/// 末尾の `\n` を黙って消すので、`parse_label` は trim の前の値をこれで検査する。
fn is_control_character(code_point: UtfCodepoint) -> Bool {
  let code = string.utf_codepoint_to_int(code_point)
  code <= 0x1f || { code >= 0x7f && code <= 0x9f }
}

/// アカウント 1 件への操作。一覧から行を引いてから、GET は操作のページを、POST は
/// 操作を実行する。
fn account_action(
  context: Context,
  request: Request,
  language: Language,
  theme: view.Theme,
  signer: String,
  action: dashboard.AccountAction,
) -> Response {
  use row <- with_account(context, language, theme, signer)
  case request.method, action {
    http.Get, _ ->
      account_pages.account_action_page(language, theme, row, action, None)
      |> wisp.html_response(200)
    http.Post, dashboard.EditLabel ->
      update_label(context, request, language, theme, row)
    http.Post, dashboard.RotateSecret ->
      apply_account_change(
        language,
        theme,
        row,
        action,
        context.rotate_secret(row.signer),
      )
    http.Post, dashboard.DeleteAccount ->
      apply_account_change(
        language,
        theme,
        row,
        action,
        context.remove_account(row.signer),
      )
    http.Post, dashboard.RevealPrivateKey ->
      reveal_private_key(context, request, language, theme, row)
    _, _ -> method_not_allowed(language, theme, [http.Get, http.Post])
  }
}

/// 一覧から署名者の行を引く。一覧を得られなければ 503、無ければ 404。どちらも
/// `signer` を応答に含めない。以降のログとバンカーへの呼び出しには、呼び出し側が
/// 渡した文字列ではなく、一覧の行の値を使う。
fn with_account(
  context: Context,
  language: Language,
  theme: view.Theme,
  signer: String,
  next: fn(dashboard.AccountRow) -> Response,
) -> Response {
  case context.accounts() {
    Error(reason) -> accounts_unavailable(language, theme, reason)
    Ok(rows) ->
      case list.find(rows, fn(row) { row.signer == signer }) {
        Ok(row) -> next(row)
        Error(Nil) ->
          not_found_notice(
            language,
            theme,
            i18n.Translated(i18n.AccountNotFound),
          )
      }
  }
}

/// ラベルの差し替え。ラベルが規則に反すれば 400 で編集のページを返す。
fn update_label(
  context: Context,
  request: Request,
  language: Language,
  theme: view.Theme,
  row: dashboard.AccountRow,
) -> Response {
  use form <- wisp.require_form(request)
  case parse_label(form_value(form, dashboard.label_field)) {
    Error(reason) ->
      account_pages.account_action_page(
        language,
        theme,
        row,
        dashboard.EditLabel,
        Some(i18n.Translated(reason)),
      )
      |> wisp.html_response(400)
    Ok(label) ->
      apply_account_change(
        language,
        theme,
        row,
        dashboard.EditLabel,
        context.update_label(row.signer, label),
      )
  }
}

/// 変更の結果。成功ならダッシュボードへ 303 で戻し（再読み込みで変更を再送させない）、
/// 失敗なら `change_failure_response` に渡す。
fn apply_account_change(
  language: Language,
  theme: view.Theme,
  row: dashboard.AccountRow,
  action: dashboard.AccountAction,
  outcome: Result(Nil, ChangeFailure),
) -> Response {
  case outcome {
    Ok(Nil) -> wisp.redirect(to: "/")
    Error(failure) ->
      change_failure_response(language, theme, failure, fn(reason) {
        account_pages.account_action_page(
          language,
          theme,
          row,
          action,
          Some(reason),
        )
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
    bunker.NotReady(reason) -> accounts_unavailable(language, theme, reason)
    bunker.MaybeApplied(cause) ->
      not_confirmed_notice(
        language,
        theme,
        i18n.Translated(not_confirmed_message(cause)),
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
/// 決める（アカウントの変更は 202、セッションの取り消しは 503）。本文は呼び出し側が
/// 訳すかを決める。
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
  )
  |> wisp.html_response(status)
}

/// アカウントを扱えないときの 503 の通知ページ。一覧を得られない、変更を受け付け
/// られない、nsec の問い合わせが失敗した場合に共通で使う。
fn accounts_unavailable(
  language: Language,
  theme: view.Theme,
  reason: String,
) -> Response {
  dashboard.notice_page(
    language,
    theme,
    return_to_dashboard,
    i18n.AccountsNotAvailable,
    i18n.Untranslated(reason),
    view.Warning,
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
        Error(reason) -> accounts_unavailable(language, theme, reason)
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
