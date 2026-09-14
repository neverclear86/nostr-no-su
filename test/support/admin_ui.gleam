//// 描画した管理 UI のページと、配信する静的ファイル（`priv/static/`）を突き合わせる検査
//// （`stylesheet_test` と `script_test`）が共有する、ページと静的ファイルの読み出し。

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{None, Some}
import nostr_no_su/admin/account_pages
import nostr_no_su/admin/dashboard
import nostr_no_su/admin/i18n
import nostr_no_su/admin/view
import nostr_no_su/bunker/engine
import nostr_no_su/plugin_runner
import nostr_no_su/relay_connection
import support/account_actions

/// ファイルの中身を読む。
@external(erlang, "file", "read_file")
fn read_file(path: String) -> Result(BitArray, Dynamic)

/// URL のパスセグメントが指す静的ファイルの中身。ルーティングが `priv` の下の同じパスから
/// 配信するので、セグメントの定義（`view.stylesheet_segments` など）から読む。
pub fn static_file(segments: List(String)) -> String {
  let assert Ok(bytes) = read_file("priv" <> view.segments_path(segments))
  let assert Ok(content) = bit_array.to_string(bytes)
  content
}

/// 状態ごとに違うクラスと属性がすべて現れるよう、描画のどの分岐も通したページ。言語ごとに描画し、
/// 言語の切り替えの項目（表示している言語とそれ以外）と、切り替えを出さない秘密鍵のページを
/// 通す。テーマの一覧の項目（`view.themes` ごとの表示中の項目の 3 通り）は、ダッシュボードを
/// テーマごとに描画して通す。ほかのページは `view.System` で描画する。描画に状態の分岐を
/// 足したら、ここにもその状態のページを足す。
pub fn pages() -> List(String) {
  let row =
    dashboard.AccountRow(
      signer: "abcd",
      npub: "npub1example",
      label: "main",
      uri: "bunker://abcd?relay=x&secret=s",
      auth_uri: "bunker://abcd?relay=x",
    )
  let pending =
    dashboard.PendingRow(
      token: "tok",
      signer: "abcd",
      client: "ef01",
      age_seconds: 12,
    )
  let empty =
    dashboard.Snapshot(
      accounts: Ok([]),
      pending: Ok([]),
      relays: [],
      sessions: Ok([]),
      plugins: [],
    )
  let full =
    dashboard.Snapshot(
      accounts: Ok([row]),
      pending: Ok([pending]),
      relays: [
        dashboard.RelayRow(
          dashboard.MonitorRelay,
          "wss://a",
          relay_connection.Connected,
        ),
        dashboard.RelayRow(
          dashboard.BunkerRelay,
          "wss://b",
          relay_connection.Disconnected,
        ),
      ],
      sessions: Ok([
        engine.Session(
          signer: "abcd",
          client: "ef01",
          perms: "",
          created_at: 1000,
          last_used_at: 1000,
        ),
      ]),
      plugins: [
        dashboard.PluginRow("running", Some(plugin_runner.Running)),
        dashboard.PluginRow(
          "overloaded",
          Some(plugin_runner.Overloaded(dropped: 1)),
        ),
        dashboard.PluginRow(
          "disabled",
          Some(plugin_runner.Disabled(reason: "boom", dropped: 1)),
        ),
        dashboard.PluginRow("unavailable", None),
      ],
    )
  use language <- list.flat_map(i18n.languages)
  let reason = i18n.Untranslated("reason")
  list.flatten([
    list.map(view.themes, dashboard.render(language, _, full)),
    [
      dashboard.render(language, view.System, empty),
      dashboard.render(
        language,
        view.System,
        dashboard.Snapshot(
          ..empty,
          accounts: Error("reason"),
          pending: Error("reason"),
          sessions: Error("reason"),
        ),
      ),
      dashboard.approval_page(language, view.System, pending),
      account_pages.new_account_page(language, view.System, "", Some(reason)),
      account_pages.generated_key_page(
        language,
        view.System,
        "nsec1example",
        "",
        Some(account_pages.InvalidLabel(i18n.LabelHasControlCharacters)),
      ),
      account_pages.registered_page(
        language,
        view.System,
        "npub1example",
        "main",
        "nsec1example",
      ),
      account_pages.private_key_page(language, view.System, row, "nsec1example"),
    ],
    list.map(
      [
        account_pages.NotApplied("reason"),
        account_pages.NotAccepted("reason"),
        account_pages.NotConfirmed(i18n.StoreDidNotConfirm),
      ],
      fn(problem) {
        account_pages.generated_key_page(
          language,
          view.System,
          "nsec1example",
          "main",
          Some(problem),
        )
      },
    ),
    list.map(
      [view.Neutral, view.Success, view.Warning, view.Failure],
      dashboard.notice_page(
        language,
        view.System,
        view.SwitchReturningTo("/"),
        i18n.NotFound,
        reason,
        _,
        [],
      ),
    ),
    [
      dashboard.notice_page(
        language,
        view.System,
        view.SwitchReturningTo("/"),
        i18n.ChangeNotConfirmed,
        reason,
        view.Warning,
        [view.hint("hint")],
      ),
      dashboard.notice_page(
        language,
        view.System,
        view.NoSwitch,
        i18n.BadRequest,
        i18n.Translated(i18n.OriginMismatch),
        view.Failure,
        [],
      ),
    ],
    list.map(account_actions.all, account_pages.account_action_page(
      language,
      view.System,
      row,
      _,
      None,
      Some(reason),
    )),
  ])
}
