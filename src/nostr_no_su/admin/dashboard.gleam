//// 管理 UI のダッシュボード、承認ページ、通知ページの描画と、表示する状態の型、パスと
//// フォームの欄の名前の定義と、ダイアログに出すフォームの中身。描画は状態の
//// スナップショット（純粋なデータ）から HTML 文字列を組み立てるだけで、プロセスにも IO にも
//// 触れない。
////
//// 埋め込む値はすべてユーザー由来になりうる（リレー URL、クライアント pubkey、
//// アカウントのラベル、表示する理由）ため、テキストか属性値として lustre に渡し、
//// エスケープを文字列化に任せる（`admin/view` の規則に従う）。文言は `admin/i18n` から
//// 表示の言語で引き、文字列リテラルで書かない（同じく `admin/view` の規則）。
////
//// パスとフォームの欄の名前は、ルーティング（`admin`）とここのフォームが同じ定義を見るようここに置く。
//// ダッシュボードのダイアログに出すフォームの中身（リレーの `new_relay_form`、`relay_action_form`、
//// アカウントの `import_form`、`generate_form`、`account_action_form`、`unreadable_delete_form`、
//// `label_fieldset`、セッションの `permissions_form`、クライアントの接続の `connect_content`、
//// `connect_form`）もここに置く。`label_fieldset` を除くこれらのフォームは末尾の引数 `placement` で
//// 送信の置き場所を受け、ダイアログは `view.dialog` が渡す `view.InDialog` を渡す。
//// ページのモジュールがここを
//// import するので、ページのモジュールに置くと import が循環する。
//// ページ枠が使う定義
//// （スタイルシートとテーマと言語の切り替えのパスセグメント、切り替えの欄の名前）と、
//// パスセグメントからパスを組み立てる `segments_path` は `admin/view` に置く。

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/svg
import nostr_no_su/admin/fingerprint
import nostr_no_su/admin/i18n.{type Language}
import nostr_no_su/admin/permission_view
import nostr_no_su/admin/qr
import nostr_no_su/admin/view
import nostr_no_su/bunker/engine
import nostr_no_su/bunker/vault
import nostr_no_su/plugin
import nostr_no_su/plugin_loader
import nostr_no_su/plugin_runner
import nostr_no_su/relay_connection.{type Status, Connected, Disconnected}
import nostr_no_su/relay_list.{type Roles, Roles}
import nostr_no_su/relay_store.{type Relay}

/// `relays` の 1 行の表示内容。用途ごとに、使っていなければ `Unused`、状態を得られたら
/// `Reported`、締め切りまでに接続が答えなければ `Unanswered` を持つ。
pub type RelayRow {
  RelayRow(id: Int, url: String, monitor: RoleState, bunker: RoleState)
}

/// リレー 1 件の、用途 1 つぶんの状態。
pub type RoleState {
  /// この用途には使っていない。
  Unused
  /// 接続の状態を得られた。
  Reported(Status)
  /// 締め切りまでに接続が答えなかった。
  Unanswered
}

/// アカウント 1 件の表示内容。`uri` と `uri_camera_text` は secret を含むため、認証済み
/// ページ以外に出してはならない。`auth_uri` は secret を持たない URI で、これで接続した
/// クライアントは管理 UI での承認を経てから署名を委任できる。`uri_camera_text` と
/// `auth_uri_camera_text` は、それぞれの URI の端末のカメラ用のコピー用の文字列
/// （`connection_uri.camera_copy_text`）。`npub` は画面でアカウントを識別するための表記。
/// `picture` は kind 0 の `picture` の検査済みの `https:` の URL で、無ければ `None`。
pub type AccountRow {
  AccountRow(
    signer: String,
    npub: String,
    label: String,
    uri: String,
    auth_uri: String,
    uri_camera_text: String,
    auth_uri_camera_text: String,
    picture: Option(String),
  )
}

/// 読み込みで飛ばされた行 1 件の表示内容。`npub` は `pubkey` から導けたときだけ
/// 入り、`MalformedPubkey` の行では空文字列になる。この行は識別を描かず、
/// `reason` の 1 文だけを出す。
pub type SkippedRow {
  SkippedRow(
    pubkey: String,
    npub: String,
    label: String,
    reason: vault.RowError,
  )
}

/// プラグイン 1 つの表示内容。`status` が `None` なのは、ランナーが再起動中か、
/// 遅いプラグインの実行中で問い合わせに応答しなかったか、共通の締め切りまでに
/// 答えなかったことを意味する。`pages` は読み込み時に検証済みの一覧で、空なら
/// このプラグインは管理 UI のページを供給しない。
pub type PluginRow {
  PluginRow(
    name: String,
    status: Option(plugin_runner.Status),
    pages: List(plugin.PluginPage),
  )
}

/// 承認待ちのカードと承認ページに出す署名者の表示。アカウント一覧と突き合わせられればラベルと
/// npub、そうでなければ 16 進。
pub type SignerName {
  /// アカウント一覧にある署名者。ラベルと省略した npub で出す。
  KnownSigner(label: String, npub: String)
  /// 一覧に無い署名者、または一覧を得られないとき。省略した 16 進で出す。
  UnknownSigner(hex: String)
}

/// アカウント一覧と突き合わせて、署名者の表示を決める。
pub fn signer_name(
  accounts: Result(List(AccountRow), i18n.Reason),
  signer: String,
) -> SignerName {
  case accounts {
    Ok(rows) ->
      case list.find(rows, fn(row) { row.signer == signer }) {
        Ok(row) -> KnownSigner(label: row.label, npub: row.npub)
        Error(Nil) -> UnknownSigner(hex: signer)
      }
    Error(_) -> UnknownSigner(hex: signer)
  }
}

/// 承認待ちの接続要求 1 件の表示内容。`expires_in_seconds` は描画時点で失効まで
/// あと何秒か。`secret_mismatch` は提示された secret が一致しなかったか（偽なら
/// 提示が無い）。`perms` は `connect` で要求された権限（無ければ空文字列）。
pub type PendingRow {
  PendingRow(
    token: String,
    signer: String,
    client: String,
    expires_in_seconds: Int,
    secret_mismatch: Bool,
    perms: String,
  )
}

/// 承認済みセッション 1 件の表示内容。時刻は Unix 秒。`perms` は承認したときに要求
/// されていた権限（無ければ空文字列）で、`connect` し直しても変わらず、管理 UI の
/// 「権限を編集」でだけ変わる。
pub type SessionRow {
  SessionRow(
    signer: String,
    client: String,
    perms: String,
    created_at: Int,
    last_used_at: Int,
  )
}

/// ダッシュボードが表示する状態の一式。
pub type Snapshot {
  Snapshot(
    /// アカウントの一覧。得られないとき（読み込み中、応答なし、締め切り超過）は
    /// 表示する理由。
    accounts: Result(List(AccountRow), i18n.Reason),
    /// 直近の読み込みで飛ばされた行の一覧。得られないとき（読み込み中、応答なし、
    /// 締め切り超過）は枠ごと描かない。
    skipped: Result(List(SkippedRow), i18n.Reason),
    /// 承認待ちの一覧。得られないとき（読み込み中、応答なし、締め切り超過）は
    /// 表示する理由。
    pending: Result(List(PendingRow), i18n.Reason),
    /// リレーの一覧。得られないとき（`relay_list` の応答なし、DB の障害）は表示する
    /// 理由。この一覧自体は締め切りの外で得るが、行ごとの用途の状態は締め切りまでに
    /// 答えなければ `RoleState.Unanswered` になる。
    relays: Result(List(RelayRow), i18n.Reason),
    /// 承認済みセッションの一覧。得られないとき（読み込み中、応答なし、締め切り
    /// 超過）は表示する理由。
    sessions: Result(List(SessionRow), i18n.Reason),
    plugins: List(PluginRow),
    /// 起動時に読み込めなかったプラグインの一覧。0 件なら枠ごと描かない。
    not_loaded_plugins: List(plugin_loader.NotLoaded),
    /// 描画時点の Unix 秒。セッションの最終利用を相対で出すために使う。
    now: Int,
  )
}

/// 「はじめに」の帯の段のうち、済んだかどうかが変わる 2 つ。
pub type GettingStarted {
  GettingStarted(
    /// バンカーに使うリレーが 1 件以上ある。
    bunker_relay: Bool,
    /// 読み込めたアカウントが 1 件以上ある。
    account: Bool,
  )
}

/// POST の応答で、ダッシュボードに開いた状態で描くダイアログ。
pub type OpenDialog {
  /// リレーの追加。欄に戻す URL と用途と、先頭に出す理由を持つ。
  NewRelayOpen(url: String, roles: Roles, error: i18n.Reason)
  /// リレー `id` への操作。`roles` は用途の編集の欄に戻す用途で、削除では `None`。
  RelayActionOpen(
    id: Int,
    action: RelayAction,
    roles: Option(Roles),
    error: i18n.Reason,
  )
  /// アカウントの追加（登録のタブ）。`label` は欄に戻すラベル、`error` は先頭に出す理由。
  AddAccountOpen(label: String, error: i18n.Reason)
  /// 生成した鍵。`label` は欄に戻すラベル、`problem` は登録に失敗して開き直す理由。
  GeneratedKeyOpen(
    npub: String,
    nsec: String,
    label: String,
    problem: Option(GeneratedKeyProblem),
  )
  /// アカウント `signer` への操作。`label` はラベルの編集の欄に戻す値で、ほかの操作では `None`。
  AccountActionOpen(
    signer: String,
    action: AccountAction,
    label: Option(String),
    error: i18n.Reason,
  )
  /// 管理パスワードを照合した後の、`row` の秘密鍵 `nsec`。
  PrivateKeyOpen(row: AccountRow, nsec: String)
  /// 読み込めなかった行 `pubkey` の削除。
  UnreadableDeleteOpen(pubkey: String, error: i18n.Reason)
  /// クライアントの接続のダイアログ。`uri` と `signer` は送られた値で欄に戻し、`error` は
  /// 先頭に出す理由（一覧を得られないときは `None` で、理由はダイアログの中の囲みに出る）。
  ConnectOpen(uri: String, signer: String, error: Option(i18n.Reason))
  /// 接続の確認のダイアログ。`review` は解釈した接続の内容で、`error` は接続の段で失敗した
  /// ときに先頭に出す理由。このダイアログは開くときだけ描く。
  ConnectReviewOpen(review: ConnectReview, error: Option(i18n.Reason))
  /// （`signer`, `client`）の行の権限の編集のダイアログ。`form` は送られた欄の状態で、
  /// `error` は先頭に出す理由。
  PermissionsOpen(
    signer: String,
    client: String,
    form: PermissionsForm,
    error: i18n.Reason,
  )
}

/// 確認のダイアログに出す接続の内容。`uri` と `signer` は 1 段目で送られた値で、ダイアログの
/// 隠し欄で送り直す。`client_name` は表示のために整えた名前（無ければ `None`）。`relays` は
/// URI に現れた順。
pub type ConnectReview {
  ConnectReview(
    uri: String,
    signer: String,
    client: String,
    client_name: Option(String),
    perms: String,
    relays: List(String),
  )
}

/// 生成した鍵の登録に失敗して生成した鍵のダイアログを開き直す理由。
pub type GeneratedKeyProblem {
  /// ラベルが規則に反した（400）。
  InvalidLabel(i18n.Message)
  /// バンカーが登録を反映しなかった（409）。画面に出す理由を持つ（登録済みは訳した
  /// 文言、ストアの失敗は英語のまま届いた理由）。
  NotApplied(i18n.Reason)
  /// バンカーが今は登録を受け付けられない（503）。英語のまま届いた理由を持つ。
  NotAccepted(String)
  /// 登録が反映されたか分からない（202）。確かめられなかった原因の文言を持つ。
  NotConfirmed(i18n.Message)
}

/// 「はじめに」の帯の段 1 つの見せ方。
type SetupStep {
  /// 済んだ段。済みの印を付け、操作を出さない。
  StepDone
  /// 今できる段。追加のダイアログを開くボタンを出す。
  StepOpen(dialog: String, action: i18n.Message)
  /// 前の段が済むまで開けない段。点線の枠で出し、操作を出さない。
  StepLocked
}

/// アカウント 1 件に対する操作。
pub type AccountAction {
  EditLabel
  RotateSecret
  DeleteAccount
  RevealPrivateKey
}

/// 操作の一覧。セグメントとの対応をここから引く。
const account_actions = [
  EditLabel,
  RevealPrivateKey,
  RotateSecret,
  DeleteAccount,
]

/// アカウントの行の畳みにダイアログで並べる操作。この順に左から並べ、削除だけ右端に離して置く。
const detail_actions = [EditLabel, RevealPrivateKey, RotateSecret]

/// リレー 1 件に対する操作。
pub type RelayAction {
  EditRelayRoles
  DeleteRelay
}

/// 操作の一覧。ダッシュボードのボタンとダイアログはこの順に並べ、セグメントとの対応もここから引く。
const relay_actions = [EditRelayRoles, DeleteRelay]

/// アカウントのページのパスの先頭のセグメント。
const accounts_segment = "accounts"

/// リレーの POST 先のパスの先頭のセグメント。
const relays_segment = "relays"

/// プラグインのページのパスの先頭のセグメント。
const plugins_segment = "plugins"

/// 承認ページのパスの先頭のセグメント。
pub const approve_segment = "approve"

/// 拒否のパスの先頭のセグメント。
pub const deny_segment = "deny"

/// アカウントの読み直しの POST 先のパスセグメント。
pub const reload_accounts_segments = [accounts_segment, "reload"]

/// リレーの追加の POST 先のパスセグメント。
pub const new_relay_segments = [relays_segment, "new"]

/// 鍵の生成の POST 先のパスセグメント。
pub const generate_account_segments = [accounts_segment, "generate"]

/// nsec による登録の POST 先のパスセグメント。
pub const import_account_segments = [accounts_segment, "import"]

/// 生成した鍵の登録の POST 先のパスセグメント。
pub const register_generated_segments = [accounts_segment, "register-generated"]

/// セッションのページの先頭のセグメント。
pub const sessions_segment = "sessions"

/// セッションの取り消しの操作の語。POST 先のパスの末尾と、取り消しのダイアログの `id` に使う。
const revoke_segment = "revoke"

/// セッション取り消しの POST 先のパスセグメント。
pub const revoke_segments = [sessions_segment, revoke_segment]

/// クライアントの接続の 1 段目の送信先のパスセグメント。
pub const connect_segments = [sessions_segment, "connect"]

/// クライアントの接続の確認のダイアログから、接続を送るパス。
pub const connect_confirm_segments = [sessions_segment, "connect", "confirm"]

/// プラグインの再有効化の POST 先のパスセグメント。
pub const reenable_plugin_segments = [plugins_segment, "reenable"]

/// 登録のフォームで nsec を送る欄の名前。
pub const nsec_field = "nsec"

/// ラベルを送る欄の名前。
pub const label_field = "label"

/// リレーの追加のフォームで URL を送る欄の名前。
pub const relay_url_field = "url"

/// リレーの追加と用途の編集のフォームで監視に使うかを送る欄の名前。
pub const monitor_field = "monitor"

/// リレーの追加と用途の編集のフォームでバンカーに使うかを送る欄の名前。
pub const bunker_field = "bunker"

/// クライアントの接続のフォームで `nostrconnect://` の URI を送る欄の名前。
pub const nostrconnect_uri_field = "uri"

/// 秘密鍵の再表示で管理パスワードを送る欄の名前。
pub const password_field = "password"

/// セッション取り消しとクライアントの接続のフォームで署名者を送る欄の名前。
pub const signer_field = "signer"

/// セッション取り消しのフォームでクライアントを送る欄の名前。
pub const client_field = "client"

/// 権限の編集のフォームで `sign_event` の可否を送る欄の名前。トークンそのもの。
pub const sign_event_field = "sign_event"

/// 権限の編集のフォームで `nip44_encrypt` の可否を送る欄の名前。トークンそのもの。
pub const nip44_encrypt_field = "nip44_encrypt"

/// 権限の編集のフォームで `nip44_decrypt` の可否を送る欄の名前。トークンそのもの。
pub const nip44_decrypt_field = "nip44_decrypt"

/// 権限の編集のフォームで許す kind の一覧を送る欄の名前。
pub const perms_kinds_field = "kinds"

/// 権限の編集のフォームでそのほかの宣言を送る隠し欄の名前。
pub const perms_other_field = "other"

/// プラグインの再有効化のフォームでプラグイン名を送る欄の名前。
pub const plugin_name_field = "name"

/// ラベルの符号位置の最大数。UTF-8 では 400 バイト以下になる。
pub const max_label_code_points = 100

/// `nostrconnect://` の接続で、URI のリレーが応答の発行先になるのを待つ上限（秒）。確認のダイアログの
/// 案内と `app.connect_nostrconnect` の待ちが同じ値を見る。
pub const nostrconnect_wait_seconds = 15

/// 承認待ちがあるダッシュボードと承認ページを自動で読み込み直す間隔（秒）。
const refresh_seconds = 30

/// 承認待ちの節のアンカー。概要の帯の項目の `href="#…"` と節の `id` が同じ値を見る。
const pending_anchor = "pending"

/// 「はじめに」の帯のアンカー。
const getting_started_anchor = "getting-started"

/// アカウントの節のアンカー。
const accounts_anchor = "accounts"

/// セッションの節のアンカー。
const sessions_anchor = "sessions"

/// リレーの節のアンカー。
const relays_anchor = "relays"

/// プラグインの節のアンカー。
const plugins_anchor = "plugins"

/// ダッシュボードを自動で読み込み直すかどうか。承認待ちを 1 件以上得たときだけ更新し、
/// 空のときと一覧を得られないときは、コピー中の選択を壊さないために更新しない。
fn dashboard_refresh(
  pending: Result(List(PendingRow), i18n.Reason),
) -> view.Refresh {
  case pending {
    Ok([_, ..]) -> view.RefreshEverySeconds(refresh_seconds)
    _ -> view.NoRefresh
  }
}

/// スナップショットをダッシュボードのページに描画する。先頭に概要の帯を置き、承認待ち、アカウント、セッションの
/// 3 つの一覧が同じ英語の理由で得られないときは、その直下にエラーの色の囲みで理由を 1 回だけ出す。続けて
/// 承認待ちが 1 件以上あるとき（または一覧を得られないとき）だけ全幅の帯を置き、アカウントか
/// バンカーに使うリレーが 0 件のときは「はじめに」の帯をその下に置く。その下は
/// 幅が 1120px を超える画面では、アカウント（末尾に読み込めなかったアカウントの枠）とセッションを左の列に、
/// リレーとプラグイン（末尾に読み込めなかったプラグインの枠）を右の列に、1.62 対 1 の幅で置く 2 列で、
/// 1120px 以下ではこの順に 1 列に並ぶ。
pub fn render(
  language: Language,
  theme: view.Theme,
  snapshot: Snapshot,
) -> String {
  render_page(language, theme, snapshot, None)
}

/// `render` と同じダッシュボードに `dialog` を開いた状態で描く。自動の読み込み直しはしない。
/// 追加、生成した鍵、秘密鍵、クライアントの接続とその確認のダイアログは一覧によらず描く。権限の編集の
/// ダイアログは `Error` にせず、そのセッションの行が一覧に無ければ開いたダイアログの無いダッシュボードを描く。
/// ほかの行の操作のダイアログは、その行の一覧（リレー、アカウント、読み込めなかった行）を得られなければその
/// 理由を、操作する行が一覧に無ければ `RelayNotFound` か `AccountNotFound` を `Error` で返す。
pub fn render_open(
  language: Language,
  theme: view.Theme,
  snapshot: Snapshot,
  dialog: OpenDialog,
) -> Result(String, i18n.Reason) {
  case dialog {
    NewRelayOpen(..)
    | AddAccountOpen(..)
    | GeneratedKeyOpen(..)
    | PrivateKeyOpen(..)
    | ConnectOpen(..)
    | ConnectReviewOpen(..)
    | PermissionsOpen(..) -> Ok(Nil)
    RelayActionOpen(id:, ..) ->
      listed_row(snapshot.relays, fn(row) { row.id == id }, i18n.RelayNotFound)
    AccountActionOpen(signer:, ..) ->
      listed_row(
        snapshot.accounts,
        fn(row) { row.signer == signer },
        i18n.AccountNotFound,
      )
    UnreadableDeleteOpen(pubkey:, ..) ->
      listed_row(
        snapshot.skipped,
        fn(row) { row.pubkey == pubkey },
        i18n.AccountNotFound,
      )
  }
  |> result.map(fn(_) { render_page(language, theme, snapshot, Some(dialog)) })
}

/// 開く行が一覧にあるか。一覧を得られなければその理由を、無ければ `missing` を訳す理由で返す。
fn listed_row(
  rows: Result(List(a), i18n.Reason),
  matches: fn(a) -> Bool,
  missing: i18n.Message,
) -> Result(Nil, i18n.Reason) {
  use rows <- result.try(rows)
  case list.any(rows, matches) {
    True -> Ok(Nil)
    False -> Error(i18n.Translated(missing))
  }
}

/// `render` と `render_open` の本体。
fn render_page(
  language: Language,
  theme: view.Theme,
  snapshot: Snapshot,
  dialog: Option(OpenDialog),
) -> String {
  let shared = shared_failure(snapshot)
  let refresh = case dialog {
    None -> dashboard_refresh(snapshot.pending)
    Some(_) -> view.NoRefresh
  }
  view.page(
    language,
    theme,
    i18n.Dashboard,
    view.Wide,
    view.SwitchReturningTo("/"),
    refresh,
    [
      overview_rail(language, snapshot),
      shared_failure_alert(language, shared),
      pending_section(
        language,
        snapshot.accounts,
        snapshot.now,
        shared,
        snapshot.pending,
        refresh,
      ),
      getting_started_band(language, snapshot.accounts, snapshot.relays),
      html.div(
        [
          attribute.class(
            "grid items-start gap-6 min-[1121px]:grid-cols-[minmax(0,1.62fr)_minmax(0,1fr)]",
          ),
        ],
        [
          html.div([attribute.class("flex min-w-0 flex-col gap-6")], [
            accounts_section(
              language,
              shared,
              snapshot.accounts,
              snapshot.skipped,
              snapshot.sessions,
              snapshot.relays,
              dialog,
            ),
            sessions_section(
              language,
              snapshot.accounts,
              snapshot.now,
              shared,
              snapshot.sessions,
              dialog,
            ),
          ]),
          html.div([attribute.class("flex min-w-0 flex-col gap-6")], [
            relays_section(language, snapshot.relays, dialog),
            plugins_section(
              language,
              snapshot.plugins,
              snapshot.not_loaded_plugins,
            ),
          ]),
        ],
      ),
      result_dialog(language, dialog),
    ],
  )
}

/// 概要の帯の 1 項目の値。
pub type OverviewValue {
  /// 件数。
  Count(Int)
  /// 動作中の件数と全件数（プラグイン）。
  CountOfTotal(count: Int, total: Int)
  /// 一覧を得られない。「—」を error の色で出す。
  NoValue
}

/// 概要の帯の補足の語 1 つ。`state` が `Some` の語は要対応で、状態のチップと同じ色と
/// アイコンで出す。`None` の語は補助の文字の色で出す。
pub type OverviewNote {
  OverviewNote(state: Option(view.Chip), text: i18n.Message)
}

/// 概要の帯の 1 項目の見せ方。`linked` が偽なら節へのリンクにしない（飛び先の節が出ない）。
/// `highlighted` が真なら項目を `primary` で塗る。
pub type Overview {
  Overview(
    value: OverviewValue,
    notes: List(OverviewNote),
    linked: Bool,
    highlighted: Bool,
  )
}

/// 概要の帯の 5 項目。
pub type OverviewRail {
  OverviewRail(
    pending: Overview,
    accounts: Overview,
    sessions: Overview,
    relays: Overview,
    plugins: Overview,
  )
}

/// スナップショットから概要の帯の 5 項目の見せ方を決める。
pub fn overview(snapshot: Snapshot) -> OverviewRail {
  OverviewRail(
    pending: pending_overview(snapshot.pending),
    accounts: accounts_overview(snapshot.accounts, snapshot.skipped),
    sessions: sessions_overview(snapshot.sessions),
    relays: relays_overview(snapshot.relays),
    plugins: plugins_overview(snapshot.plugins, snapshot.not_loaded_plugins),
  )
}

/// 一覧を得られない項目。値は「—」、補足は error の色の「取得できません」。
const not_available = Overview(
  value: NoValue,
  notes: [
    OverviewNote(Some(view.ToneChip(view.Failure)), i18n.OverviewNotAvailable),
  ],
  linked: True,
  highlighted: False,
)

/// 色を付けない補足の語。
fn plain_note(text: i18n.Message) -> OverviewNote {
  OverviewNote(None, text)
}

/// 件数が 1 以上のときだけ、要対応の補足の語を 1 つ返す。
fn attention_notes(
  count: Int,
  chip: view.Chip,
  text: fn(Int) -> i18n.Message,
) -> List(OverviewNote) {
  case count {
    0 -> []
    _ -> [OverviewNote(Some(chip), text(count))]
  }
}

/// 承認待ちの項目。1 件以上あれば `primary` で塗り、補足に「承認を待っています」と最短の失効を
/// 出す。0 件なら失効までの分数を出し、節が出ないのでリンクにしない。
fn pending_overview(
  pending: Result(List(PendingRow), i18n.Reason),
) -> Overview {
  case pending {
    Error(_) -> not_available
    Ok([]) ->
      Overview(
        value: Count(0),
        notes: [
          plain_note(
            i18n.PendingExpireAfterMinutes(engine.pending_ttl_minutes()),
          ),
        ],
        linked: False,
        highlighted: False,
      )
    Ok([first, ..] as rows) -> {
      let soonest =
        list.fold(rows, first.expires_in_seconds, fn(soonest, row) {
          int.min(soonest, row.expires_in_seconds)
        })
      Overview(
        value: Count(list.length(rows)),
        notes: [
          plain_note(i18n.AwaitingDecision),
          plain_note(i18n.SoonestExpiry(view.countdown(soonest))),
        ],
        linked: True,
        highlighted: True,
      )
    }
  }
}

/// アカウントの項目。読み込めなかった行があればその件数を error の色で出す。
fn accounts_overview(
  accounts: Result(List(AccountRow), i18n.Reason),
  skipped: Result(List(SkippedRow), i18n.Reason),
) -> Overview {
  case accounts {
    Error(_) -> not_available
    Ok(rows) ->
      Overview(
        value: Count(list.length(rows)),
        notes: case skipped {
          Error(_) -> not_available.notes
          Ok([]) -> [plain_note(i18n.AllAccountsLoaded)]
          Ok(skipped) ->
            attention_notes(
              list.length(skipped),
              view.LoadFailedChip,
              i18n.UnreadableRowCount,
            )
        },
        linked: True,
        highlighted: False,
      )
  }
}

/// セッションの項目。承認済みのクライアントの件数を出す。
fn sessions_overview(
  sessions: Result(List(SessionRow), i18n.Reason),
) -> Overview {
  case sessions {
    Error(_) -> not_available
    Ok(rows) ->
      Overview(
        value: Count(list.length(rows)),
        notes: [plain_note(i18n.ApprovedClients)],
        linked: True,
        highlighted: False,
      )
  }
}

/// リレーの項目。バンカー用の行が無いこと、未接続と応答なしの行数を要対応の語で出し、どれも
/// 無ければ「すべて接続中」を出す。未接続と応答なしは、用途が 2 つある行を二重に数えないよう
/// 行単位で数える。
fn relays_overview(relays: Result(List(RelayRow), i18n.Reason)) -> Overview {
  case relays {
    Error(_) -> not_available
    Ok(rows) -> {
      let no_bunker = case has_bunker_relay(rows) {
        True -> []
        False -> [
          OverviewNote(
            Some(view.ToneChip(view.Warning)),
            i18n.NoBunkerRelayShort,
          ),
        ]
      }
      let issues =
        list.flatten([
          no_bunker,
          attention_notes(
            list.count(rows, row_has_role_state(_, Reported(Disconnected))),
            view.DisconnectedChip,
            i18n.DisconnectedRelayCount,
          ),
          attention_notes(
            list.count(rows, row_has_role_state(_, Unanswered)),
            view.UnansweredChip,
            i18n.UnansweredRelayCount,
          ),
        ])
      Overview(
        value: Count(list.length(rows)),
        notes: case issues {
          [] -> [plain_note(i18n.AllRelaysConnected)]
          _ -> issues
        },
        linked: True,
        highlighted: False,
      )
    }
  }
}

/// プラグインの項目。値は動作中の件数と全件数で、読み込めなかった候補は分母に入れない
/// （ランナーが無いため）。補足は過負荷・無効・応答なし・読み込み失敗の件数を要対応の語で出し、
/// どれも無ければ、プラグインが 1 件も無いとき「有効なプラグインなし」、あれば値の読み方
/// （「動作中 / 全件数」）を出す。
fn plugins_overview(
  plugins: List(PluginRow),
  not_loaded: List(plugin_loader.NotLoaded),
) -> Overview {
  let count = fn(matches: fn(Option(plugin_runner.Status)) -> Bool) {
    list.count(plugins, fn(plugin) { matches(plugin.status) })
  }
  let running = count(fn(status) { status == Some(plugin_runner.Running) })
  let overloaded =
    count(fn(status) {
      case status {
        Some(plugin_runner.Overloaded(..)) -> True
        _ -> False
      }
    })
  let disabled =
    count(fn(status) {
      case status {
        Some(plugin_runner.Disabled(..)) -> True
        _ -> False
      }
    })
  let unavailable = count(fn(status) { status == None })
  let total = list.length(plugins)
  let issues =
    list.flatten([
      attention_notes(
        overloaded,
        view.OverloadedChip,
        i18n.OverloadedPluginCount,
      ),
      attention_notes(disabled, view.DisabledChip, i18n.DisabledPluginCount),
      attention_notes(
        unavailable,
        view.UnansweredChip,
        i18n.UnavailablePluginCount,
      ),
      attention_notes(
        list.length(not_loaded),
        view.LoadFailedChip,
        i18n.PluginsNotLoadedShort,
      ),
    ])
  Overview(
    value: CountOfTotal(running, total),
    notes: case issues, total {
      [], 0 -> [plain_note(i18n.NoPluginsEnabledShort)]
      [], _ -> [plain_note(i18n.RunningOfTotal)]
      _, _ -> issues
    },
    linked: True,
    highlighted: False,
  )
}

/// 概要の帯。5 項目を区切りの線で分けて 1 本の面に並べる。狭い画面では 2 列で、承認待ちの
/// 項目だけ全幅にする。
fn overview_rail(language: Language, snapshot: Snapshot) -> Element(msg) {
  let rail = overview(snapshot)
  html.nav(
    [
      attribute.attribute("aria-label", i18n.text(language, i18n.OverviewLabel)),
      attribute.class(
        "grid grid-cols-2 gap-px overflow-hidden rounded-box border border-base-300 bg-base-300 lg:grid-cols-5",
      ),
    ],
    [
      overview_cell(
        language,
        view.door_open_icon(),
        i18n.Pending,
        pending_anchor,
        True,
        rail.pending,
      ),
      overview_cell(
        language,
        view.users_icon(),
        i18n.Accounts,
        accounts_anchor,
        False,
        rail.accounts,
      ),
      overview_cell(
        language,
        view.clock_icon(),
        i18n.Sessions,
        sessions_anchor,
        False,
        rail.sessions,
      ),
      overview_cell(
        language,
        view.plug_icon(),
        i18n.Relays,
        relays_anchor,
        False,
        rail.relays,
      ),
      overview_cell(
        language,
        view.puzzle_icon(),
        i18n.Plugins,
        plugins_anchor,
        False,
        rail.plugins,
      ),
    ],
  )
}

/// 概要の帯の 1 項目。アイコンと見出し、値、補足の語を縦に並べ、`item.linked` なら同じページの
/// 節（`anchor`）へのリンクにする。`wide` が真なら狭い画面で全幅を占めさせる。塗った項目では
/// 見出しと補足を補助の文字の色にせず、塗りの上の文字の色を継がせる。リンクにしない項目には、
/// マウスを重ねたときの色を付けない。
fn overview_cell(
  language: Language,
  icon: Element(msg),
  title: i18n.Message,
  anchor: String,
  wide: Bool,
  item: Overview,
) -> Element(msg) {
  let class = case wide, item.highlighted, item.linked {
    True, True, _ ->
      "col-span-2 flex flex-col gap-0.5 bg-primary px-4 py-3.5 text-primary-content hover:bg-primary/90 lg:col-span-1"
    True, False, True ->
      "col-span-2 flex flex-col gap-0.5 bg-base-100 px-4 py-3.5 hover:bg-base-200 lg:col-span-1"
    True, False, False ->
      "col-span-2 flex flex-col gap-0.5 bg-base-100 px-4 py-3.5 lg:col-span-1"
    False, _, True ->
      "flex flex-col gap-0.5 bg-base-100 px-4 py-3.5 hover:bg-base-200"
    False, _, False -> "flex flex-col gap-0.5 bg-base-100 px-4 py-3.5"
  }
  let #(label_class, note_class) = case item.highlighted {
    True -> #(
      "flex items-center gap-1.5 text-sm font-semibold",
      "flex flex-wrap items-center gap-x-2.5 gap-y-0.5 text-xs",
    )
    False -> #(
      "flex items-center gap-1.5 text-sm font-semibold text-muted",
      "flex flex-wrap items-center gap-x-2.5 gap-y-0.5 text-xs text-muted",
    )
  }
  let content = [
    html.span([attribute.class(label_class)], [
      icon,
      html.text(i18n.text(language, title)),
    ]),
    overview_value(item.value),
    html.span(
      [attribute.class(note_class)],
      list.map(item.notes, overview_note(language, _)),
    ),
  ]
  case item.linked {
    True ->
      html.a([attribute.href("#" <> anchor), attribute.class(class)], content)
    False -> html.div([attribute.class(class)], content)
  }
}

/// 概要の帯の値。等幅の数字を 1 行で出し、全件数は小さく補助の文字の色で続ける。
fn overview_value(value: OverviewValue) -> Element(msg) {
  let class =
    "whitespace-nowrap font-mono text-3xl font-bold leading-tight tabular-nums"
  case value {
    Count(count) ->
      html.span([attribute.class(class)], [html.text(int.to_string(count))])
    CountOfTotal(count:, total:) ->
      html.span([attribute.class(class)], [
        html.text(int.to_string(count)),
        html.small([attribute.class("text-lg font-medium text-muted")], [
          html.text("/" <> int.to_string(total)),
        ]),
      ])
    NoValue ->
      html.span(
        [
          attribute.class(
            "whitespace-nowrap font-mono text-3xl font-bold leading-tight tabular-nums text-error",
          ),
        ],
        [html.text("—")],
      )
  }
}

/// 概要の帯の補足の語 1 つ。
fn overview_note(language: Language, note: OverviewNote) -> Element(msg) {
  let text = i18n.text(language, note.text)
  case note.state {
    Some(chip) -> view.status_note(chip, text)
    None -> html.span([], [html.text(text)])
  }
}

/// 行の監視かバンカーの用途のどちらかが `state` と等しいか。
fn row_has_role_state(row: RelayRow, state: RoleState) -> Bool {
  row.monitor == state || row.bunker == state
}

/// 一覧にバンカーに使う行があるか。
fn has_bunker_relay(rows: List(RelayRow)) -> Bool {
  list.any(rows, fn(row) { row.bunker != Unused })
}

/// アカウントとリレーの一覧から「はじめに」の帯の段の状態を決める。どちらの一覧も得られ、
/// バンカーに使うリレーと読み込めたアカウントの少なくとも一方が 0 件のときだけ `Some` を返す。
/// 一覧を得られないときは段が済んだかを決められないので `None` にする。
pub fn getting_started(
  accounts: Result(List(AccountRow), i18n.Reason),
  relays: Result(List(RelayRow), i18n.Reason),
) -> Option(GettingStarted) {
  case accounts, relays {
    Ok(accounts), Ok(relays) ->
      case has_bunker_relay(relays), accounts {
        True, [_, ..] -> None
        bunker_relay, accounts ->
          Some(GettingStarted(bunker_relay:, account: accounts != []))
      }
    _, _ -> None
  }
}

/// 「はじめに」の帯。`getting_started` が `Some` のときだけ、全幅の帯に見出しと 3 つの段を
/// 番号順に並べる。段 1（バンカー用のリレー）と段 2（アカウント）は済んだかで見せ方が変わり、
/// 段 3（接続 URI）は両方が済むまで開けないので、帯が出ている間は常に点線の枠で出す。
fn getting_started_band(
  language: Language,
  accounts: Result(List(AccountRow), i18n.Reason),
  relays: Result(List(RelayRow), i18n.Reason),
) -> Element(msg) {
  case getting_started(accounts, relays) {
    None -> element.none()
    Some(steps) -> {
      let text = i18n.text(language, _)
      view.band(getting_started_anchor, [
        view.section_heading(
          view.sparkle_icon(),
          text(i18n.GettingStarted),
          None,
          [],
          [],
        ),
        html.ol([attribute.class("grid gap-3.5 lg:grid-cols-3")], [
          setup_step(
            language,
            1,
            i18n.SetupBunkerRelay,
            i18n.SetupBunkerRelayDescription,
            open_unless_done(
              steps.bunker_relay,
              add_relay_dialog_id(),
              i18n.AddRelay,
            ),
          ),
          setup_step(
            language,
            2,
            i18n.SetupAccount,
            i18n.SetupAccountDescription,
            open_unless_done(
              steps.account,
              add_account_dialog_id(),
              i18n.AddAccount,
            ),
          ),
          setup_step(
            language,
            3,
            i18n.SetupConnectionUri,
            i18n.SetupConnectionUriDescription,
            StepLocked,
          ),
        ]),
      ])
    }
  }
}

/// 済んだ段は `StepDone`、まだの段は `dialog` の追加のダイアログを開く `StepOpen` にする。
fn open_unless_done(
  done: Bool,
  dialog: String,
  action: i18n.Message,
) -> SetupStep {
  case done {
    True -> StepDone
    False -> StepOpen(dialog, action)
  }
}

/// 「はじめに」の帯の段 1 つ。番号の丸と見出しを 1 行に並べ、その下に説明と追加の操作を置く。
/// 済んだ段は丸を success の色のチェックにして見出しの右に「済み」のチップを付け、開けない段は
/// 枠を点線にして塗らない。
fn setup_step(
  language: Language,
  number: Int,
  title: i18n.Message,
  description: i18n.Message,
  step: SetupStep,
) -> Element(msg) {
  let text = i18n.text(language, _)
  let item_class = case step {
    StepLocked ->
      "flex flex-col items-start gap-2 rounded-box border border-dashed border-field p-4"
    StepDone | StepOpen(..) ->
      "flex flex-col items-start gap-2 rounded-box border border-primary/22 bg-base-100 p-4"
  }
  let number_text = html.text(int.to_string(number))
  let marker = case step {
    StepDone ->
      html.span(
        [
          attribute.class(
            "grid size-7 shrink-0 place-items-center rounded-full bg-success text-success-content",
          ),
        ],
        [view.check_icon()],
      )
    StepOpen(..) ->
      html.span(
        [
          attribute.class(
            "grid size-7 shrink-0 place-items-center rounded-full bg-primary font-mono font-bold text-primary-content",
          ),
        ],
        [number_text],
      )
    StepLocked ->
      html.span(
        [
          attribute.class(
            "grid size-7 shrink-0 place-items-center rounded-full bg-base-300 font-mono font-bold",
          ),
        ],
        [number_text],
      )
  }
  let done_chip = case step {
    StepDone ->
      view.status_chip(view.ToneChip(view.Success), text(i18n.SetupStepDone))
    StepOpen(..) | StepLocked -> element.none()
  }
  let action = case step {
    StepOpen(dialog, action) ->
      view.dialog_trigger(
        dialog,
        view.IconTextTrigger(view.plus_icon(), text(action)),
        view.PrimaryButton,
      )
    StepDone | StepLocked -> element.none()
  }
  html.li([attribute.class(item_class)], [
    html.div([attribute.class("flex flex-wrap items-center gap-2.5")], [
      marker,
      html.h3([attribute.class("font-bold")], [html.text(text(title))]),
      done_chip,
    ]),
    html.p([attribute.class("text-sm text-muted")], [
      html.text(text(description)),
    ]),
    action,
  ])
}

/// アカウントの節。見出しに説明を開く ⓘ、件数、「DB から読み直す」と、「アカウントを追加」のダイアログを開く
/// ボタンを置き、行の一覧の後に読み込めなかった行の枠と、アカウントの追加のダイアログを置く。一覧を得られない
/// ときは、一覧の代わりにその理由（`shared` が `Some` なら「上の理由で取得できません。」）を出し、追加のボタンも
/// 出さない。追加のダイアログは一覧の有無によらず描き、`dialog` が `AddAccountOpen` なら開いた状態で描く。
/// `relays` は接続 QR コードのダイアログに渡す。
fn accounts_section(
  language: Language,
  shared: Option(String),
  accounts: Result(List(AccountRow), i18n.Reason),
  skipped: Result(List(SkippedRow), i18n.Reason),
  sessions: Result(List(SessionRow), i18n.Reason),
  relays: Result(List(RelayRow), i18n.Reason),
  dialog: Option(OpenDialog),
) -> Element(msg) {
  let text = i18n.text(language, _)
  view.section_block(accounts_anchor, [
    listed_section_heading(
      language,
      accounts,
      view.users_icon(),
      i18n.Accounts,
      view.info_hint(language, accounts_anchor <> "-hint", [
        html.text(text(i18n.AccountsDescription)),
      ]),
      [add_account_button(language)],
      [reload_form(language)],
    ),
    listed_body(
      language,
      shared,
      accounts,
      i18n.CouldNotListAccounts,
      view.empty_state(view.users_icon(), text(i18n.NoAccounts), [
        view.dialog_trigger(
          add_account_dialog_id(),
          view.IconTextTrigger(view.plus_icon(), text(i18n.AddAccount)),
          view.OutlineButton,
        ),
      ]),
      fn(rows) {
        view.row_list(
          list.map(rows, account_item(language, sessions, relays, dialog, _)),
        )
      },
    ),
    unreadable_accounts(language, skipped, dialog),
    add_account_dialog(language, dialog),
  ])
}

/// アカウントの節の見出しの、一覧を得たときに出す「アカウントを追加」のダイアログを開くボタン。
fn add_account_button(language: Language) -> Element(msg) {
  view.dialog_trigger(
    add_account_dialog_id(),
    view.IconTextTrigger(view.plus_icon(), i18n.text(language, i18n.AddAccount)),
    view.PrimaryButton,
  )
}

/// 「アカウントを追加」のダイアログ（「既存の秘密鍵を登録」と「新しい秘密鍵を生成」のタブ）。`dialog` が
/// `AddAccountOpen` なら開いた状態で描き、先頭に理由を出して、登録のタブのラベルの欄に送られた値を入れる。
fn add_account_dialog(
  language: Language,
  dialog: Option(OpenDialog),
) -> Element(msg) {
  let text = i18n.text(language, _)
  let id = add_account_dialog_id()
  let #(opening, label, error) = case dialog {
    Some(AddAccountOpen(label:, error:)) -> #(
      view.OpenedByResponse,
      label,
      Some(error),
    )
    _ -> #(view.OpensOnTrigger, "", None)
  }
  view.dialog(
    language,
    id,
    text(i18n.AddAccount),
    fn(placement) {
      [
        view.error_message(language, Some(i18n.CouldNotRegister), error),
        view.radio_tabs(id <> "-tab", [
          #(
            text(i18n.ImportPrivateKey),
            import_form(language, label, placement),
          ),
          #(text(i18n.GenerateNewKey), generate_form(language, placement)),
        ]),
      ]
    },
    i18n.Cancel,
    opening,
  )
}

/// 既存の秘密鍵の登録のフォーム（ページの枠を含まない）。nsec の伏せ字の欄とラベルの欄を送る。nsec の欄の
/// 説明（`ImportDescription`）は見出しの横の ⓘ で開く補足にし、欄の `aria-describedby` から指す。`label` は
/// ラベルの欄に入れる値。アカウントの追加のダイアログが使う。
pub fn import_form(
  language: Language,
  label: String,
  placement: view.Placement,
) -> List(Element(msg)) {
  let text = i18n.text(language, _)
  [
    view.secret_post_form(
      view.segments_path(import_account_segments),
      [
        view.hinted_input(
          language,
          text(i18n.PrivateKeyNsec),
          nsec_hint_id,
          view.FoldedHint(text(i18n.ImportDescription)),
          view.secret_input_attributes(nsec_field, "new-password"),
        ),
        label_fieldset(language, label_hint_id, label),
      ],
      text(i18n.Register),
      view.PrimaryButton,
      placement,
    ),
  ]
}

/// 新しい秘密鍵の生成の説明とフォーム（ページの枠を含まない）。フォームは欄を持たず、送信のボタンは枠の
/// ボタンにする。アカウントの追加のダイアログが使う。
pub fn generate_form(
  language: Language,
  placement: view.Placement,
) -> List(Element(msg)) {
  let text = i18n.text(language, _)
  [
    view.form_description(text(i18n.GenerateDescription)),
    view.post_form(
      view.segments_path(generate_account_segments),
      [],
      text(i18n.Generate),
      view.OutlineButton,
      placement,
    ),
  ]
}

/// nsec の欄の補足の `id`。nsec の欄はアカウントの追加のダイアログに 1 つだけなので固定の値にする。
const nsec_hint_id = "nsec-hint"

/// 直近の読み込みで飛ばされた行の error の色の枠。1 件以上あるときだけ描く。一覧を得られないとき
/// （読み込み中、応答なし、締め切り超過）も描かない。`dialog` は行の削除のダイアログに渡す。
fn unreadable_accounts(
  language: Language,
  skipped: Result(List(SkippedRow), i18n.Reason),
  dialog: Option(OpenDialog),
) -> Element(msg) {
  case skipped {
    Ok([_, ..] as rows) ->
      view.failure_frame(
        view.warning_triangle_icon(),
        i18n.text(language, i18n.UnreadableAccounts),
        list.length(rows),
        i18n.text(language, i18n.UnreadableAccountsWarning),
        list.map(rows, skipped_item(language, _, dialog)),
      )
    Ok([]) | Error(_) -> element.none()
  }
}

/// 飛ばした行 1 件。灰色の鍵の指紋、識別と理由の 1 文を並べ、右に削除のダイアログを開くボタンを置く。
/// `pubkey` 列が形式不正の行は指紋も識別も削除のボタンも出さず、理由の 1 文に削除できない旨を続けて出す。
fn skipped_item(
  language: Language,
  row: SkippedRow,
  dialog: Option(OpenDialog),
) -> Element(msg) {
  case row.reason {
    vault.MalformedPubkey ->
      view.list_row(view.InlineRow, [
        html.p([attribute.class("text-sm")], [
          html.text(i18n.text(language, i18n.UnreadableReason(row.reason))),
          html.text(
            i18n.sentence_gap(language)
            <> i18n.text(language, i18n.UnreadableNotDeletable),
          ),
        ]),
      ])
    _ ->
      view.list_row(view.InlineRow, [
        html.div([attribute.class("flex min-w-0 items-center gap-3")], [
          fingerprint.pubkey_svg(row.pubkey, fingerprint.Gray, "size-8"),
          html.div([attribute.class("flex min-w-0 flex-col gap-1")], [
            view.identity(language, view.PlainIdentity, row.label, row.npub),
            html.p([attribute.class("text-sm")], [
              html.text(i18n.text(language, i18n.UnreadableReason(row.reason))),
            ]),
          ]),
        ]),
        button_row(unreadable_dialog(language, row, dialog)),
      ])
  }
}

/// 一覧を得る節の見出し。一覧を得て 1 件以上あるときだけ件数を出す。`hint`（ⓘ と補足）は一覧の有無に
/// 関わらず題の横に出す。操作は `always_actions` を常に先に出し、一覧を得たときだけその後ろに
/// `listed_actions` を出す。
fn listed_section_heading(
  language: Language,
  listing: Result(List(a), i18n.Reason),
  icon: Element(msg),
  title: i18n.Message,
  hint: List(Element(msg)),
  listed_actions: List(Element(msg)),
  always_actions: List(Element(msg)),
) -> Element(msg) {
  let count = case listing {
    Ok([_, ..] as rows) -> Some(list.length(rows))
    Ok([]) | Error(_) -> None
  }
  let actions = case listing {
    Ok(_) -> list.append(always_actions, listed_actions)
    Error(_) -> always_actions
  }
  view.section_heading(icon, i18n.text(language, title), count, hint, actions)
}

/// 一覧を得たときの節の本文。得られれば `render` の内容を出す。得られず、3 つの一覧に共通の理由（`shared`）が
/// ページの先頭に出ているときは「上の理由で取得できません。」の 1 文だけを出し、そうでなければ `lead` を前置きに
/// したエラーの色の理由の囲みを面（`view.surface`）に載せて出す。承認待ち、アカウント、セッション、リレーの節が
/// 使い、リレーの節は `shared` に `None` を渡す。
fn listed_body(
  language: Language,
  shared: Option(String),
  listing: Result(List(a), i18n.Reason),
  lead: i18n.Lead,
  empty: Element(msg),
  render: fn(List(a)) -> Element(msg),
) -> Element(msg) {
  case listing, shared {
    Ok(rows), _ -> section_body(rows, empty, render)
    Error(_), Some(_) ->
      view.hint(i18n.text(language, i18n.NotAvailableForReasonAbove))
    Error(reason), None ->
      view.surface([
        view.alert(
          view.Failure,
          view.reason_content(language, Some(lead), reason),
        ),
      ])
  }
}

/// 承認待ち、アカウント、セッションの 3 つの一覧が、同じ英語の理由（DB の障害、読み込み中）で得られない
/// ときのその理由。1 つでも得られたとき、理由が 1 つでも違うとき、締め切り超過（訳した理由）のときは `None`。
fn shared_failure(snapshot: Snapshot) -> Option(String) {
  case snapshot.pending, snapshot.accounts, snapshot.sessions {
    Error(i18n.Untranslated(pending)),
      Error(i18n.Untranslated(accounts)),
      Error(i18n.Untranslated(sessions))
      if pending == accounts && accounts == sessions
    -> Some(pending)
    _, _, _ -> None
  }
}

/// 3 つの一覧に共通の理由を、エラーの色の囲みで 1 つ出す。日本語のページでは、何を表示できないかの前置きを
/// 付ける。共通の理由が無ければ何も出さない。
fn shared_failure_alert(
  language: Language,
  shared: Option(String),
) -> Element(msg) {
  case shared {
    Some(detail) ->
      view.alert(
        view.Failure,
        view.reason_content(
          language,
          Some(i18n.CouldNotListPendingAccountsSessions),
          i18n.Untranslated(detail),
        ),
      )
    None -> element.none()
  }
}

/// アカウント 1 件。上の段にアイコン（`account_icon`）、識別、セッションの件数、「接続 QR コード」のダイアログを
/// 開くボタンを並べ、下に「接続 URI と操作」の畳みを置く。幅が足りなければ件数とボタンを次の行へ回す。畳みの
/// 後に、行の操作と接続 QR コードのダイアログを置く（閉じた畳みの中では開いた状態で描いても見えない）。
fn account_item(
  language: Language,
  sessions: Result(List(SessionRow), i18n.Reason),
  relays: Result(List(RelayRow), i18n.Reason),
  dialog: Option(OpenDialog),
  account: AccountRow,
) -> Element(msg) {
  let action_dialogs =
    list.map(list.append(detail_actions, [DeleteAccount]), fn(action) {
      account_dialog(language, account, action, dialog)
    })
  view.list_row(view.StackedRow, [
    html.div([attribute.class("flex flex-wrap items-center gap-x-4 gap-y-2")], [
      html.div(
        [attribute.class("flex min-w-0 flex-1 basis-48 items-center gap-3")],
        [
          account_icon(account),
          view.identity(
            language,
            view.LargeIdentity,
            account.label,
            account.npub,
          ),
        ],
      ),
      html.div([attribute.class("ml-auto flex shrink-0 items-center gap-3")], [
        session_count(language, sessions, account.signer),
        view.dialog_trigger(
          connection_qr_dialog_id(account.signer),
          view.CompactTrigger(
            view.qr_code_icon(),
            i18n.text(language, i18n.ConnectionQr),
          ),
          view.PrimaryButton,
        ),
      ]),
    ]),
    account_details(language, account),
    ..list.append(action_dialogs, [
      connection_qr_dialog(language, account, relays),
    ])
  ])
}

/// アカウントの行のアイコン。鍵の指紋を描き、`picture` があればその画像を透明で重ねる。`admin.js` が
/// 読めた画像に `data-loaded` を付けて見せるので、無い・読めない・JS が無いときは指紋が見える。
fn account_icon(account: AccountRow) -> Element(msg) {
  html.div([attribute.class("relative size-10 shrink-0")], [
    fingerprint.pubkey_svg(account.signer, fingerprint.Colored, "size-10"),
    case account.picture {
      Some(url) ->
        html.img([
          attribute.src(url),
          attribute.alt(""),
          attribute.width(40),
          attribute.height(40),
          attribute.attribute("referrerpolicy", "no-referrer"),
          attribute.attribute("decoding", "async"),
          attribute.attribute("data-avatar", ""),
          attribute.class(
            "absolute inset-0 size-10 rounded-field object-cover border border-base-300 opacity-0 data-loaded:opacity-100",
          ),
        ])
      None -> element.none()
    },
  ])
}

/// 署名者 `signer` の承認済みセッションの件数。セッションの一覧を得られないときは、0 件と読み違えさせないよう
/// 何も出さない。
fn session_count(
  language: Language,
  sessions: Result(List(SessionRow), i18n.Reason),
  signer: String,
) -> Element(msg) {
  case sessions {
    Ok(rows) ->
      html.span([attribute.class("text-sm whitespace-nowrap text-muted")], [
        html.text(i18n.text(
          language,
          i18n.SessionCount(list.count(rows, fn(row) { row.signer == signer })),
        )),
      ])
    Error(_) -> element.none()
  }
}

/// 「接続 URI と操作」の畳み。secret 入りの URI と要承認の URI を、説明を見出しの横の ⓘ で開くコピー欄で、
/// 16 進の公開鍵を説明なしでコピー欄に並べ、その下に、`detail_actions` の操作のダイアログを開くボタンと、
/// 右端に離した削除のダイアログを開くボタンを置く。ダイアログは畳みの外（`account_item`）に置く。
fn account_details(language: Language, account: AccountRow) -> Element(msg) {
  let text = i18n.text(language, _)
  let trigger = account_action_trigger(language, account.signer, _)
  view.details_panel(text(i18n.ConnectionUrisAndActions), [
    html.div([attribute.class("flex flex-col gap-3")], [
      view.hinted_copyable_field(
        language,
        text(i18n.ConnectionUri),
        "account-" <> account.signer <> "-uri-hint",
        text(i18n.SecretUriDescription),
        account.uri,
      ),
      view.hinted_copyable_field(
        language,
        text(i18n.ConnectionUriForApproval),
        "account-" <> account.signer <> "-auth-uri-hint",
        text(i18n.ApprovalUriNeedsApproval),
        account.auth_uri,
      ),
      view.copyable_field(language, text(i18n.PublicKeyHex), account.signer),
      html.div(
        [attribute.class("flex flex-wrap items-center gap-2")],
        list.append(list.map(detail_actions, trigger), [
          html.div([attribute.class("ml-auto")], [trigger(DeleteAccount)]),
        ]),
      ),
    ]),
  ])
}

/// アカウント 1 件への操作のダイアログの `id`（`dialog-account-<署名者>-<セグメント>`）。
fn account_dialog_id(signer: String, action: AccountAction) -> String {
  view.dialog_id(["account", signer, account_action_segment(action)])
}

/// アカウント 1 件への操作のダイアログを開くボタン。語と種類は操作から決める。
fn account_action_trigger(
  language: Language,
  signer: String,
  action: AccountAction,
) -> Element(msg) {
  view.dialog_trigger(
    account_dialog_id(signer, action),
    view.IconTextTrigger(
      account_action_icon(action),
      i18n.text(language, account_action_row_title(action)),
    ),
    account_action_button_kind(action),
  )
}

/// アカウント 1 件への操作のダイアログ。題は操作の見出しで、中にラベルと省略した npub、`account_action_form`
/// の説明とフォームを並べる。ラベルの欄の補足の `id` は、ダイアログの `id` に `-label-hint` を付けて行ごとに
/// 変える。`dialog` がこの行と操作の `AccountActionOpen` なら開いた状態で描き、要約の後に理由を出して、
/// ラベルの欄に送られた値を入れる。
fn account_dialog(
  language: Language,
  account: AccountRow,
  action: AccountAction,
  dialog: Option(OpenDialog),
) -> Element(msg) {
  let id = account_dialog_id(account.signer, action)
  let #(opening, label, error) = case dialog {
    Some(AccountActionOpen(signer:, action: opened, label:, error:))
      if signer == account.signer && opened == action
    -> #(view.OpenedByResponse, label, Some(error))
    _ -> #(view.OpensOnTrigger, None, None)
  }
  view.dialog(
    language,
    id,
    i18n.text(language, account_action_title(action)),
    fn(placement) {
      [
        view.identity(language, view.PlainIdentity, account.label, account.npub),
        view.error_message(language, action_lead(action), error),
        ..account_action_form(
          language,
          account,
          action,
          label,
          id <> "-label-hint",
          placement,
        )
      ]
    },
    i18n.Cancel,
    opening,
  )
}

/// 読み込みで飛ばされた行の削除のダイアログを開くボタンと、そのダイアログ。ボタンは「削除」の error の
/// 文字色、題はアカウントの削除の見出しで、中にラベルと省略した npub、`unreadable_delete_form` を並べる。
/// `id` の節の語をアカウントの行と分け、同じ pubkey の行があってもダイアログが重ならないようにする。
/// `dialog` がこの行の `UnreadableDeleteOpen` なら開いた状態で描き、要約の後に理由を出す。
fn unreadable_dialog(
  language: Language,
  row: SkippedRow,
  dialog: Option(OpenDialog),
) -> List(Element(msg)) {
  let text = i18n.text(language, _)
  let id = view.dialog_id(["unreadable", row.pubkey, "delete"])
  let #(opening, error) = case dialog {
    Some(UnreadableDeleteOpen(pubkey:, error:)) if pubkey == row.pubkey -> #(
      view.OpenedByResponse,
      Some(error),
    )
    _ -> #(view.OpensOnTrigger, None)
  }
  [
    view.dialog_trigger(
      id,
      view.IconTextTrigger(view.trash_icon(), text(i18n.Delete)),
      view.DangerGhostButton,
    ),
    view.dialog(
      language,
      id,
      text(account_action_title(DeleteAccount)),
      fn(placement) {
        [
          view.identity(language, view.PlainIdentity, row.label, row.npub),
          view.error_message(language, Some(i18n.CouldNotDeleteAccount), error),
          ..unreadable_delete_form(language, row, placement)
        ]
      },
      i18n.Cancel,
      opening,
    ),
  ]
}

/// 操作のダイアログで、バンカーから英語のまま届いた理由の前に置く前置き。秘密鍵の表示の
/// フォームに出る理由は管理パスワードの誤り（訳す理由）だけなので、前置きを持たない。
fn action_lead(action: AccountAction) -> Option(i18n.Lead) {
  case action {
    EditLabel -> Some(i18n.CouldNotSaveLabel)
    RotateSecret -> Some(i18n.CouldNotRotateSecret)
    DeleteAccount -> Some(i18n.CouldNotDeleteAccount)
    RevealPrivateKey -> None
  }
}

/// 接続 QR コードのダイアログの `id`（`dialog-account-<署名者>-qr`）。
fn connection_qr_dialog_id(signer: String) -> String {
  view.dialog_id(["account", signer, "qr"])
}

/// 接続 QR コードのダイアログ。アカウントの識別、バンカーに使うリレーが無いときの警告、secret 入りの URI と
/// 要承認の URI のタブ（`uri_tab`。タブの `name` はダイアログの `id` に `-tab` を付ける）、カメラ用のコードの
/// 貼り方、この URI が使うバンカーのリレーの URL の順に並べる。符号化できない URI はその位置に理由を出し、
/// コピー欄は残す。
fn connection_qr_dialog(
  language: Language,
  account: AccountRow,
  relays: Result(List(RelayRow), i18n.Reason),
) -> Element(msg) {
  let text = i18n.text(language, _)
  let id = connection_qr_dialog_id(account.signer)
  view.dialog(
    language,
    id,
    text(i18n.ConnectionQr),
    fn(placement) {
      [
        view.identity(language, view.PlainIdentity, account.label, account.npub),
        no_bunker_relay_alert(language, relays),
        view.radio_tabs(id <> "-tab", [
          uri_tab(
            language,
            i18n.ConnectionUri,
            account.uri,
            account.uri_camera_text,
            view.alert(view.Warning, [
              html.text(text(i18n.ConnectionQrSecretWarning)),
            ]),
          ),
          uri_tab(
            language,
            i18n.ConnectionUriForApproval,
            account.auth_uri,
            account.auth_uri_camera_text,
            approval_note(language),
          ),
        ]),
        html.p([], [html.text(text(i18n.CameraCopySteps))]),
        view.hint(text(i18n.CameraCopyNote)),
        html.h3([attribute.class("font-bold")], [
          html.text(text(i18n.BunkerRelaysForUri)),
        ]),
        view.hint(text(i18n.BunkerRelaysHint)),
        bunker_relay_list(language, relays),
        ..view.dialog_actions(placement, [])
      ]
    },
    i18n.Close,
    view.OpensOnTrigger,
  )
}

/// 要承認のタブの `note`。この URI で接続したクライアントは承認待ちで承認するまで署名
/// できない旨を伝える。
fn approval_note(language: Language) -> Element(msg) {
  html.p([], [html.text(i18n.text(language, i18n.ApprovalUriNeedsApproval))])
}

/// 接続 URI 1 件のタブの語と中身の組（`view.radio_tabs` に渡す）。中身は `note`、端末の
/// カメラ用のコピー用の文字列 `camera_text` の QR、`uri` のコピー欄、クライアントの読み取り
/// 機能が読む完全な `uri` の QR の畳みの順に並べる。
fn uri_tab(
  language: Language,
  title: i18n.Message,
  uri: String,
  camera_text: String,
  note: Element(msg),
) -> #(String, List(Element(msg))) {
  let text = i18n.text(language, title)
  #(text, [
    note,
    qr_or_notice(language, text, camera_text),
    view.copyable_field(language, text, uri),
    view.details_panel(i18n.text(language, i18n.ScanWithClientScanner), [
      qr_or_notice(
        language,
        text <> " / " <> i18n.text(language, i18n.ScanWithClientScanner),
        uri,
      ),
    ]),
  ])
}

/// この URI が使うバンカーのリレーの URL の一覧。`relays` が `Error` なら一覧の代わりに理由を出す。
/// `Unused` でない `bunker` の用途を持つ行だけを出す。
fn bunker_relay_list(
  language: Language,
  relays: Result(List(RelayRow), i18n.Reason),
) -> Element(msg) {
  case relays {
    Ok(rows) ->
      case list.filter(rows, fn(row) { row.bunker != Unused }) {
        [] -> element.none()
        bunker_rows ->
          view.code_list(list.map(bunker_rows, fn(row) { row.url }))
      }
    Error(reason) ->
      view.alert(
        view.Neutral,
        view.reason_content(language, Some(i18n.CouldNotListRelays), reason),
      )
  }
}

/// QR コードに載せる文字列 1 つ。完全な `bunker://` URI と、カメラ用のコピー用の文字列のどちらも受ける。符号化できなければ理由を出す。
fn qr_or_notice(
  language: Language,
  label: String,
  text: String,
) -> Element(msg) {
  case qr.svg(label, text) {
    Ok(svg) -> svg
    Error(Nil) ->
      view.alert(view.Neutral, [
        html.text(i18n.text(language, i18n.CouldNotEncodeQr)),
      ])
  }
}

/// POST の応答で開く、ダッシュボードに入口の無いダイアログ（生成した鍵、秘密鍵）。`id` は `dialog-result`
/// で、Esc で閉じず、閉じるとダッシュボード（`/`）へ戻る。
fn result_dialog(
  language: Language,
  dialog: Option(OpenDialog),
) -> Element(msg) {
  let text = i18n.text(language, _)
  let id = view.dialog_id(["result"])
  case dialog {
    Some(GeneratedKeyOpen(npub:, nsec:, label:, problem:)) ->
      view.dialog(
        language,
        id,
        text(i18n.GeneratedKey),
        fn(placement) {
          [
            option.map(problem, problem_alert(language, _))
              |> option.unwrap(element.none()),
            view.truncated_id(language, npub, text(i18n.CopyNpub)),
            view.alert(
              view.Warning,
              view.emphasized(language, i18n.BackUpNow, i18n.GeneratedKeyNotice),
            ),
            view.copyable_field(language, text(i18n.PrivateKeyNsec), nsec),
            view.post_form(
              view.segments_path(register_generated_segments),
              [
                view.hidden_input(nsec_field, nsec),
                label_fieldset(language, id <> "-label-hint", label),
              ],
              text(i18n.RegisterThisKey),
              view.PrimaryButton,
              placement,
            ),
          ]
        },
        i18n.Cancel,
        view.OpenedByResponsePinned,
      )
    Some(PrivateKeyOpen(row:, nsec:)) ->
      view.dialog(
        language,
        id,
        text(i18n.PrivateKey),
        fn(placement) {
          [
            view.identity(language, view.PlainIdentity, row.label, row.npub),
            view.copyable_field(language, text(i18n.PrivateKeyNsec), nsec),
            view.alert(
              view.Warning,
              view.emphasized(language, i18n.CopyThenClose, i18n.ResendNotice),
            ),
            ..view.dialog_actions(placement, [])
          ]
        },
        i18n.Close,
        view.OpenedByResponsePinned,
      )
    _ -> element.none()
  }
}

/// 生成した鍵のダイアログの先頭に出す、再描画の理由の囲み。
fn problem_alert(
  language: Language,
  problem: GeneratedKeyProblem,
) -> Element(msg) {
  case problem {
    InvalidLabel(reason) ->
      view.error_message(language, None, Some(i18n.Translated(reason)))
    NotApplied(reason) ->
      view.error_message(language, Some(i18n.CouldNotRegister), Some(reason))
    NotAccepted(reason) ->
      guided_warning(
        language,
        i18n.RegistrationNotAccepted,
        i18n.Untranslated(reason),
      )
    NotConfirmed(cause) ->
      guided_warning(
        language,
        i18n.RegistrationNotConfirmed,
        i18n.Translated(cause),
      )
  }
}

/// 次の操作の案内の文に理由を続けた、`Warning` の囲み。
fn guided_warning(
  language: Language,
  guide: i18n.Message,
  reason: i18n.Reason,
) -> Element(msg) {
  view.reason_alert(view.Warning, [
    html.text(i18n.text(language, guide) <> i18n.sentence_gap(language)),
    ..view.reason_content(language, None, reason)
  ])
}

/// アカウント 1 件への操作のアイコン。
fn account_action_icon(action: AccountAction) -> Element(msg) {
  case action {
    EditLabel -> view.pencil_icon()
    RevealPrivateKey -> view.eye_icon()
    RotateSecret -> view.rotate_icon()
    DeleteAccount -> view.trash_icon()
  }
}

/// 行の操作のボタンの語。削除だけ短い語（`i18n.Delete`）にする。ダイアログの題は
/// `account_action_title` のまま変えない。
fn account_action_row_title(action: AccountAction) -> i18n.Message {
  case action {
    DeleteAccount -> i18n.Delete
    EditLabel | RevealPrivateKey | RotateSecret -> account_action_title(action)
  }
}

/// アカウント 1 件への操作のボタンの種類。畳みの操作は地味なボタンにし、削除だけ error の文字色にする。
fn account_action_button_kind(action: AccountAction) -> view.ButtonKind {
  case action {
    EditLabel | RevealPrivateKey | RotateSecret -> view.GhostButton
    DeleteAccount -> view.DangerGhostButton
  }
}

/// アカウント 1 件への操作の説明と、操作を実行する 1 つのフォーム（ページの枠を含まない）。
/// ダッシュボードの操作のダイアログが使う。ラベルの編集の欄には、`label` が `Some` ならその値（入力の誤りか
/// 409 で再描画するときに送られた値）を、`None` なら `row` の保存済みのラベルを入れ、欄の補足の `id` を
/// `hint_id` にする。送信のボタンの種類は操作ごとに決める（ラベルの保存は主、secret の作り直しと秘密鍵の
/// 表示は warning の枠、削除は危険）。送信のボタンの文言は、見出しとボタンの語（`account_action_title`）
/// とは別に持つ。削除の説明の警告は畳まずに出す。
fn account_action_form(
  language: Language,
  row: AccountRow,
  action: AccountAction,
  label: Option(String),
  hint_id: String,
  placement: view.Placement,
) -> List(Element(msg)) {
  let text = i18n.text(language, _)
  let path = account_action_path(row.signer, action)
  case action {
    EditLabel -> [
      view.post_form(
        path,
        [label_fieldset(language, hint_id, option.unwrap(label, row.label))],
        text(i18n.Save),
        view.PrimaryButton,
        placement,
      ),
    ]
    RotateSecret -> [
      html.p([], [html.text(text(i18n.RotateSecretDescription))]),
      view.post_form(
        path,
        [],
        text(i18n.RotateSecretSubmit),
        view.WarningOutlineButton,
        placement,
      ),
    ]
    DeleteAccount -> {
      let gap = i18n.sentence_gap(language)
      [
        html.p([], [
          html.text(text(i18n.DeleteDescription) <> gap),
          html.strong([], [html.text(text(i18n.DeleteWarning))]),
          html.text(gap <> text(i18n.DeleteAlsoRemoves)),
        ]),
        view.post_form(
          path,
          [],
          text(i18n.DeleteAccountSubmit),
          view.DangerButton,
          placement,
        ),
      ]
    }
    RevealPrivateKey -> [
      html.p([], [html.text(text(i18n.ShowPrivateKeyDescription))]),
      view.post_form(
        path,
        [
          view.labelled(
            text(i18n.AdminPassword),
            view.secret_input(password_field, "off"),
          ),
        ],
        text(i18n.ShowPrivateKeySubmit),
        view.WarningOutlineButton,
        placement,
      ),
    ]
  }
}

/// 読み込みで飛ばされた行の削除の説明とフォーム（ページの枠を含まない）。
/// ダッシュボードの読み込めなかった行の削除のダイアログが使う。説明は、行を消すこと、nsec を控えて
/// いなければ失うこと（強調して畳まずに出す）、以前のマスターキーに戻せば控えられること、セッションと
/// 承認待ちも消えることの順に並べる。送信のボタンは危険のボタンにする。
fn unreadable_delete_form(
  language: Language,
  row: SkippedRow,
  placement: view.Placement,
) -> List(Element(msg)) {
  let text = i18n.text(language, _)
  let gap = i18n.sentence_gap(language)
  [
    html.p([], [
      html.text(text(i18n.DeleteUnreadableDescription) <> gap),
      html.strong([], [html.text(text(i18n.DeleteUnreadableWarning))]),
      html.text(
        gap
        <> text(i18n.DeleteUnreadableRecover)
        <> gap
        <> text(i18n.DeleteAlsoRemoves),
      ),
    ]),
    view.post_form(
      account_action_path(row.pubkey, DeleteAccount),
      [],
      text(i18n.DeleteAccountSubmit),
      view.DangerButton,
      placement,
    ),
  ]
}

/// アカウントの追加のダイアログのラベルの欄の補足の `id`。ラベルの欄が 1 つだけなので固定の値にする。行ごとの
/// ラベルの編集のダイアログはダイアログの `id` に `-label-hint` を付けた値を、生成した鍵のダイアログは
/// `dialog-result-label-hint` を使う。
const label_hint_id = "label-hint"

/// ラベルの見出し、入力欄、上限の補足をまとめた囲み。補足の `id` は `hint_id`。アカウントの追加、生成した鍵、
/// ラベルの編集のダイアログのどのフォームでも必須にする。
fn label_fieldset(
  language: Language,
  hint_id: String,
  value: String,
) -> Element(msg) {
  let caption = i18n.text(language, i18n.Label)
  view.hinted_input(
    language,
    caption,
    hint_id,
    view.LineHint(i18n.text(
      language,
      i18n.LabelHint(max: max_label_code_points),
    )),
    [
      attribute.type_("text"),
      attribute.name(label_field),
      attribute.autocomplete("off"),
      attribute.default_value(value),
      attribute.required(True),
      attribute.class("input w-full border-base-content/60"),
    ],
  )
}

/// 承認待ちの接続の帯。1 件以上あるとき、または一覧を得られないときだけ、全幅の帯（`view.band`）に、
/// 説明を ⓘ で開く見出しと承認待ちのカードを置く。見出しの右には、`refresh` が自動の読み込み直しのときだけ
/// 更新の間隔を出す。
/// 0 件のときは帯ごと出さない。`now` は描画の時点の Unix 秒で、失効の時刻を求めるのに使う。
/// `shared` が `Some` なら、理由の代わりに「上の理由で取得できません。」を出す。
fn pending_section(
  language: Language,
  accounts: Result(List(AccountRow), i18n.Reason),
  now: Int,
  shared: Option(String),
  pending: Result(List(PendingRow), i18n.Reason),
  refresh: view.Refresh,
) -> Element(msg) {
  case pending {
    Ok([]) -> element.none()
    _ -> {
      let text = i18n.text(language, _)
      let count = case pending {
        Ok(rows) -> Some(list.length(rows))
        Error(_) -> None
      }
      view.band(pending_anchor, [
        view.section_heading(
          view.door_open_icon(),
          text(i18n.PendingConnections),
          count,
          view.info_hint(language, pending_anchor <> "-hint", [
            html.text(text(i18n.PendingConnectionsDescription)),
          ]),
          refresh_note(language, refresh),
        ),
        listed_body(
          language,
          shared,
          pending,
          i18n.CouldNotListPending,
          element.none(),
          fn(rows) {
            html.div(
              [
                attribute.class(
                  "grid grid-cols-[repeat(auto-fit,minmax(min(100%,460px),1fr))] gap-3.5",
                ),
              ],
              list.map(rows, fn(entry) {
                pending_card(
                  language,
                  signer_name(accounts, entry.signer),
                  now,
                  entry,
                )
              }),
            )
          },
        ),
      ])
    }
  }
}

/// 承認待ちの帯の見出しの右に置く、更新の間隔の表示。ページを自動で読み込み直すとき（`refresh` が
/// `RefreshEverySeconds` のとき）だけ出す。
fn refresh_note(
  language: Language,
  refresh: view.Refresh,
) -> List(Element(msg)) {
  case refresh {
    view.RefreshEverySeconds(seconds) -> [
      html.p(
        [
          attribute.class(
            "flex items-center gap-2 rounded-full border border-base-300 bg-base-100 px-3 py-1 text-xs text-muted",
          ),
        ],
        [
          view.clock_icon(),
          html.text(i18n.text(language, i18n.RefreshesEverySeconds(seconds))),
        ],
      ),
    ]
    view.NoRefresh -> []
  }
}

/// 承認待ち 1 件のカード。ダッシュボードの承認待ちの帯と承認ページが使う。左に残り時間の円、右にクライアントの
/// 公開鍵（指紋、省略、コピー）と secret の提示の区別、署名者、失効までを置き、下に権限のチップと承認・拒否のボタンを
/// 並べる。secret が一致しないときは枠を warning の色にし、署名者の上に `WrongSecretNotice` の囲みを置く。
fn pending_card(
  language: Language,
  signer: SignerName,
  now: Int,
  pending: PendingRow,
) -> Element(msg) {
  let text = i18n.text(language, _)
  let #(card_class, ring_rows) = case pending.secret_mismatch {
    True -> #(
      "grid grid-cols-[auto_minmax(0,1fr)] items-start gap-x-4 gap-y-3 rounded-box border bg-base-100 p-4 shadow-sm border-warning/55",
      "sm:row-span-3",
    )
    False -> #(
      "grid grid-cols-[auto_minmax(0,1fr)] items-start gap-x-4 gap-y-3 rounded-box border bg-base-100 p-4 shadow-sm border-primary/22",
      "sm:row-span-2",
    )
  }
  let notice = case pending.secret_mismatch {
    True ->
      html.div([attribute.class("col-span-2 sm:col-span-1 sm:col-start-2")], [
        view.alert(view.Warning, [html.text(text(i18n.WrongSecretNotice))]),
      ])
    False -> element.none()
  }
  html.article([attribute.class(card_class)], [
    countdown_ring(language, pending.expires_in_seconds, ring_rows),
    html.div(
      [
        attribute.class("flex min-w-0 flex-wrap items-center gap-x-3 gap-y-1.5"),
      ],
      [
        client_pubkey_line(language, pending.client),
        secret_badge(language, pending.secret_mismatch),
      ],
    ),
    notice,
    html.div([attribute.class("col-span-2 sm:col-span-1 sm:col-start-2")], [
      view.detail_list([
        #(text(i18n.Signer), html.dd([], [signer_value(signer)])),
        #(
          text(i18n.ExpiresIn),
          expiry_value(language, now, pending.expires_in_seconds),
        ),
      ]),
    ]),
    html.div(
      [
        attribute.class(
          "col-span-2 flex flex-col gap-2 border-t border-base-300 pt-3",
        ),
      ],
      [
        html.p([attribute.class("text-xs font-semibold text-muted")], [
          html.text(text(i18n.Permissions)),
        ]),
        permission_view.chips(language, pending.perms),
      ],
    ),
    html.div(
      [
        attribute.class(
          "col-span-2 grid grid-cols-2 gap-2 *:grid sm:flex sm:justify-end",
        ),
      ],
      decision_forms(language, pending.token, pending.secret_mismatch),
    ),
  ])
}

/// 残り時間の円。600 秒（承認待ちの寿命）を満たんとし、`pathLength="600"` の円に `stroke-dasharray` で
/// 残りの秒だけの弧を描き、中央に「分:秒」を出す。60 秒未満は弧と数字を warning の色にする。円は飾りにし、
/// 残り時間は囲みの `aria-label` で読み上げる。`rows` は広い画面で円が跨ぐ行のクラスである。
fn countdown_ring(
  language: Language,
  seconds: Int,
  rows: String,
) -> Element(msg) {
  let remaining = int.clamp(seconds, 0, engine.pending_ttl_seconds)
  let clock = view.countdown(remaining)
  let #(arc_class, clock_class) = case remaining < 60 {
    True -> #(
      "fill-none stroke-6 stroke-warning",
      "absolute inset-0 grid place-items-center font-mono text-sm font-bold tabular-nums text-warning",
    )
    False -> #(
      "fill-none stroke-6 stroke-primary",
      "absolute inset-0 grid place-items-center font-mono text-sm font-bold tabular-nums",
    )
  }
  let circle = fn(attributes) {
    svg.circle([
      attribute.attribute("cx", "32"),
      attribute.attribute("cy", "32"),
      attribute.attribute("r", "28"),
      ..attributes
    ])
  }
  html.div(
    [
      attribute.role("img"),
      attribute.aria_label(i18n.text(language, i18n.ExpiresIn) <> " " <> clock),
      attribute.class("relative size-14 sm:size-17"),
      attribute.class(rows),
    ],
    [
      svg.svg(
        [
          attribute.aria_hidden(True),
          attribute.attribute("viewBox", "0 0 64 64"),
          attribute.class("size-full -rotate-90"),
        ],
        [
          circle([attribute.class("fill-none stroke-6 stroke-base-300")]),
          circle([
            attribute.attribute(
              "pathLength",
              int.to_string(engine.pending_ttl_seconds),
            ),
            attribute.attribute(
              "stroke-dasharray",
              int.to_string(remaining)
                <> " "
                <> int.to_string(engine.pending_ttl_seconds),
            ),
            attribute.attribute("stroke-linecap", "round"),
            attribute.class(arc_class),
          ]),
        ],
      ),
      html.span([attribute.aria_hidden(True), attribute.class(clock_class)], [
        html.text(clock),
      ]),
    ],
  )
}

/// 失効までの値。「8:12（12:12:43 に失効）」の形で、残りの「分:秒」に続けて失効の時刻を `view.time_of_day`
/// で出す。60 秒未満は先頭に warning の色の三角を置く。
fn expiry_value(language: Language, now: Int, seconds: Int) -> Element(msg) {
  let text = i18n.text(language, _)
  let mark = case seconds < 60 {
    True ->
      html.span(
        [attribute.class("mr-1 inline-block align-[-3px] text-warning")],
        [
          view.warning_triangle_icon(),
        ],
      )
    False -> element.none()
  }
  html.dd([], [
    mark,
    html.text(text(i18n.ExpiryBeforeTime(view.countdown(seconds)))),
    view.time_of_day(language, now + seconds),
    html.text(text(i18n.ExpiryAfterTime)),
  ])
}

/// 承認ページ。クライアントが `auth_url` で開く、接続要求 1 件の確認画面。ダッシュボードと同じ承認待ちのカード
/// （`pending_card`）の下に、承認の意味の説明を畳まずに置く。`now` は描画の時点の Unix 秒で、失効の時刻を求めるのに
/// 使う。テーマか言語を切り替えた後は同じ承認ページを開き直す。
pub fn approval_page(
  language: Language,
  theme: view.Theme,
  accounts: Result(List(AccountRow), i18n.Reason),
  now: Int,
  pending: PendingRow,
) -> String {
  view.page(
    language,
    theme,
    i18n.ApproveConnection,
    view.Narrow,
    view.SwitchReturningTo(approve_path(pending.token)),
    view.RefreshEverySeconds(refresh_seconds),
    [
      html.section([attribute.class("flex flex-col gap-4")], [
        pending_card(
          language,
          signer_name(accounts, pending.signer),
          now,
          pending,
        ),
        approval_explanation(language, pending.perms),
      ]),
    ],
  )
}

/// 承認の意味の説明。権限が空のときは、署名と暗号化を拒否する旨の一文を続ける。
fn approval_explanation(language: Language, perms: String) -> Element(msg) {
  let text = i18n.text(language, _)
  let content = case perms {
    "" -> [
      html.text(text(i18n.ApprovalExplanation)),
      html.text(
        i18n.sentence_gap(language) <> text(i18n.NoPermissionsRequested),
      ),
    ]
    _ -> [html.text(text(i18n.ApprovalExplanation))]
  }
  view.alert(view.Info, content)
}

/// 見出しと理由だけを伝えるページ。承認・拒否の結果、アカウントを扱えないとき、変更が反映されたか分からないとき、
/// 404 / 405 / 400 の通知に使う。カードの先頭に `tone` の結果の印（`view.notice_mark`）と理由を横に並べる。`tone` は
/// 呼び出し側が結果に応じて決める。`below` は印と理由の直後にカードの中へ並べる要素で、無ければ空リストを渡す。
/// ダッシュボードで状態を確かめられるようリンクを置く。切り替えを出すか、切り替えた後にどこを開くかは呼び出し側が
/// `switch` で決める。
pub fn notice_page(
  language: Language,
  theme: view.Theme,
  switch: view.NavbarSwitch,
  title: i18n.Message,
  message: i18n.Reason,
  tone: view.Tone,
  below: List(Element(msg)),
) -> String {
  view.page(language, theme, title, view.Narrow, switch, view.NoRefresh, [
    view.card([
      html.div([attribute.class("flex items-start gap-3")], [
        view.notice_mark(tone),
        html.p(
          [attribute.class("min-w-0 self-center")],
          view.reason_content(language, None, message),
        ),
      ]),
      ..below
    ]),
    view.back_link(language),
  ])
}

/// 操作の見出し（ダイアログの題）。削除を除き、ダッシュボードのボタンの語にも使う
/// （`account_action_row_title`）。
fn account_action_title(action: AccountAction) -> i18n.Message {
  case action {
    EditLabel -> i18n.EditLabel
    RotateSecret -> i18n.RotateSecret
    DeleteAccount -> i18n.DeleteAccount
    RevealPrivateKey -> i18n.ShowPrivateKey
  }
}

/// 操作のパスセグメント。
fn account_action_segment(action: AccountAction) -> String {
  case action {
    EditLabel -> "label"
    RotateSecret -> "rotate"
    DeleteAccount -> "delete"
    RevealPrivateKey -> "private-key"
  }
}

/// 操作のパス（`/accounts/<signer>/<segment>`）。
pub fn account_action_path(signer: String, action: AccountAction) -> String {
  view.segments_path([accounts_segment, signer, account_action_segment(action)])
}

/// パスセグメントから、アカウント 1 件への操作の署名者と操作を引く。操作のパスで
/// なければ Error。署名者の値は検査しない（一覧との照合は呼び出し側が行う）。
pub fn parse_account_action_path(
  segments: List(String),
) -> Result(#(String, AccountAction), Nil) {
  case segments {
    [first, signer, segment] if first == accounts_segment ->
      account_actions
      |> list.find(fn(action) { account_action_segment(action) == segment })
      |> result.map(fn(action) { #(signer, action) })
    _ -> Error(Nil)
  }
}

/// 操作の見出し（ダイアログの題）と、ダッシュボードのボタンの語。
fn relay_action_title(action: RelayAction) -> i18n.Message {
  case action {
    EditRelayRoles -> i18n.EditRelayRoles
    DeleteRelay -> i18n.DeleteRelay
  }
}

/// 操作のダイアログで送信に失敗したときの理由の前置き。
fn relay_action_lead(action: RelayAction) -> i18n.Lead {
  case action {
    EditRelayRoles -> i18n.CouldNotSaveRelay
    DeleteRelay -> i18n.CouldNotDeleteRelay
  }
}

/// 操作のパスセグメント。
fn relay_action_segment(action: RelayAction) -> String {
  case action {
    EditRelayRoles -> "edit"
    DeleteRelay -> "delete"
  }
}

/// 操作のパス（`/relays/<id>/<segment>`）。
pub fn relay_action_path(id: Int, action: RelayAction) -> String {
  view.segments_path([
    relays_segment,
    int.to_string(id),
    relay_action_segment(action),
  ])
}

/// パスセグメントから、リレー 1 件への操作の DB の行の id と操作を引く。id が整数として
/// 読めなければ Error。行との照合は呼び出し側が行う。
pub fn parse_relay_action_path(
  segments: List(String),
) -> Result(#(Int, RelayAction), Nil) {
  case segments {
    [first, id, segment] if first == relays_segment -> {
      use id <- result.try(int.parse(id))
      relay_actions
      |> list.find(fn(action) { relay_action_segment(action) == segment })
      |> result.map(fn(action) { #(id, action) })
    }
    _ -> Error(Nil)
  }
}

/// セッションの権限の保存のパスの末尾のセグメント。
pub const session_permissions_segment = "permissions"

/// セッションの権限の保存のパス（`/sessions/<signer>/<client>/permissions`）。
pub fn session_permissions_path(signer: String, client: String) -> String {
  view.segments_path([
    sessions_segment,
    signer,
    client,
    session_permissions_segment,
  ])
}

/// パスセグメントから、セッションの権限の保存のパスの署名者とクライアントを引く。値は
/// 検査しない（一覧との照合は呼び出し側が行う）。
pub fn parse_session_permissions_path(
  segments: List(String),
) -> Result(#(String, String), Nil) {
  case segments {
    [first, signer, client, last]
      if first == sessions_segment && last == session_permissions_segment
    -> Ok(#(signer, client))
    _ -> Error(Nil)
  }
}

/// プラグインのページのパス（`/plugins/<プラグイン名>/<ページのキー>`）。符号化しない
/// 素のパスで、`view.SwitchReturningTo` に渡す値。リンクの `href` には
/// `plugin_page_href` を使う。
pub fn plugin_page_path(plugin: String, page: String) -> String {
  view.segments_path([plugins_segment, plugin, page])
}

/// プラグインのページへのリンクのパス。`plugin_name/0` は任意の文字列でよく
/// `wisp.path_segments` は percent-decode しないため、プラグイン名だけを
/// percent-encode する（ページのキーは `[a-z0-9_-]+` に限られているので符号化
/// しない）。`return` には `plugin_page_path` を渡すこと。`admin.return_path`
/// が自分でセグメントを符号化するため、符号化済みの値を渡すと二重になる。
pub fn plugin_page_href(plugin: String, page: String) -> String {
  view.segments_path([plugins_segment, uri.percent_encode(plugin), page])
}

/// パスセグメントから、プラグインのページのプラグイン名とキーを引く。プラグイン名は
/// percent-decode し、失敗すれば `Error(Nil)`。一覧との照合は呼び出し側が行う。
pub fn parse_plugin_page_path(
  segments: List(String),
) -> Result(#(String, String), Nil) {
  case segments {
    [first, name, key] if first == plugins_segment -> {
      use name <- result.try(uri.percent_decode(name))
      Ok(#(name, key))
    }
    _ -> Error(Nil)
  }
}

/// 操作のダイアログを開くボタンの種類。編集は開くだけなので地味なボタン、削除は接続中のクライアントに
/// 影響するので error の文字色にする。
fn relay_action_button_kind(action: RelayAction) -> view.ButtonKind {
  case action {
    EditRelayRoles -> view.GhostButton
    DeleteRelay -> view.DangerGhostButton
  }
}

/// リレー 1 件への操作のアイコン。
fn relay_action_icon(action: RelayAction) -> Element(msg) {
  case action {
    EditRelayRoles -> view.pencil_icon()
    DeleteRelay -> view.trash_icon()
  }
}

/// 署名者の表示。アカウント一覧にある署名者はラベルと省略した npub を縦に、無い署名者は
/// 省略した 16 進の pubkey だけを出す。
pub fn signer_value(signer: SignerName) -> Element(msg) {
  case signer {
    KnownSigner(label:, npub:) ->
      html.div([attribute.class("flex flex-col gap-0.5")], [
        html.span([], [html.text(label)]),
        html.span(
          [attribute.class("font-mono text-xs"), attribute.title(npub)],
          [html.text(view.shorten(npub))],
        ),
      ])
    UnknownSigner(hex:) ->
      html.span([attribute.class("font-mono text-xs"), attribute.title(hex)], [
        html.text(view.shorten(hex)),
      ])
  }
}

/// secret の提示の区別のバッジ。不一致は警告色、提示なしは色を付けない。
fn secret_badge(language: Language, mismatch: Bool) -> Element(msg) {
  let text = i18n.text(language, _)
  case mismatch {
    True ->
      view.status_chip(
        view.SecretMismatchChip,
        text(i18n.PendingSecretMismatch),
      )
    False ->
      view.status_chip(
        view.SecretNotOfferedChip,
        text(i18n.PendingSecretNotOffered),
      )
  }
}

/// リレーの一覧。見出しの ⓘ で、監視とバンカーの語と説明の凡例（`role_hint`）を開く。
/// 1 件は `relays` の 1 行である。一覧を得たときは見出しの行に追加のダイアログを開くボタンを出す。バンカー
/// に使う行が無ければエラーの色の囲みを、一覧を得られないときは理由を出す。節の末尾には追加のダイアログを
/// 一覧の有無によらず描き、`dialog` が `NewRelayOpen` なら開いた状態で描く。
fn relays_section(
  language: Language,
  relays: Result(List(RelayRow), i18n.Reason),
  dialog: Option(OpenDialog),
) -> Element(msg) {
  let text = i18n.text(language, _)
  let #(opening, url, roles, error) = case dialog {
    Some(NewRelayOpen(url:, roles:, error:)) -> #(
      view.OpenedByResponse,
      url,
      roles,
      Some(error),
    )
    _ -> #(view.OpensOnTrigger, "", new_relay_roles, None)
  }
  view.section_block(relays_anchor, [
    listed_section_heading(
      language,
      relays,
      view.plug_icon(),
      i18n.Relays,
      view.info_hint(language, relays_anchor <> "-hint", role_hint(language)),
      [
        view.dialog_trigger(
          add_relay_dialog_id(),
          view.IconTextTrigger(view.plus_icon(), text(i18n.Add)),
          view.PrimaryButton,
        ),
      ],
      [],
    ),
    no_bunker_relay_alert(language, relays),
    listed_body(
      language,
      None,
      relays,
      i18n.CouldNotListRelays,
      element.none(),
      fn(rows) {
        view.row_list(list.map(rows, relay_item(language, _, dialog)))
      },
    ),
    view.dialog(
      language,
      add_relay_dialog_id(),
      text(i18n.AddRelay),
      fn(placement) {
        [
          view.error_message(language, Some(i18n.CouldNotAddRelay), error),
          ..new_relay_form(language, url, roles, placement)
        ]
      },
      i18n.Cancel,
      opening,
    ),
  ])
}

/// リレーの節の ⓘ で開く凡例。監視、バンカーの順に、太字の用途の語と説明を 1 段落ずつ並べる。
fn role_hint(language: Language) -> List(Element(msg)) {
  let text = i18n.text(language, _)
  let paragraph = fn(attributes, role, description) {
    html.p(attributes, [
      html.b([attribute.class("font-semibold")], [html.text(text(role))]),
      html.text(" "),
      html.text(text(description)),
    ])
  }
  [
    paragraph([], i18n.MonitorRole, i18n.MonitorRoleDescription),
    paragraph(
      [attribute.class("mt-1")],
      i18n.BunkerRole,
      i18n.BunkerRoleDescription,
    ),
  ]
}

/// 一覧を得て、バンカーに使う行が 1 件も無いときのエラーの色の囲み。クライアントがどの
/// アカウントにも接続できないことを伝える。リレーの節と接続 QR コードのダイアログで使う。
fn no_bunker_relay_alert(
  language: Language,
  relays: Result(List(RelayRow), i18n.Reason),
) -> Element(msg) {
  case relays {
    Ok(rows) ->
      case has_bunker_relay(rows) {
        True -> element.none()
        False ->
          view.alert(view.Failure, [
            html.text(i18n.text(language, i18n.NoBunkerRelay)),
          ])
      }
    Error(_) -> element.none()
  }
}

/// リレー 1 件。1 段目に URL と、操作（用途の編集、削除）のダイアログを開くアイコンだけのボタンを並べ、
/// 2 段目に用途のマス（`relay_role`）を監視、バンカーの順に 2 つ並べる。使っていない用途は「未使用」の
/// バッジで出す。`dialog` が同じ行と操作の `RelayActionOpen` なら、そのダイアログを開いた状態で描く。
fn relay_item(
  language: Language,
  row: RelayRow,
  dialog: Option(OpenDialog),
) -> Element(msg) {
  view.list_row(view.InlineRow, [
    html.p([attribute.class("min-w-0 flex-1 font-mono text-sm break-all")], [
      html.text(row.url),
    ]),
    button_row(
      list.flat_map(relay_actions, fn(action) {
        let title = i18n.text(language, relay_action_title(action))
        let id =
          view.dialog_id([
            "relay",
            int.to_string(row.id),
            relay_action_segment(action),
          ])
        let #(opening, roles, error) = case dialog {
          Some(RelayActionOpen(id:, action: opened, roles:, error:))
            if id == row.id && opened == action
          -> #(view.OpenedByResponse, roles, Some(error))
          _ -> #(view.OpensOnTrigger, None, None)
        }
        [
          view.dialog_trigger(
            id,
            view.IconOnlyTrigger(relay_action_icon(action), title),
            relay_action_button_kind(action),
          ),
          view.dialog(
            language,
            id,
            title,
            fn(placement) {
              [
                view.error_message(
                  language,
                  Some(relay_action_lead(action)),
                  error,
                ),
                view.summary_list([
                  #(i18n.text(language, i18n.RelayUrl), view.Code(row.url)),
                ]),
                ..relay_action_form(
                  language,
                  relay_store.Relay(
                    id: row.id,
                    url: row.url,
                    roles: row_roles(row),
                  ),
                  action,
                  roles,
                  Some(row),
                  placement,
                )
              ]
            },
            i18n.Cancel,
            opening,
          ),
        ]
      }),
    ),
    html.dl([attribute.class("grid basis-full grid-cols-2 gap-1.5")], [
      relay_role(language, view.eye_icon(), i18n.MonitorRole, row.monitor),
      relay_role(language, view.key_icon(), i18n.BunkerRole, row.bunker),
    ]),
  ])
}

/// リレーの追加のフォームの既定の用途。バンカーだけにチェックを入れる。閉じた状態で描く追加のダイアログが使う。
pub const new_relay_roles = Roles(monitor: False, bunker: True)

/// リレーの追加のダイアログの `id`。節の見出しのボタンと「はじめに」の段 1 のボタンが開く。
fn add_relay_dialog_id() -> String {
  view.dialog_id(["relay", "new"])
}

/// アカウントの追加のダイアログの `id`。節の見出しのボタンと「はじめに」の段 2 のボタンが開く。
fn add_account_dialog_id() -> String {
  view.dialog_id(["account", "new"])
}

/// URL の補足の `id`。URL の欄はダッシュボードの追加のダイアログにだけあり、
/// 1 つのページに 2 つ現れないので固定の値にする。
const relay_url_hint_id = "relay-url-hint"

/// 行の今の用途。`Unused` でない用途を使っているとみなす（`app.merge_relay_rows` は使っていない
/// 用途だけを `Unused` にする）。
fn row_roles(row: RelayRow) -> Roles {
  Roles(monitor: row.monitor != Unused, bunker: row.bunker != Unused)
}

/// リレーの追加のフォームの中身。説明の 1 行と、`/relays/new` へ POST するフォーム（URL の欄と
/// 用途のチェック）を並べる。ダイアログの枠と入力の誤りは含めない。`url` と `roles` は欄に出す値で、
/// 用途の接続状態のバッジは出さない。
pub fn new_relay_form(
  language: Language,
  url: String,
  roles: Roles,
  placement: view.Placement,
) -> List(Element(msg)) {
  let text = i18n.text(language, _)
  [
    view.form_description(text(i18n.AddRelayDescription)),
    view.post_form(
      view.segments_path(new_relay_segments),
      [url_field(language, url), roles_fieldset(language, roles, None)],
      text(i18n.Register),
      view.PrimaryButton,
      placement,
    ),
  ]
}

/// リレー 1 件への操作のフォームの中身。操作の説明の段落と、操作のパスへ POST するフォームを
/// 並べる。説明は結果の注意なので畳まない。用途の編集は `roles`（`None` なら保存済みの用途）の
/// チェックと `states` の接続状態のバッジを出し、削除は危険のボタンだけで `roles` と `states` を
/// 使わない。URL の要約と入力の誤りは含めない。
pub fn relay_action_form(
  language: Language,
  relay: Relay,
  action: RelayAction,
  roles: Option(Roles),
  states: Option(RelayRow),
  placement: view.Placement,
) -> List(Element(msg)) {
  let text = i18n.text(language, _)
  let path = relay_action_path(relay.id, action)
  case action {
    EditRelayRoles -> [
      html.p([], [html.text(text(i18n.EditRelayRolesDescription))]),
      view.post_form(
        path,
        [roles_fieldset(language, option.unwrap(roles, relay.roles), states)],
        text(i18n.Save),
        view.PrimaryButton,
        placement,
      ),
    ]
    DeleteRelay -> [
      html.p([], [html.text(text(i18n.DeleteRelayDescription))]),
      view.post_form(
        path,
        [],
        text(i18n.DeleteRelaySubmit),
        view.DangerButton,
        placement,
      ),
    ]
  }
}

/// リレーの URL の欄。
fn url_field(language: Language, url: String) -> Element(msg) {
  let text = i18n.text(language, _)
  view.hinted_input(
    language,
    text(i18n.RelayUrl),
    relay_url_hint_id,
    view.LineHint(text(i18n.RelayUrlHint)),
    [
      attribute.type_("text"),
      attribute.name(relay_url_field),
      attribute.required(True),
      attribute.autocomplete("off"),
      attribute.spellcheck(False),
      attribute.inputmode("url"),
      attribute.default_value(url),
      attribute.class("input w-full font-mono border-base-content/60"),
    ],
  )
}

/// 用途（監視・バンカー）のチェックの囲み。`states` はその用途の今の接続状態で、`None`
/// ならバッジを出さない。
fn roles_fieldset(
  language: Language,
  roles: Roles,
  states: Option(RelayRow),
) -> Element(msg) {
  let text = i18n.text(language, _)
  html.fieldset([attribute.class("fieldset")], [
    html.legend([attribute.class("fieldset-legend")], [
      html.text(text(i18n.Role)),
    ]),
    view.checkbox_row(
      monitor_field,
      view.eye_icon(),
      text(i18n.UseForMonitoring),
      html.text(text(i18n.MonitorRoleDescription)),
      roles.monitor,
      option.values([
        option.map(states, fn(row) { row.monitor })
        |> option.map(role_state_badge(language, _)),
      ]),
    ),
    view.checkbox_row(
      bunker_field,
      view.key_icon(),
      text(i18n.UseForBunker),
      html.text(text(i18n.BunkerRoleDescription)),
      roles.bunker,
      option.values([
        option.map(states, fn(row) { row.bunker })
        |> option.map(role_state_badge(language, _)),
      ]),
    ),
  ])
}

/// 用途 1 つのマス。`dt` にアイコンと用途の語、`dd` にその用途の状態のバッジを置き、幅が足りなければ
/// バッジを下へ回す。
fn relay_role(
  language: Language,
  icon: Element(msg),
  role: i18n.Message,
  state: RoleState,
) -> Element(msg) {
  html.div(
    [
      attribute.class(
        "flex flex-wrap items-center justify-between gap-x-2 gap-y-1 rounded-field bg-base-200 py-1.5 pr-1.5 pl-2.5",
      ),
    ],
    [
      html.dt(
        [attribute.class("flex items-center gap-1.5 text-sm text-muted")],
        [
          icon,
          html.text(i18n.text(language, role)),
        ],
      ),
      html.dd([], [role_state_badge(language, state)]),
    ],
  )
}

/// 用途 1 つぶんの接続状態のバッジ。ダッシュボードの行と、用途の編集のフォーム（ダイアログと
/// ページ）の用途のチェックが使う。
fn role_state_badge(language: Language, state: RoleState) -> Element(msg) {
  let text = i18n.text(language, _)
  case state {
    Reported(status) -> relay_status(language, status)
    Unanswered ->
      view.status_chip(view.UnansweredChip, text(i18n.PluginUnavailable))
    Unused -> view.status_chip(view.UnusedChip, text(i18n.RelayRoleUnused))
  }
}

/// 承認済みのセッションの節。見出しに説明を開く ⓘ と件数と、一覧を得たときだけ接続のダイアログを開く
/// 「クライアントを接続」を置き、行を並べる。一覧を得られないときは、一覧とボタンの代わりにその理由を出す。
/// 末尾に接続のダイアログと、開くときだけ確認のダイアログを置く。`dialog` は開いた状態で返すダイアログで、
/// 行の権限の編集のダイアログにも渡す。
fn sessions_section(
  language: Language,
  accounts: Result(List(AccountRow), i18n.Reason),
  now: Int,
  shared: Option(String),
  sessions: Result(List(SessionRow), i18n.Reason),
  dialog: Option(OpenDialog),
) -> Element(msg) {
  let text = i18n.text(language, _)
  let connect_trigger = fn(kind) {
    view.dialog_trigger(
      connect_dialog_id(),
      view.IconTextTrigger(view.plus_icon(), text(i18n.ConnectClient)),
      kind,
    )
  }
  view.section_block(sessions_anchor, [
    listed_section_heading(
      language,
      sessions,
      view.clock_icon(),
      i18n.ApprovedSessions,
      view.info_hint(language, sessions_anchor <> "-hint", [
        html.text(text(i18n.ApprovedSessionsDescription)),
      ]),
      [connect_trigger(view.PrimaryButton)],
      [],
    ),
    listed_body(
      language,
      shared,
      sessions,
      i18n.CouldNotListSessions,
      view.empty_state(view.clock_icon(), text(i18n.NoApprovedSessions), [
        connect_trigger(view.OutlineButton),
      ]),
      fn(rows) {
        view.row_list(
          list.map(rows, session_item(language, accounts, now, dialog, _)),
        )
      },
    ),
    connect_dialog(language, accounts, dialog),
    connect_review_dialog(language, accounts, dialog),
  ])
}

/// 接続のダイアログの `id`。見出しと空の状態のボタンが同じ `id` を指す。
fn connect_dialog_id() -> String {
  view.dialog_id(["session", "connect"])
}

/// 接続のダイアログ。セッションの一覧を得られたかどうかに関わらず 1 回だけ描く。`dialog` が
/// `ConnectOpen` なら開いた状態で、先頭に理由を、欄に送られた値を出す。それ以外は閉じた状態で
/// 空の欄を出す。
fn connect_dialog(
  language: Language,
  accounts: Result(List(AccountRow), i18n.Reason),
  dialog: Option(OpenDialog),
) -> Element(msg) {
  let #(opening, uri, signer, error) = case dialog {
    Some(ConnectOpen(uri:, signer:, error:)) -> #(
      view.OpenedByResponse,
      uri,
      signer,
      error,
    )
    _ -> #(view.OpensOnTrigger, "", "", None)
  }
  view.dialog(
    language,
    connect_dialog_id(),
    i18n.text(language, i18n.ConnectClient),
    fn(placement) {
      [
        view.error_message(language, Some(i18n.CouldNotStartConnection), error),
        ..connect_content(language, accounts, uri, signer, placement)
      ]
    },
    i18n.Cancel,
    opening,
  )
}

/// 接続の確認のダイアログ。`dialog` が `ConnectReviewOpen` のときだけ開いた状態で描き、
/// それ以外は何も描かない。先頭の理由、説明、URI を解釈した一覧、接続の意味の説明、
/// `/sessions/connect/confirm` へ送る「接続する」のフォーム、待ちの補足を並べる。
fn connect_review_dialog(
  language: Language,
  accounts: Result(List(AccountRow), i18n.Reason),
  dialog: Option(OpenDialog),
) -> Element(msg) {
  let text = i18n.text(language, _)
  case dialog {
    Some(ConnectReviewOpen(review:, error:)) ->
      view.dialog(
        language,
        view.dialog_id(["session", "connect", "review"]),
        text(i18n.ConfirmConnection),
        fn(placement) {
          [
            view.error_message(
              language,
              Some(i18n.CouldNotStartConnection),
              error,
            ),
            view.form_description(text(i18n.ConnectConfirmDescription)),
            review_list(language, accounts, review),
            connect_explanation(language, review.perms),
            view.post_form(
              view.segments_path(connect_confirm_segments),
              [
                view.hidden_input(nostrconnect_uri_field, review.uri),
                view.hidden_input(signer_field, review.signer),
              ],
              text(i18n.Connect),
              view.PrimaryButton,
              placement,
            ),
            view.hint(
              text(i18n.ConnectWaitHint(seconds: nostrconnect_wait_seconds)),
            ),
          ]
        },
        i18n.Cancel,
        view.OpenedByResponse,
      )
    _ -> element.none()
  }
}

/// 確認のダイアログの一覧。名乗る名前（無ければ行ごと省く）、クライアント、署名者、権限、URI の
/// リレーの順に並べる。
fn review_list(
  language: Language,
  accounts: Result(List(AccountRow), i18n.Reason),
  review: ConnectReview,
) -> Element(msg) {
  let text = i18n.text(language, _)
  let name_entry = case review.client_name {
    Some(name) -> [#(text(i18n.ClientName), view.value_cell(view.Plain(name)))]
    None -> []
  }
  view.detail_list(
    list.append(name_entry, [
      #(
        text(i18n.Client),
        view.identifier_cell(language, review.client, text(i18n.CopyClient)),
      ),
      #(
        text(i18n.Signer),
        html.dd([], [signer_value(signer_name(accounts, review.signer))]),
      ),
      #(
        text(i18n.Permissions),
        html.dd([], [permission_view.chips(language, review.perms)]),
      ),
      #(text(i18n.UriRelays), html.dd([], [view.code_list(review.relays)])),
    ]),
  )
}

/// 接続の意味の説明。権限が空のときは、許す操作の一文を続ける。URI のリレーに届く
/// 情報を末尾に書く。
fn connect_explanation(language: Language, perms: String) -> Element(msg) {
  let text = i18n.text(language, _)
  let permissions = case perms {
    "" -> [i18n.NoPermissionsRequested]
    _ -> []
  }
  let sentences =
    [i18n.ConnectExplanation, ..permissions]
    |> list.append([i18n.ConnectRelaysScope])
    |> list.map(text)
  view.alert(view.Info, [
    html.text(string.join(sentences, i18n.sentence_gap(language))),
  ])
}

/// 承認済みセッション 1 件。広い画面では、クライアントの公開鍵（指紋、省略、コピー）、署名者、最終利用を
/// 1 段目に、権限のチップと操作（`session_actions`）を 2 段目に並べる。幅 720px 以下では、クライアント、
/// 署名者と最終利用、権限のチップ、ボタンの 4 段に組み替える。`dialog` は `session_actions` に渡す。
fn session_item(
  language: Language,
  accounts: Result(List(AccountRow), i18n.Reason),
  now: Int,
  dialog: Option(OpenDialog),
  session: SessionRow,
) -> Element(msg) {
  let text = i18n.text(language, _)
  view.list_row(view.StackedRow, [
    html.div(
      [
        attribute.class(
          "grid grid-cols-[minmax(0,1fr)_auto] items-center gap-x-4 gap-y-2 min-[721px]:grid-cols-[auto_minmax(0,1fr)_auto]",
        ),
      ],
      [
        html.div(
          [attribute.class("col-span-2 min-w-0 min-[721px]:col-span-1")],
          [
            client_pubkey_line(language, session.client),
          ],
        ),
        html.div([attribute.class("min-w-0 text-sm")], [
          html.span([attribute.class("sr-only")], [html.text(text(i18n.Signer))]),
          signer_value(signer_name(accounts, session.signer)),
        ]),
        last_used_value(language, now, session),
        html.div([attribute.class("col-span-2")], [
          permission_view.chips(language, session.perms),
        ]),
        html.div(
          [
            attribute.class(
              "col-span-2 grid justify-items-end gap-1 border-t border-dashed border-base-300 pt-2 min-[721px]:col-span-1 min-[721px]:self-start min-[721px]:border-t-0 min-[721px]:pt-0",
            ),
          ],
          session_actions(language, accounts, dialog, session),
        ),
      ],
    ),
  ])
}

/// クライアントの公開鍵。鍵の指紋と、省略した表示とコピーのボタンを並べる。16 進の公開鍵でなければ指紋を
/// 出さない。承認待ちのカードと承認済みのセッションの行が使う。
fn client_pubkey_line(language: Language, client: String) -> Element(msg) {
  html.div([attribute.class("flex min-w-0 items-center gap-2")], [
    fingerprint.pubkey_svg(client, fingerprint.Colored, "size-6"),
    view.truncated_id(language, client, i18n.text(language, i18n.CopyClient)),
  ])
}

/// 最終利用の相対時刻（「最終利用 3 分前」の形）。時計のアイコンを前に置き、`title` に最終利用と作成の
/// UTC の全文を出す。
fn last_used_value(
  language: Language,
  now: Int,
  session: SessionRow,
) -> Element(msg) {
  let text = i18n.text(language, _)
  html.span(
    [
      attribute.class(
        "inline-flex items-center gap-1.5 justify-self-end whitespace-nowrap text-sm text-muted",
      ),
      attribute.title(session_time_title(language, session)),
    ],
    [
      view.clock_icon(),
      html.text(
        text(i18n.LastUsed)
        <> " "
        <> text(view.relative_time(now, session.last_used_at)),
      ),
    ],
  )
}

/// 承認済みセッション 1 件の操作。権限の編集と承認の取り消しのダイアログを開くボタンとそのダイアログを
/// 1 行に並べる。権限の編集のダイアログは、`dialog` がこの行の `PermissionsOpen` なら送られた欄の状態と
/// 先頭の理由で開いた状態で描き、それ以外はそのセッションの今の権限を入れて閉じた状態で描く。取り消しは
/// 確認のダイアログの中のボタンでだけ POST する。
fn session_actions(
  language: Language,
  accounts: Result(List(AccountRow), i18n.Reason),
  dialog: Option(OpenDialog),
  session: SessionRow,
) -> List(Element(msg)) {
  let text = i18n.text(language, _)
  let summary = session_dialog_summary(language, accounts, session)
  let permissions_id = session_dialog_id(session, session_permissions_segment)
  let #(opening, form, error) = case dialog {
    Some(PermissionsOpen(signer:, client:, form:, error:))
      if signer == session.signer && client == session.client
    -> #(view.OpenedByResponse, Some(form), Some(error))
    _ -> #(view.OpensOnTrigger, None, None)
  }
  [
    html.div(
      [attribute.class("flex flex-wrap justify-end gap-2")],
      list.append(
        [
          view.dialog_trigger(
            permissions_id,
            view.IconTextTrigger(view.pencil_icon(), text(i18n.EditPermissions)),
            view.GhostButton,
          ),
          view.dialog(
            language,
            permissions_id,
            text(i18n.EditPermissions),
            fn(placement) {
              [
                view.error_message(
                  language,
                  Some(i18n.CouldNotSavePermissions),
                  error,
                ),
                summary,
                ..permissions_form(language, session, form, placement)
              ]
            },
            i18n.Cancel,
            opening,
          ),
        ],
        view.dialog_button(
          language,
          session_dialog_id(session, revoke_segment),
          view.TextTrigger(text(i18n.Revoke)),
          view.GhostButton,
          text(i18n.Revoke),
          fn(placement) {
            [summary, ..revoke_form(language, session, placement)]
          },
        ),
      ),
    ),
  ]
}

/// セッションの行のダイアログの `id`。署名者とクライアントの 16 進の公開鍵と操作の語から作る。
fn session_dialog_id(session: SessionRow, action: String) -> String {
  view.dialog_id(["session", session.signer, session.client, action])
}

/// セッションのダイアログの題の下に出す要約。クライアントの公開鍵の全文と署名者を並べる。権限のチップは
/// 行に出ているので繰り返さない。
fn session_dialog_summary(
  language: Language,
  accounts: Result(List(AccountRow), i18n.Reason),
  session: SessionRow,
) -> Element(msg) {
  let text = i18n.text(language, _)
  view.detail_list([
    #(text(i18n.Client), view.value_cell(view.Code(session.client))),
    #(
      text(i18n.Signer),
      html.dd([], [signer_value(signer_name(accounts, session.signer))]),
    ),
  ])
}

/// 最終利用の `title` に出す、UTC の全文と作成時刻。
fn session_time_title(language: Language, session: SessionRow) -> String {
  let text = i18n.text(language, _)
  text(i18n.LastUsed)
  <> ": "
  <> view.utc_time(session.last_used_at)
  <> " · "
  <> text(i18n.Created)
  <> ": "
  <> view.utc_time(session.created_at)
}

/// 権限の編集フォームの欄の状態。`kinds` と `other` は欄に出す文字列そのままで、
/// 検証していない値も持つ。
pub type PermissionsForm {
  PermissionsForm(
    sign_event: Bool,
    nip44_encrypt: Bool,
    nip44_decrypt: Bool,
    kinds: String,
    other: String,
  )
}

/// `perms` を 3 つのチェック、kind の一覧、そのほかの宣言に分けたもの。
/// `form_of_perms` の途中の形で、最後に `PermissionsForm` へまとめる。
type ParsedPerms {
  ParsedPerms(
    sign_event: Bool,
    nip44_encrypt: Bool,
    nip44_decrypt: Bool,
    kinds: List(String),
    other: List(String),
  )
}

/// 権限の編集フォームの中身。説明の 1 行と、セッションの権限のパスへ POST するフォームを
/// 並べる。要約と入力の誤りは含めない。`form` は描き直すときに送られた欄の状態で、
/// `None` なら `session` の保存済みの値（`form_of_perms(session.perms)`）を使う。kind の欄の
/// 補足の `id` は行のダイアログの `id` から作り、1 つのページで重ならないようにする。
pub fn permissions_form(
  language: Language,
  session: SessionRow,
  form: Option(PermissionsForm),
  placement: view.Placement,
) -> List(Element(msg)) {
  let fields = option.unwrap(form, form_of_perms(session.perms))
  let kinds_hint_id =
    session_dialog_id(session, session_permissions_segment) <> "-kinds-hint"
  [
    view.form_description(i18n.text(language, i18n.EditPermissionsDescription)),
    view.post_form(
      session_permissions_path(session.signer, session.client),
      permissions_fields(language, fields, kinds_hint_id),
      i18n.text(language, i18n.Save),
      view.PrimaryButton,
      placement,
    ),
  ]
}

/// 権限の編集フォームの欄。3 つのチェック、kind 24133 を拒否する注意の 1 行、ⓘ で補足（`id` は
/// `kinds_hint_id`）を開く kind の欄、あればそのほかの宣言のチップと隠し欄。
fn permissions_fields(
  language: Language,
  fields: PermissionsForm,
  kinds_hint_id: String,
) -> List(Element(msg)) {
  let text = i18n.text(language, _)
  [
    html.fieldset([attribute.class("fieldset")], [
      view.checkbox_row(
        sign_event_field,
        view.pencil_icon(),
        text(i18n.AllowSignEvent),
        view.untranslated(sign_event_field),
        fields.sign_event,
        [],
      ),
      html.p([attribute.class("text-sm text-muted")], [
        html.text(text(i18n.SignEventAlwaysRefused)),
      ]),
      view.checkbox_row(
        nip44_encrypt_field,
        view.key_icon(),
        text(i18n.AllowNip44Encrypt),
        view.untranslated(nip44_encrypt_field),
        fields.nip44_encrypt,
        [],
      ),
      view.checkbox_row(
        nip44_decrypt_field,
        view.key_icon(),
        text(i18n.AllowNip44Decrypt),
        view.untranslated(nip44_decrypt_field),
        fields.nip44_decrypt,
        [],
      ),
    ]),
    view.hinted_input(
      language,
      text(i18n.AllowedKinds),
      kinds_hint_id,
      view.FoldedHint(text(i18n.AllowedKindsHint)),
      [
        attribute.name(perms_kinds_field),
        attribute.inputmode("numeric"),
        attribute.default_value(fields.kinds),
        attribute.class("input w-full font-mono border-base-content/60"),
        attribute.maxlength(512),
      ],
    ),
    ..other_declarations(language, fields.other)
  ]
}

/// 「そのほかの宣言」がある場合だけ、読み取り専用のチップと 1 行の補足、送信のための隠し欄を
/// 出す。無ければ何も出さない。
fn other_declarations(language: Language, other: String) -> List(Element(msg)) {
  case other {
    "" -> []
    _ -> [
      html.div([attribute.class("flex flex-col gap-1")], [
        html.span([], [html.text(i18n.text(language, i18n.OtherPermissions))]),
        permission_view.chips(language, other),
        view.hint(i18n.text(language, i18n.OtherPermissionsHint)),
      ]),
      view.hidden_input(perms_other_field, other),
    ]
  }
}

/// 保存済みの `perms` を欄の状態に写す。3 つの語はチェック、`sign_event:<n>` は
/// kind の欄、それ以外は「そのほかの宣言」に落とし、空の `perms` は 3 つのチェック
/// を入れる。
fn form_of_perms(perms: String) -> PermissionsForm {
  let parsed = case perms {
    "" ->
      ParsedPerms(
        sign_event: True,
        nip44_encrypt: True,
        nip44_decrypt: True,
        kinds: [],
        other: [],
      )
    _ ->
      string.split(perms, ",")
      |> list.fold(
        ParsedPerms(
          sign_event: False,
          nip44_encrypt: False,
          nip44_decrypt: False,
          kinds: [],
          other: [],
        ),
        fold_token,
      )
      |> reverse_lists
  }
  PermissionsForm(
    sign_event: parsed.sign_event,
    nip44_encrypt: parsed.nip44_encrypt,
    nip44_decrypt: parsed.nip44_decrypt,
    kinds: string.join(parsed.kinds, ","),
    other: string.join(parsed.other, ","),
  )
}

/// `form_of_perms` の 1 トークンぶんの畳み込み。
fn fold_token(acc: ParsedPerms, token: String) -> ParsedPerms {
  case token {
    "sign_event" -> ParsedPerms(..acc, sign_event: True)
    "nip44_encrypt" -> ParsedPerms(..acc, nip44_encrypt: True)
    "nip44_decrypt" -> ParsedPerms(..acc, nip44_decrypt: True)
    _ ->
      case permission_view.signed_kind(token) {
        Ok(kind) ->
          ParsedPerms(..acc, kinds: [int.to_string(kind), ..acc.kinds])
        Error(Nil) -> ParsedPerms(..acc, other: [token, ..acc.other])
      }
  }
}

/// `fold_token` が先頭に積んだ `kinds` と `other` を入力の順に戻す。
fn reverse_lists(parsed: ParsedPerms) -> ParsedPerms {
  ParsedPerms(
    ..parsed,
    kinds: list.reverse(parsed.kinds),
    other: list.reverse(parsed.other),
  )
}

/// URI の補足の `id`。URI の欄はダッシュボードの接続のダイアログに 1 つだけなので固定の値にする。
const nostrconnect_uri_hint_id = "nostrconnect-uri-hint"

/// ダッシュボードの接続のダイアログの中身。アカウントの一覧が
/// 空なら登録への案内、得られなければ理由の囲みを、得られればフォームの中身（`connect_form`）を出す。
/// `uri` と `signer` は `connect_form` に渡す値である。
pub fn connect_content(
  language: Language,
  accounts: Result(List(AccountRow), i18n.Reason),
  uri: String,
  signer: String,
  placement: view.Placement,
) -> List(Element(msg)) {
  let text = i18n.text(language, _)
  case accounts {
    Ok([]) -> [
      view.hint(text(i18n.NoAccountsForConnect)),
      ..view.dialog_actions(placement, [])
    ]
    Ok(rows) -> connect_form(language, rows, uri, signer, placement)
    Error(reason) -> [
      view.alert(
        view.Neutral,
        view.reason_content(language, Some(i18n.CouldNotListAccounts), reason),
      ),
      ..view.dialog_actions(placement, [])
    ]
  }
}

/// 接続のフォームの中身。説明の 1 行と、`/sessions/connect` へ POST するフォーム（URI の欄と
/// 署名するアカウントの選択欄）を並べる。入力の誤りは含めない。`uri` と `signer` は
/// 描き直すときに送られた値で、`signer` が空文字列なら `accounts` の先頭を選ぶ。
pub fn connect_form(
  language: Language,
  accounts: List(AccountRow),
  uri: String,
  signer: String,
  placement: view.Placement,
) -> List(Element(msg)) {
  let text = i18n.text(language, _)
  [
    view.form_description(text(i18n.ConnectClientDescription)),
    view.post_form(
      view.segments_path(connect_segments),
      [
        uri_field(language, uri),
        signing_account_select(language, accounts, signer),
      ],
      text(i18n.ReviewConnection),
      view.PrimaryButton,
      placement,
    ),
  ]
}

/// URI の欄。
fn uri_field(language: Language, uri: String) -> Element(msg) {
  let text = i18n.text(language, _)
  view.hinted_textarea(
    language,
    text(i18n.NostrconnectUri),
    nostrconnect_uri_hint_id,
    view.LineHint(text(i18n.NostrconnectUriHint)),
    uri,
    [
      attribute.name(nostrconnect_uri_field),
      attribute.required(True),
      attribute.autocomplete("off"),
      attribute.spellcheck(False),
      attribute.autocapitalize("off"),
      attribute.rows(4),
      attribute.class(
        "textarea w-full font-mono text-xs border-base-content/60",
      ),
    ],
  )
}

/// 署名するアカウントの選択欄。`rows` の順に並べ、`selected` が空文字列なら先頭を
/// 選ぶ。表示はラベルと省略した npub を並べる。
fn signing_account_select(
  language: Language,
  rows: List(AccountRow),
  selected: String,
) -> Element(msg) {
  let selected = case selected, list.first(rows) {
    "", Ok(first) -> first.signer
    _, _ -> selected
  }
  view.select_field(
    i18n.text(language, i18n.SigningAccount),
    signer_field,
    list.map(rows, fn(row) {
      #(row.signer, row.label <> " " <> view.shorten(row.npub))
    }),
    selected,
  )
}

/// 監視イベントを処理するプラグインと、その現在の状態。見出しに件数（1 件以上のとき）を
/// 置き、プラグインを行の一覧で並べる。起動時に読み込めなかった候補があれば、節の末尾にエラーの色の枠で出す。
fn plugins_section(
  language: Language,
  plugins: List(PluginRow),
  not_loaded: List(plugin_loader.NotLoaded),
) -> Element(msg) {
  let text = i18n.text(language, _)
  view.section_block(plugins_anchor, [
    listed_section_heading(
      language,
      Ok(plugins),
      view.puzzle_icon(),
      i18n.Plugins,
      [],
      [],
      [],
    ),
    section_body(
      plugins,
      view.empty_state(view.puzzle_icon(), text(i18n.NoPlugins), []),
      fn(rows) { view.row_list(list.map(rows, plugin_item(language, _))) },
    ),
    not_loaded_panel(language, not_loaded),
  ])
}

/// プラグイン 1 件。名前と状態のチップ（破棄の件数、無効の理由）を縦に並べ、ページを開くリンクと
/// 再有効化のフォームを右に置く。幅が足りなければ操作は下の段に回る。
fn plugin_item(language: Language, plugin: PluginRow) -> Element(msg) {
  let actions = case
    list.append(
      plugin_page_link(language, plugin),
      reenable_form_if_disabled(language, plugin),
    )
  {
    [] -> element.none()
    buttons -> button_row(buttons)
  }
  view.list_row(view.InlineRow, [
    html.div([attribute.class("flex min-w-0 flex-col items-start gap-1")], [
      html.span([attribute.class("font-semibold break-words")], [
        html.text(plugin.name),
      ]),
      plugin_state(language, plugin),
    ]),
    actions,
  ])
}

/// 起動時に読み込めなかったプラグインの枠。1 件以上あるときだけ、題と警告の 1 文と行の一覧を
/// エラーの色の枠（`view.failure_frame`）に入れる。`app.Spec` から届く一覧で、起動時に確定するので
/// 取得できない状態は無い。
fn not_loaded_panel(
  language: Language,
  rows: List(plugin_loader.NotLoaded),
) -> Element(msg) {
  case rows {
    [] -> element.none()
    rows ->
      view.failure_frame(
        view.warning_triangle_icon(),
        i18n.text(language, i18n.NotLoadedPlugins),
        list.length(rows),
        i18n.text(language, i18n.NotLoadedPluginsWarning),
        list.map(rows, not_loaded_item(language, _)),
      )
  }
}

/// 読み込めなかった候補 1 件。「読み込み失敗」のチップ、識別子、理由を縦に並べる。識別子と
/// 理由はローダーとプラグイン由来の英語なので訳さない。識別子は原因に辿り着く唯一の手掛かり
/// なので、長くても切らずに折り返して全文を出す。
fn not_loaded_item(
  language: Language,
  row: plugin_loader.NotLoaded,
) -> Element(msg) {
  view.list_row(view.InlineRow, [
    html.div([attribute.class("flex min-w-0 flex-col items-start gap-1")], [
      view.status_chip(
        view.LoadFailedChip,
        i18n.text(language, i18n.PluginLoadFailed),
      ),
      html.p([attribute.class("font-mono text-sm break-all")], [
        view.untranslated(row.id),
      ]),
      html.p([attribute.class("text-sm break-words")], [
        view.untranslated(row.reason),
      ]),
    ]),
  ])
}

/// 節の本文。行が無いときは `render` の代わりに `empty` を出す。
fn section_body(
  rows: List(a),
  empty: Element(msg),
  render: fn(List(a)) -> Element(msg),
) -> Element(msg) {
  case rows {
    [] -> empty
    rows -> render(rows)
  }
}

/// 行のボタンの並び。
fn button_row(buttons: List(Element(msg))) -> Element(msg) {
  html.div([attribute.class("flex shrink-0 flex-wrap gap-2")], buttons)
}

/// 承認ページのパス。`auth_url` としてクライアントへ渡す URL も、このパスに
/// 公開 URL を前置して組み立てる。
pub fn approve_path(token: String) -> String {
  view.segments_path([approve_segment, token])
}

/// 拒否のパス。承認ページと違い、POST でしか使わない。
fn deny_path(token: String) -> String {
  view.segments_path([deny_segment, token])
}

/// 承認待ち 1 件への承認・拒否フォーム。どちらも状態を変えるので POST で送り、承認、拒否の順に並べる。
/// secret が一致しないときは拒否を塗りのボタンにし、承認を warning の枠の「それでも承認する」にする。
/// 一致しないとき以外は承認が主な操作で、拒否してもクライアントは接続し直せるので拒否を地味なボタンにする。
fn decision_forms(
  language: Language,
  token: String,
  secret_mismatch: Bool,
) -> List(Element(msg)) {
  let text = i18n.text(language, _)
  let #(approve, approve_kind, deny_kind) = case secret_mismatch {
    True -> #(i18n.ApproveAnyway, view.WarningOutlineButton, view.PrimaryButton)
    False -> #(i18n.Approve, view.PrimaryButton, view.GhostButton)
  }
  [
    view.post_form(
      approve_path(token),
      [],
      text(approve),
      approve_kind,
      view.InRow,
    ),
    view.post_form(deny_path(token), [], text(i18n.Deny), deny_kind, view.InRow),
  ]
}

/// セッションを 1 件取り消すフォームの中身。取り消しの結果の説明と、`/sessions/revoke` へ POST するフォームを
/// 並べ、確認のダイアログの中にだけ置く。取り消しは接続中のクライアントに影響するので warning の枠のボタンにする。
fn revoke_form(
  language: Language,
  session: SessionRow,
  placement: view.Placement,
) -> List(Element(msg)) {
  let text = i18n.text(language, _)
  [
    view.form_description(text(i18n.RevokeSessionDescription)),
    view.post_form(
      view.segments_path(revoke_segments),
      [
        view.hidden_input(signer_field, session.signer),
        view.hidden_input(client_field, session.client),
      ],
      text(i18n.Revoke),
      view.WarningOutlineButton,
      placement,
    ),
  ]
}

/// 無効になったプラグイン 1 つの再有効化フォーム。イベント処理を再開させ、失敗が
/// 続けばまた無効になる。取り返しの付く操作なので地味なボタンにする。
fn reenable_form(language: Language, name: String) -> Element(msg) {
  view.post_form(
    view.segments_path(reenable_plugin_segments),
    [view.hidden_input(plugin_name_field, name)],
    i18n.text(language, i18n.ReenablePlugin),
    view.GhostButton,
    view.InRow,
  )
}

/// DB からの読み直しのフォーム。読み直しはメモリから DB に無いアカウントを取り除き、
/// セッションと承認待ちも置き換えるが、DB の内容は変えずやり直せるので地味なボタンにする。
fn reload_form(language: Language) -> Element(msg) {
  view.post_form(
    view.segments_path(reload_accounts_segments),
    [],
    i18n.text(language, i18n.ReloadAccounts),
    view.GhostButton,
    view.InRow,
  )
}

/// リレーの接続状態のバッジ。
fn relay_status(language: Language, status: Status) -> Element(msg) {
  let chip = case status {
    Connected -> view.ActiveChip
    Disconnected -> view.DisconnectedChip
  }
  view.status_chip(chip, i18n.text(language, status_label(status)))
}

/// プラグインの状態。バッジと、あれば詳細を縦に並べる。応答が無いのは再起動中か応答待ちの
/// 一時的な状態だが、イベントを処理できていないので警告の色にする。
pub fn plugin_state(language: Language, plugin: PluginRow) -> Element(msg) {
  let chip = case plugin.status {
    None -> view.UnansweredChip
    Some(plugin_runner.Running) -> view.ActiveChip
    Some(plugin_runner.Overloaded(..)) -> view.OverloadedChip
    Some(plugin_runner.Disabled(..)) -> view.DisabledChip
  }
  let #(word, detail) = plugin_state_label(language, plugin.status)
  let badge = view.status_chip(chip, word)
  case detail {
    None -> badge
    Some(detail) ->
      html.div([attribute.class("flex flex-col items-start gap-1")], [
        badge,
        html.span([attribute.class("text-xs break-words")], detail),
      ])
  }
}

/// ページを供給するプラグインへのリンクを 1 要素のリストで返す。`pages` の先頭のページを
/// 指す。供給が無ければ空。
fn plugin_page_link(
  language: Language,
  plugin: PluginRow,
) -> List(Element(msg)) {
  case plugin.pages {
    [first, ..] -> [
      view.icon_button_link(
        plugin_page_href(plugin.name, first.key),
        view.file_text_icon(),
        i18n.text(language, i18n.OpenPluginPage),
        view.GhostButton,
      ),
    ]
    [] -> []
  }
}

/// `Disabled` のときだけ再有効化のフォームを 1 要素のリストで返す。それ以外は空。
fn reenable_form_if_disabled(
  language: Language,
  plugin: PluginRow,
) -> List(Element(msg)) {
  case plugin.status {
    Some(plugin_runner.Disabled(..)) -> [reenable_form(language, plugin.name)]
    _ -> []
  }
}

/// プラグインの状態の語と、あれば詳細。`Disabled` の理由はプラグイン由来の英語の文字列
/// なので、訳さずにテキストとして描画する（長さは `plugin_runner` 側で切ってあるので、
/// ここでは切らない）。
fn plugin_state_label(
  language: Language,
  status: Option(plugin_runner.Status),
) -> #(String, Option(List(Element(msg)))) {
  let text = i18n.text(language, _)
  case status {
    None -> #(text(i18n.PluginUnavailable), None)
    Some(plugin_runner.Running) -> #(text(i18n.PluginRunning), None)
    Some(plugin_runner.Overloaded(dropped:)) -> #(
      text(i18n.PluginOverloaded),
      Some([html.text(text(i18n.Dropped(dropped)))]),
    )
    Some(plugin_runner.Disabled(reason:, dropped:)) -> #(
      text(i18n.PluginDisabled),
      Some([
        view.untranslated(reason),
        html.text(i18n.sentence_gap(language) <> text(i18n.Dropped(dropped))),
      ]),
    )
  }
}

/// 接続状態の表示名。
fn status_label(status: Status) -> i18n.Message {
  case status {
    Connected -> i18n.RelayConnected
    Disconnected -> i18n.RelayDisconnected
  }
}
