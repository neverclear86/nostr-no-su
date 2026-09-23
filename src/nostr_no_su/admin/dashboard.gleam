//// 管理 UI のダッシュボード、承認ページ、通知ページの描画と、表示する状態の型、パスと
//// フォームの欄の名前の定義。描画は状態のスナップショット（純粋なデータ）から HTML
//// 文字列を組み立てるだけで、プロセスにも IO にも触れない。
////
//// 埋め込む値はすべてユーザー由来になりうる（リレー URL、クライアント pubkey、
//// アカウントのラベル、表示する理由）ため、テキストか属性値として lustre に渡し、
//// エスケープを文字列化に任せる（`admin/view` の規則に従う）。文言は `admin/i18n` から
//// 表示の言語で引き、文字列リテラルで書かない（同じく `admin/view` の規則）。
////
//// パスとフォームの欄の名前は、ルーティング（`admin`）とフォーム（ここと
//// `admin/account_pages`、`admin/relay_pages`、`admin/connect_pages`、
//// `admin/session_pages`）が同じ定義を見るようここに置く。
//// ページ枠が使う定義
//// （スタイルシートとテーマと言語の切り替えのパスセグメント、切り替えの欄の名前）と、
//// パスセグメントからパスを組み立てる `segments_path` は `admin/view` に置く。

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/calendar
import gleam/time/timestamp
import gleam/uri
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import nostr_no_su/admin/i18n.{type Language}
import nostr_no_su/admin/permission_view
import nostr_no_su/admin/view
import nostr_no_su/bunker/engine
import nostr_no_su/bunker/vault
import nostr_no_su/plugin
import nostr_no_su/plugin_loader
import nostr_no_su/plugin_runner
import nostr_no_su/relay_connection.{type Status, Connected, Disconnected}

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

/// アカウント 1 件の表示内容。`uri` は secret を含むため、認証済みページ以外に
/// 出してはならない。`auth_uri` は secret を持たない URI で、これで接続した
/// クライアントは管理 UI での承認を経てから署名を委任できる。`npub` は画面で
/// アカウントを識別するための表記。
pub type AccountRow {
  AccountRow(
    signer: String,
    npub: String,
    label: String,
    uri: String,
    auth_uri: String,
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

/// 承認待ちの行と承認ページに出す署名者の表示。アカウント一覧と突き合わせられればラベルと
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
    /// 締め切り超過）はカードごと描かない。
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
    /// 起動時に読み込めなかったプラグインの一覧。0 件ならカードごと描かない。
    not_loaded_plugins: List(plugin_loader.NotLoaded),
    /// 描画時点の Unix 秒。セッションの最終利用を相対で出すために使う。
    now: Int,
  )
}

/// アカウント 1 件に対する操作。
pub type AccountAction {
  EditLabel
  RotateSecret
  DeleteAccount
  RevealPrivateKey
  ShowConnectionQr
}

/// 操作の一覧。ダッシュボードのリンクはこの順（重さの軽い順）に並べ、セグメントとの
/// 対応もここから引く。
const account_actions = [
  ShowConnectionQr,
  EditLabel,
  RevealPrivateKey,
  RotateSecret,
  DeleteAccount,
]

/// リレー 1 件に対する操作。
pub type RelayAction {
  EditRelayRoles
  DeleteRelay
}

/// 操作の一覧。ダッシュボードのリンクはこの順に並べ、セグメントとの対応もここから引く。
const relay_actions = [EditRelayRoles, DeleteRelay]

/// アカウントのページのパスの先頭のセグメント。
const accounts_segment = "accounts"

/// リレーのページのパスの先頭のセグメント。
const relays_segment = "relays"

/// プラグインのページのパスの先頭のセグメント。
const plugins_segment = "plugins"

/// 承認ページのパスの先頭のセグメント。
pub const approve_segment = "approve"

/// 拒否のパスの先頭のセグメント。
pub const deny_segment = "deny"

/// アカウントの登録画面のパスセグメント。
pub const new_account_segments = [accounts_segment, "new"]

/// アカウントの読み直しの POST 先のパスセグメント。
pub const reload_accounts_segments = [accounts_segment, "reload"]

/// リレーの追加画面のパスセグメント。
pub const new_relay_segments = [relays_segment, "new"]

/// 鍵の生成の POST 先のパスセグメント。
pub const generate_account_segments = [accounts_segment, "generate"]

/// nsec による登録の POST 先のパスセグメント。
pub const import_account_segments = [accounts_segment, "import"]

/// 生成した鍵の登録の POST 先のパスセグメント。
pub const register_generated_segments = [accounts_segment, "register-generated"]

/// セッションのページの先頭のセグメント。
pub const sessions_segment = "sessions"

/// セッション取り消しの POST 先のパスセグメント。
pub const revoke_segments = [sessions_segment, "revoke"]

/// クライアントの接続画面のパスセグメント。
pub const connect_segments = [sessions_segment, "connect"]

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

/// 承認待ちがあるダッシュボードと承認ページを自動で読み込み直す間隔（秒）。
const refresh_seconds = 30

/// 承認待ちの節のアンカー。タイルの `href="#…"` と節の `id` が同じ値を見る。接続 QR
/// コードのページからのリンクも同じ値を見る。
pub const pending_anchor = "pending"

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

/// スナップショットをダッシュボードのページに描画する。先頭に概要のタイル、続けて
/// 承認待ちが 1 件以上あるとき（または一覧を得られないとき）だけ全幅の節を置く。その下は
/// 広い画面では、アカウントと読み込めなかったアカウントとセッションを左の列に、リレーと
/// プラグインの状態と読み込めなかったプラグインを右の列に置く 2 列で、狭い画面ではこの順に
/// 1 列に並ぶ。
pub fn render(
  language: Language,
  theme: view.Theme,
  snapshot: Snapshot,
) -> String {
  view.page(
    language,
    theme,
    i18n.Dashboard,
    view.Wide,
    view.SwitchReturningTo("/"),
    dashboard_refresh(snapshot.pending),
    [
      overview_tiles(language, snapshot),
      pending_section(language, snapshot.accounts, snapshot.pending),
      html.div([attribute.class("grid items-start gap-6 xl:grid-cols-5")], [
        html.div(
          [attribute.class("flex min-w-0 flex-col gap-6 xl:col-span-3")],
          [
            accounts_section(language, snapshot.accounts),
            skipped_section(language, snapshot.skipped),
            sessions_section(
              language,
              snapshot.accounts,
              snapshot.now,
              snapshot.sessions,
            ),
          ],
        ),
        html.div(
          [attribute.class("flex min-w-0 flex-col gap-6 xl:col-span-2")],
          [
            relays_section(language, snapshot.relays),
            plugins_section(language, snapshot.plugins),
            not_loaded_section(language, snapshot.not_loaded_plugins),
          ],
        ),
      ]),
    ],
  )
}

/// 概要のタイル 5 枚。狭い画面では 2 列で、承認待ちが 1 件以上のときは承認待ちのタイルだけ
/// 全幅にする。
fn overview_tiles(language: Language, snapshot: Snapshot) -> Element(msg) {
  html.div([attribute.class("grid grid-cols-2 gap-4 lg:grid-cols-5")], [
    pending_tile(language, snapshot.pending),
    accounts_tile(language, snapshot.accounts, snapshot.skipped),
    sessions_tile(language, snapshot.sessions),
    relays_tile(language, snapshot.relays),
    plugins_tile(language, snapshot.plugins, snapshot.not_loaded_plugins),
  ])
}

/// タイル 1 枚。`anchor` が `Some(a)` なら同じページの節への `href="#" <> a` のリンクにする。
/// 飛び先の節が出ないときは `None` を渡し、リンクにしない。`tone` が `Warning` のときだけ
/// 警告の色にし、`wide` が真のときだけ狭い画面で全幅を占めさせる。
fn tile(
  language: Language,
  tone: view.Tone,
  title: i18n.Message,
  value: String,
  note: Element(msg),
  anchor: Option(String),
  wide: Bool,
) -> Element(msg) {
  let class = case tone, wide {
    view.Warning, True ->
      "card card-border col-span-2 border-warning bg-warning/15 text-warning lg:col-span-1"
    view.Warning, False ->
      "card card-border border-warning bg-warning/15 text-warning"
    _, True -> "card card-border col-span-2 lg:col-span-1"
    _, False -> "card card-border"
  }
  let content = [
    html.div([attribute.class("card-body gap-1 p-4")], [
      html.p([attribute.class("text-sm")], [
        html.text(i18n.text(language, title)),
      ]),
      html.p([attribute.class("text-2xl font-bold")], [html.text(value)]),
      note,
    ]),
  ]
  case anchor {
    Some(a) ->
      html.a([attribute.href("#" <> a), attribute.class(class)], content)
    None -> html.div([attribute.class(class)], content)
  }
}

/// タイルの補足 1 行。
fn tile_note(text: String) -> Element(msg) {
  html.p([attribute.class("text-xs")], [html.text(text)])
}

/// 承認待ちのタイル。1 件以上あれば件数と警告の色、無ければ失効までの分数、得られなければ
/// 「取得できません」を出す。0 件のときは節が出ないので、リンクにしない。
fn pending_tile(
  language: Language,
  pending: Result(List(PendingRow), i18n.Reason),
) -> Element(msg) {
  let text = i18n.text(language, _)
  let #(value, note, tone, wide, anchor) = case pending {
    Error(_) -> #(
      "—",
      text(i18n.TileNotAvailable),
      view.Neutral,
      False,
      Some(pending_anchor),
    )
    Ok([]) -> #(
      "0",
      text(i18n.PendingExpireAfterMinutes(engine.pending_ttl_minutes())),
      view.Neutral,
      False,
      None,
    )
    Ok(rows) -> #(
      int.to_string(list.length(rows)),
      text(i18n.AwaitingDecision(refresh_seconds)),
      view.Warning,
      True,
      Some(pending_anchor),
    )
  }
  tile(language, tone, i18n.Pending, value, tile_note(note), anchor, wide)
}

/// アカウントのタイル。件数と、読み込めなかった行の有無を補足する。
fn accounts_tile(
  language: Language,
  accounts: Result(List(AccountRow), i18n.Reason),
  skipped: Result(List(SkippedRow), i18n.Reason),
) -> Element(msg) {
  let text = i18n.text(language, _)
  let #(value, note) = case accounts {
    Error(_) -> #("—", text(i18n.TileNotAvailable))
    Ok(rows) -> #(int.to_string(list.length(rows)), case skipped {
      Error(_) -> text(i18n.TileNotAvailable)
      Ok([]) -> text(i18n.AllAccountsLoaded)
      Ok(rows) -> text(i18n.UnreadableRowCount(list.length(rows)))
    })
  }
  tile(
    language,
    view.Neutral,
    i18n.Accounts,
    value,
    tile_note(note),
    Some(accounts_anchor),
    False,
  )
}

/// セッションのタイル。承認済みのクライアントの件数を出す。
fn sessions_tile(
  language: Language,
  sessions: Result(List(SessionRow), i18n.Reason),
) -> Element(msg) {
  let text = i18n.text(language, _)
  let #(value, note) = case sessions {
    Error(_) -> #("—", text(i18n.TileNotAvailable))
    Ok(rows) -> #(int.to_string(list.length(rows)), text(i18n.ApprovedClients))
  }
  tile(
    language,
    view.Neutral,
    i18n.Sessions,
    value,
    tile_note(note),
    Some(sessions_anchor),
    False,
  )
}

/// リレーのタイル。行数と、未接続・応答なしの行数、バンカー用の行の有無を補足する。
/// 未接続と応答なしは、用途が 2 つある行を二重に数えないよう行単位で数える。
fn relays_tile(
  language: Language,
  relays: Result(List(RelayRow), i18n.Reason),
) -> Element(msg) {
  let text = i18n.text(language, _)
  let #(value, note) = case relays {
    Error(_) -> #("—", text(i18n.TileNotAvailable))
    Ok(rows) -> #(
      int.to_string(list.length(rows)),
      case has_bunker_relay(rows) {
        False -> text(i18n.NoBunkerRelayShort)
        True -> {
          let disconnected =
            list.count(rows, row_has_role_state(_, Reported(Disconnected)))
          let unanswered = list.count(rows, row_has_role_state(_, Unanswered))
          case disconnected, unanswered {
            0, 0 -> text(i18n.AllRelaysConnected)
            _, _ -> text(i18n.RelayIssueCounts(disconnected, unanswered))
          }
        }
      },
    )
  }
  tile(
    language,
    view.Neutral,
    i18n.Relays,
    value,
    tile_note(note),
    Some(relays_anchor),
    False,
  )
}

/// 行の監視かバンカーの用途のどちらかが `state` と等しいか。
fn row_has_role_state(row: RelayRow, state: RoleState) -> Bool {
  row.monitor == state || row.bunker == state
}

/// 一覧にバンカーに使う行があるか。
fn has_bunker_relay(rows: List(RelayRow)) -> Bool {
  list.any(rows, fn(row) { row.bunker != Unused })
}

/// プラグインのタイル。値は動作中の件数と全件数で、読み込めなかった候補は分母に入れない
/// （ランナーが無いため）。補足は、読み込めなかった候補があればその件数（このときだけ警告の
/// 色にする）、無ければ異常（過負荷・無効・応答なし）の内訳、プラグインが 1 件も無ければ
/// 「有効なプラグインなし」、どれでもなければ出さない。
fn plugins_tile(
  language: Language,
  plugins: List(PluginRow),
  not_loaded: List(plugin_loader.NotLoaded),
) -> Element(msg) {
  let text = i18n.text(language, _)
  let total = list.length(plugins)
  let running =
    list.count(plugins, fn(plugin) {
      plugin.status == Some(plugin_runner.Running)
    })
  let overloaded =
    list.count(plugins, fn(plugin) {
      case plugin.status {
        Some(plugin_runner.Overloaded(..)) -> True
        _ -> False
      }
    })
  let disabled =
    list.count(plugins, fn(plugin) {
      case plugin.status {
        Some(plugin_runner.Disabled(..)) -> True
        _ -> False
      }
    })
  let unavailable = list.count(plugins, fn(plugin) { plugin.status == None })
  let not_loaded_count = list.length(not_loaded)
  let #(tone, note) = case
    not_loaded_count,
    overloaded,
    disabled,
    unavailable,
    total
  {
    0, 0, 0, 0, 0 -> #(
      view.Neutral,
      tile_note(text(i18n.NoPluginsEnabledShort)),
    )
    0, 0, 0, 0, _ -> #(view.Neutral, element.none())
    0, _, _, _, _ -> #(
      view.Neutral,
      tile_note(text(i18n.PluginIssueCounts(overloaded, disabled, unavailable))),
    )
    _, _, _, _, _ -> #(
      view.Warning,
      tile_note(text(i18n.PluginsNotLoadedShort(not_loaded_count))),
    )
  }
  tile(
    language,
    tone,
    i18n.Plugins,
    text(i18n.PluginsRunningOfTotal(running, total)),
    note,
    Some(plugins_anchor),
    False,
  )
}

/// アカウントと、その `bunker://` 接続 URI（secret 入りと、承認を経るもの）と操作。
/// 一覧を得られないときは、一覧の代わりにその理由を出し、登録のリンクも出さない。
fn accounts_section(
  language: Language,
  accounts: Result(List(AccountRow), i18n.Reason),
) -> Element(msg) {
  let text = i18n.text(language, _)
  view.section_block(accounts_anchor, [
    listed_section_heading(
      language,
      accounts,
      view.users_icon(),
      i18n.Accounts,
      [
        view.icon_button_link(
          view.segments_path(new_account_segments),
          view.plus_icon(),
          text(i18n.Add),
          view.PrimaryButton,
        ),
      ],
      [reload_form(language)],
    ),
    listed_body(
      language,
      view.Neutral,
      accounts,
      i18n.CouldNotListAccounts,
      view.empty_state(view.users_icon(), text(i18n.NoAccounts)),
      fn(rows) { view.row_list(list.map(rows, account_item(language, _))) },
    ),
  ])
}

/// 直近の読み込みで飛ばされた行。1 件以上あるときだけカードを描く。一覧を
/// 得られないとき（読み込み中、応答なし、締め切り超過）も描かない。
fn skipped_section(
  language: Language,
  skipped: Result(List(SkippedRow), i18n.Reason),
) -> Element(msg) {
  case skipped {
    Ok([_, ..] as rows) ->
      view.card([
        view.section_heading(
          view.warning_triangle_icon(),
          i18n.text(language, i18n.UnreadableAccounts),
          Some(list.length(rows)),
          None,
          [],
        ),
        view.alert(view.Warning, [
          html.text(i18n.text(language, i18n.UnreadableAccountsWarning)),
        ]),
        view.row_list(list.map(rows, skipped_item(language, _))),
      ])
    Ok([]) | Error(_) -> element.none()
  }
}

/// 飛ばした行 1 件。識別と理由の 1 文を縦に並べ、削除のリンクを右に置く。`pubkey`
/// 列が形式不正の行は識別も削除のリンクも出さず、理由の 1 文に削除できない旨を
/// 続けて出す。
fn skipped_item(language: Language, row: SkippedRow) -> Element(msg) {
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
        html.div([attribute.class("flex min-w-0 flex-col gap-1")], [
          view.identity(language, row.label, row.npub),
          html.p([attribute.class("text-sm")], [
            html.text(i18n.text(language, i18n.UnreadableReason(row.reason))),
          ]),
        ]),
        button_row([
          view.icon_button_link(
            account_action_path(row.pubkey, DeleteAccount),
            view.trash_icon(),
            i18n.text(language, i18n.Delete),
            view.DangerGhostButton,
          ),
        ]),
      ])
  }
}

/// 一覧を得る節の見出し。一覧を得て 1 件以上あるときだけ件数を出す。一覧を得たときだけ `listed_actions`
/// を出し、`always_actions` は常に出す。説明の行は出さない。
fn listed_section_heading(
  language: Language,
  listing: Result(List(a), i18n.Reason),
  icon: Element(msg),
  title: i18n.Message,
  listed_actions: List(Element(msg)),
  always_actions: List(Element(msg)),
) -> Element(msg) {
  let count = case listing {
    Ok([_, ..] as rows) -> Some(list.length(rows))
    Ok([]) | Error(_) -> None
  }
  let actions = case listing {
    Ok(_) -> list.append(listed_actions, always_actions)
    Error(_) -> always_actions
  }
  view.section_heading(icon, i18n.text(language, title), count, None, actions)
}

/// 一覧を得たときの節の本文。得られなければ `lead` を前置きにした `tone` の色の理由の囲みを面
/// （`view.surface`）に載せて、得られれば `render` の内容を出す。アカウント、承認待ち、セッション、リレーの
/// 節が使い、承認待ちだけ `Failure`、ほかは `Neutral` を渡す。
fn listed_body(
  language: Language,
  tone: view.Tone,
  listing: Result(List(a), i18n.Reason),
  lead: i18n.Lead,
  empty: Element(msg),
  render: fn(List(a)) -> Element(msg),
) -> Element(msg) {
  case listing {
    Ok(rows) -> section_body(rows, empty, render)
    Error(reason) ->
      view.surface([
        view.alert(tone, view.reason_content(language, Some(lead), reason)),
      ])
  }
}

/// アカウント 1 件。識別、接続 URI と公開鍵の畳み、操作のリンクを縦に並べる。
fn account_item(language: Language, account: AccountRow) -> Element(msg) {
  view.list_row(view.StackedRow, [
    view.identity(language, account.label, account.npub),
    uri_details(language, account),
    account_action_links(language, account.signer),
  ])
}

/// 接続 URI と公開鍵の畳み。secret 入りの URI、要承認の URI、16 進の公開鍵の 3 つの
/// コピー欄を `view.details_panel` の中に置く。
fn uri_details(language: Language, account: AccountRow) -> Element(msg) {
  let text = i18n.text(language, _)
  view.details_panel(text(i18n.ConnectionUrisAndPublicKey), [
    view.copyable_field(language, text(i18n.ConnectionUri), account.uri),
    view.copyable_field(
      language,
      text(i18n.ConnectionUriForApproval),
      account.auth_uri,
    ),
    view.copyable_field(language, text(i18n.PublicKeyHex), account.signer),
  ])
}

/// アカウント 1 件への操作のリンク。すべてアイコン＋語の ghost にし、削除だけ短い語と
/// `text-error` にする。
fn account_action_links(language: Language, signer: String) -> Element(msg) {
  html.div(
    [attribute.class("flex flex-wrap gap-2")],
    list.map(account_actions, fn(action) {
      view.icon_button_link(
        account_action_path(signer, action),
        account_action_icon(action),
        i18n.text(language, account_action_row_title(action)),
        account_action_link_kind(action),
      )
    }),
  )
}

/// アカウント 1 件への操作のアイコン。
fn account_action_icon(action: AccountAction) -> Element(msg) {
  case action {
    EditLabel -> view.pencil_icon()
    RevealPrivateKey -> view.eye_icon()
    RotateSecret -> view.rotate_icon()
    DeleteAccount -> view.trash_icon()
    ShowConnectionQr -> view.qr_code_icon()
  }
}

/// 行の操作のボタンの語。削除だけ短い語（`i18n.Delete`）にする。行き先のページの題は
/// `account_action_title` のまま変えない。
fn account_action_row_title(action: AccountAction) -> i18n.Message {
  case action {
    DeleteAccount -> i18n.Delete
    EditLabel | RevealPrivateKey | RotateSecret | ShowConnectionQr ->
      account_action_title(action)
  }
}

/// アカウント 1 件への操作のボタンの種類。行の操作はすべて地味なボタンにし、削除だけ error の
/// 文字色にする。
fn account_action_link_kind(action: AccountAction) -> view.ButtonKind {
  case action {
    EditLabel | RevealPrivateKey | RotateSecret | ShowConnectionQr ->
      view.GhostButton
    DeleteAccount -> view.DangerGhostButton
  }
}

/// 承認待ちの接続要求と、その承認・拒否ボタン。1 件以上あるとき、または一覧を得られないときだけ、
/// warning の色の囲み（`view.alert_panel`）で全幅に描く。0 件のときは節ごと出さない。
fn pending_section(
  language: Language,
  accounts: Result(List(AccountRow), i18n.Reason),
  pending: Result(List(PendingRow), i18n.Reason),
) -> Element(msg) {
  case pending {
    Ok([]) -> element.none()
    _ -> {
      let text = i18n.text(language, _)
      let count = case pending {
        Ok(rows) -> Some(list.length(rows))
        Error(_) -> None
      }
      view.alert_panel(pending_anchor, view.Warning, [
        view.section_heading(
          view.door_open_icon(),
          text(i18n.PendingConnections),
          count,
          None,
          [],
        ),
        listed_body(
          language,
          view.Failure,
          pending,
          i18n.CouldNotListPending,
          element.none(),
          fn(rows) {
            view.row_list(
              list.map(rows, fn(entry) {
                let signer = signer_name(accounts, entry.signer)
                view.list_row(
                  view.InlineRow,
                  pending_content(language, signer, entry),
                )
              }),
            )
          },
        ),
      ])
    }
  }
}

/// 承認ページ。クライアントが `auth_url` で開く、接続要求 1 件の確認画面。テーマか言語を
/// 切り替えた後は同じ承認ページを開き直す。
pub fn approval_page(
  language: Language,
  theme: view.Theme,
  accounts: Result(List(AccountRow), i18n.Reason),
  pending: PendingRow,
) -> String {
  view.page(
    language,
    theme,
    i18n.ApproveConnection,
    view.Narrow,
    view.SwitchReturningTo(approve_path(pending.token)),
    view.RefreshEverySeconds(refresh_seconds),
    [view.card(approval_content(language, accounts, pending))],
  )
}

/// 承認ページのカードの中身。secret が一致しなかった承認待ちでは、判断の前に読ませる
/// 警告を先頭に置く。末尾に、承認の意味の説明を info の囲みで置く。
fn approval_content(
  language: Language,
  accounts: Result(List(AccountRow), i18n.Reason),
  pending: PendingRow,
) -> List(Element(msg)) {
  let mismatch_warning = case pending.secret_mismatch {
    True -> [
      view.alert(
        view.Warning,
        view.emphasized(
          language,
          i18n.WrongSecretOffered,
          i18n.WrongSecretNotice,
        ),
      ),
    ]
    False -> []
  }
  list.flatten([
    mismatch_warning,
    pending_content(language, signer_name(accounts, pending.signer), pending),
    [approval_explanation(language, pending.perms)],
  ])
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

/// 見出しと理由だけを伝えるページ。承認・拒否の結果、アカウントを扱えないとき、
/// 変更が反映されたか分からないとき、404 / 405 / 400 の通知に使う。`tone` は理由の
/// 囲みの色で、呼び出し側が結果に応じて決める。理由はほかのページと同じくカードに入れる
/// （中立の囲みはページの背景と同じ色なので、カードの外では見えない）。`below` は
/// 囲みの直後にカードの中へ並べる要素で、無ければ空リストを渡す。ダッシュボードで
/// 状態を確かめられるようリンクを置く。切り替えを出すか、切り替えた後にどこを開くかは
/// 呼び出し側が `switch` で決める。
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
      view.alert(tone, view.reason_content(language, None, message)),
      ..below
    ]),
    view.back_link(language),
  ])
}

/// 操作の見出しと、ダッシュボードのリンクの文言。
pub fn account_action_title(action: AccountAction) -> i18n.Message {
  case action {
    EditLabel -> i18n.EditLabel
    RotateSecret -> i18n.RotateSecret
    DeleteAccount -> i18n.DeleteAccount
    RevealPrivateKey -> i18n.ShowPrivateKey
    ShowConnectionQr -> i18n.ConnectionQr
  }
}

/// 操作のパスセグメント。
fn account_action_segment(action: AccountAction) -> String {
  case action {
    EditLabel -> "label"
    RotateSecret -> "rotate"
    DeleteAccount -> "delete"
    RevealPrivateKey -> "private-key"
    ShowConnectionQr -> "qr"
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

/// 操作の見出しと、ダッシュボードのリンクの文言。
pub fn relay_action_title(action: RelayAction) -> i18n.Message {
  case action {
    EditRelayRoles -> i18n.EditRelayRoles
    DeleteRelay -> i18n.DeleteRelay
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

/// セッションの権限の編集画面のパスの末尾のセグメント。
pub const session_permissions_segment = "permissions"

/// セッションの権限の編集画面のパス（`/sessions/<signer>/<client>/permissions`）。
pub fn session_permissions_path(signer: String, client: String) -> String {
  view.segments_path([
    sessions_segment,
    signer,
    client,
    session_permissions_segment,
  ])
}

/// パスセグメントから、セッションの権限の編集画面の署名者とクライアントを引く。値は
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

/// 操作のページへのリンクの種類。編集は開くだけなので地味なボタン、削除は接続中のクライアントに
/// 影響するので error の文字色にする。
fn relay_action_link_kind(action: RelayAction) -> view.ButtonKind {
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

/// 承認待ち 1 件の、クライアント・secret の提示の区別・失効までの時間・署名者・権限と、
/// 承認・拒否ボタン。ダッシュボードの行と承認ページが使う。
fn pending_content(
  language: Language,
  signer: SignerName,
  pending: PendingRow,
) -> List(Element(msg)) {
  let text = i18n.text(language, _)
  [
    view.detail_list([
      #(
        text(i18n.Client),
        html.dd([attribute.class("flex flex-wrap items-center gap-2")], [
          view.truncated_id(language, pending.client, text(i18n.CopyClient)),
          secret_badge(language, pending.secret_mismatch),
        ]),
      ),
      #(
        text(i18n.ExpiresIn),
        html.dd([], [expires_in_badge(language, pending.expires_in_seconds)]),
      ),
      #(text(i18n.Signer), html.dd([], [signer_value(signer)])),
      #(
        text(i18n.Permissions),
        html.dd([], [permission_view.chips(language, pending.perms)]),
      ),
    ]),
    button_row(decision_forms(language, pending.token)),
  ]
}

/// 署名者の表示。アカウント一覧にある署名者はラベルと省略した npub を縦に、無い署名者は
/// 省略した 16 進の pubkey だけを出す。
fn signer_value(signer: SignerName) -> Element(msg) {
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

/// 失効までの残り秒。60 秒未満なら、承認しても失敗しうることを示す警告色のバッジに、
/// それ以外は本文の書体の文字にする。
fn expires_in_badge(language: Language, seconds: Int) -> Element(msg) {
  let text = i18n.text(language, i18n.ExpiresInSeconds(seconds))
  case seconds < 60 {
    True -> view.status_chip(view.ToneChip(view.Warning), text)
    False -> html.span([], [html.text(text)])
  }
}

/// リレーの一覧。1 件は `relays` の 1 行で、監視、バンカーの順に用途の語と状態を並べる。
/// 一覧を得たときは見出しの行に追加のリンクを出す。バンカーに使う行が無ければ警告を、
/// 一覧を得られないときは理由を出す。
fn relays_section(
  language: Language,
  relays: Result(List(RelayRow), i18n.Reason),
) -> Element(msg) {
  let text = i18n.text(language, _)
  view.section_block(relays_anchor, [
    listed_section_heading(
      language,
      relays,
      view.plug_icon(),
      i18n.Relays,
      [
        view.icon_button_link(
          view.segments_path(new_relay_segments),
          view.plus_icon(),
          text(i18n.Add),
          view.PrimaryButton,
        ),
      ],
      [],
    ),
    no_bunker_relay_warning(language, relays),
    listed_body(
      language,
      view.Neutral,
      relays,
      i18n.CouldNotListRelays,
      element.none(),
      fn(rows) { view.row_list(list.map(rows, relay_item(language, _))) },
    ),
  ])
}

/// 一覧を得て、バンカーに使う行が 1 件も無いときの警告。リレーの節と接続 QR コードの
/// ページで使う。
pub fn no_bunker_relay_warning(
  language: Language,
  relays: Result(List(RelayRow), i18n.Reason),
) -> Element(msg) {
  case relays {
    Ok(rows) ->
      case has_bunker_relay(rows) {
        True -> element.none()
        False ->
          view.alert(view.Warning, [
            html.text(i18n.text(language, i18n.NoBunkerRelay)),
          ])
      }
    Error(_) -> element.none()
  }
}

/// リレー 1 件。URL と、用途の語と状態の組を監視、バンカーの順に並べ、アイコンだけの
/// 操作のリンク（用途の編集、削除）を続ける。使っていない用途は「未使用」のバッジで出す。
fn relay_item(language: Language, row: RelayRow) -> Element(msg) {
  view.list_row(view.InlineRow, [
    html.div([attribute.class("flex min-w-0 flex-col gap-1")], [
      html.p([attribute.class("font-mono text-xs break-all")], [
        html.text(row.url),
      ]),
      html.div([attribute.class("flex flex-wrap gap-x-4 gap-y-1 text-sm")], [
        relay_role(language, view.eye_icon(), i18n.MonitorRole, row.monitor),
        relay_role(language, view.key_icon(), i18n.BunkerRole, row.bunker),
      ]),
    ]),
    button_row(
      list.map(relay_actions, fn(action) {
        view.icon_only_link(
          relay_action_path(row.id, action),
          relay_action_icon(action),
          i18n.text(language, relay_action_title(action)),
          relay_action_link_kind(action),
        )
      }),
    ),
  ])
}

/// 用途のアイコンと語、その用途の状態のバッジの組。
fn relay_role(
  language: Language,
  icon: Element(msg),
  role: i18n.Message,
  state: RoleState,
) -> Element(msg) {
  let text = i18n.text(language, _)
  html.span([attribute.class("flex items-center gap-2")], [
    icon,
    html.span([attribute.class("whitespace-nowrap")], [html.text(text(role))]),
    role_state_badge(language, state),
  ])
}

/// 用途 1 つぶんの接続状態のバッジ。ダッシュボードの行とリレーの用途の編集のページが
/// 使う。
pub fn role_state_badge(language: Language, state: RoleState) -> Element(msg) {
  let text = i18n.text(language, _)
  case state {
    Reported(status) -> relay_status(language, status)
    Unanswered ->
      view.status_chip(view.UnansweredChip, text(i18n.PluginUnavailable))
    Unused -> view.status_chip(view.UnusedChip, text(i18n.RelayRoleUnused))
  }
}

/// 承認済みセッションと、その取り消しボタン。一覧を得られないときは、一覧の
/// 代わりにその理由を出す。
fn sessions_section(
  language: Language,
  accounts: Result(List(AccountRow), i18n.Reason),
  now: Int,
  sessions: Result(List(SessionRow), i18n.Reason),
) -> Element(msg) {
  let text = i18n.text(language, _)
  view.section_block(sessions_anchor, [
    listed_section_heading(
      language,
      sessions,
      view.clock_icon(),
      i18n.ApprovedSessions,
      [
        view.icon_button_link(
          view.segments_path(connect_segments),
          view.plus_icon(),
          text(i18n.ConnectClient),
          view.PrimaryButton,
        ),
      ],
      [],
    ),
    listed_body(
      language,
      view.Neutral,
      sessions,
      i18n.CouldNotListSessions,
      view.empty_state(view.clock_icon(), text(i18n.NoApprovedSessions)),
      fn(rows) {
        view.row_list(list.map(rows, session_item(language, accounts, now, _)))
      },
    ),
  ])
}

/// 承認済みセッション 1 件。クライアントの省略 id、署名者、権限のチップ、最終利用の相対
/// 時刻と、権限の編集と取り消しのボタンを並べる。
fn session_item(
  language: Language,
  accounts: Result(List(AccountRow), i18n.Reason),
  now: Int,
  session: SessionRow,
) -> Element(msg) {
  let text = i18n.text(language, _)
  view.list_row(view.InlineRow, [
    view.detail_list([
      #(
        text(i18n.Client),
        html.dd([], [
          view.truncated_id(language, session.client, text(i18n.CopyClient)),
        ]),
      ),
      #(
        text(i18n.Signer),
        html.dd([], [signer_value(signer_name(accounts, session.signer))]),
      ),
      #(
        text(i18n.Permissions),
        html.dd([], [permission_view.chips(language, session.perms)]),
      ),
      #(
        text(i18n.LastUsed),
        html.dd([], [
          html.span([attribute.title(session_time_title(language, session))], [
            html.text(text(relative_time(now, session.last_used_at))),
          ]),
        ]),
      ),
    ]),
    button_row([
      permissions_link(language, session),
      revoke_form(language, session),
    ]),
  ])
}

/// 権限の編集画面へのリンク。
fn permissions_link(language: Language, session: SessionRow) -> Element(msg) {
  view.icon_button_link(
    session_permissions_path(session.signer, session.client),
    view.pencil_icon(),
    i18n.text(language, i18n.EditPermissions),
    view.GhostButton,
  )
}

/// 最終利用の `title` に出す、UTC の全文と作成時刻。
fn session_time_title(language: Language, session: SessionRow) -> String {
  let text = i18n.text(language, _)
  text(i18n.LastUsed)
  <> ": "
  <> utc_time(session.last_used_at)
  <> " · "
  <> text(i18n.Created)
  <> ": "
  <> utc_time(session.created_at)
}

/// 描画時点から見た相対表示の文言。60 秒未満は「たった今」、1 時間未満は分、1 日未満は
/// 時間、それ以上は日で出す。未来の時刻は「たった今」にする。
pub fn relative_time(now: Int, at: Int) -> i18n.Message {
  case int.max(now - at, 0) {
    diff if diff < 60 -> i18n.JustNow
    diff if diff < 3600 -> i18n.MinutesAgo(diff / 60)
    diff if diff < 86_400 -> i18n.HoursAgo(diff / 3600)
    diff -> i18n.DaysAgo(diff / 86_400)
  }
}

/// Unix 秒を RFC 3339 の UTC の文字列（`2026-09-13T05:12:34Z`）にする。
fn utc_time(seconds: Int) -> String {
  timestamp.from_unix_seconds(seconds)
  |> timestamp.to_rfc3339(calendar.utc_offset)
}

/// 監視イベントを処理するプラグインと、その現在の状態。
fn plugins_section(
  language: Language,
  plugins: List(PluginRow),
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
    ),
    case plugins {
      [] -> view.empty_state(view.puzzle_icon(), text(i18n.NoPlugins))
      rows ->
        view.surface([
          view.table(
            [text(i18n.NameColumn), text(i18n.StateColumn), ""],
            list.map(rows, fn(plugin) {
              [
                html.td([attribute.class("break-words")], [
                  html.text(plugin.name),
                ]),
                html.td([], [plugin_state(language, plugin)]),
                html.td(
                  [attribute.class("whitespace-nowrap")],
                  list.append(
                    plugin_page_link(language, plugin),
                    reenable_form_if_disabled(language, plugin),
                  ),
                ),
              ]
            }),
          ),
        ])
    },
  ])
}

/// 起動時に読み込めなかったプラグイン。1 件以上あるときだけカードを描く。
/// `app.Spec` から届く一覧で、起動時に確定するので取得できない状態は無い。
fn not_loaded_section(
  language: Language,
  rows: List(plugin_loader.NotLoaded),
) -> Element(msg) {
  case rows {
    [] -> element.none()
    rows ->
      view.card([
        view.section_heading(
          view.warning_triangle_icon(),
          i18n.text(language, i18n.NotLoadedPlugins),
          Some(list.length(rows)),
          None,
          [],
        ),
        view.alert(view.Warning, [
          html.text(i18n.text(language, i18n.NotLoadedPluginsWarning)),
        ]),
        view.row_list(list.map(rows, not_loaded_item(language, _))),
      ])
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

/// 行と承認ページのボタンの並び。
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

/// 承認待ち 1 件への承認・拒否フォーム。どちらも状態を変えるので POST で送る。承認が
/// この画面の主な操作で、拒否してもクライアントは接続し直せるので地味なボタンにする。
fn decision_forms(language: Language, token: String) -> List(Element(msg)) {
  let text = i18n.text(language, _)
  [
    view.post_form(
      approve_path(token),
      [],
      text(i18n.Approve),
      view.PrimaryButton,
      view.InRow,
    ),
    view.post_form(
      deny_path(token),
      [],
      text(i18n.Deny),
      view.GhostButton,
      view.InRow,
    ),
  ]
}

/// セッションを 1 件取り消すフォーム。取り消しは副作用なので POST で送る。確認のページを
/// 経ずに接続中のクライアントに影響するが、クライアントは接続し直せるので地味なボタンにする。
fn revoke_form(language: Language, session: SessionRow) -> Element(msg) {
  view.post_form(
    view.segments_path(revoke_segments),
    [
      view.hidden_input(signer_field, session.signer),
      view.hidden_input(client_field, session.client),
    ],
    i18n.text(language, i18n.Revoke),
    view.GhostButton,
    view.InRow,
  )
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
