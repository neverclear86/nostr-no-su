//// 描画した管理 UI のページを使う検査が共有する、ページと静的ファイルの読み出し。配信する
//// 静的ファイル（`priv/static/`）と突き合わせる `stylesheet_test` と `script_test`、日本語の
//// ページの英文を見る `japanese_pages_test` が使う。
////
//// `view.gleam` に部品を足したら `components` にもその部品を足す。

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{None, Some}
import lustre/element
import lustre/element/html
import nostr_no_su/admin/account_pages
import nostr_no_su/admin/connect_pages
import nostr_no_su/admin/dashboard
import nostr_no_su/admin/i18n
import nostr_no_su/admin/relay_pages
import nostr_no_su/admin/view
import nostr_no_su/bunker/vault
import nostr_no_su/plugin_runner
import nostr_no_su/relay_connection
import nostr_no_su/relay_list.{Roles}
import nostr_no_su/relay_store
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

/// 状態ごとに違うクラスと属性がすべて現れるよう、描画のどの分岐も通したページ。渡された言語で
/// 描画し、言語の切り替えの項目（表示している言語とそれ以外）と、切り替えを出さない秘密鍵の
/// ページを通す。テーマの一覧の項目（`view.themes` ごとの表示中の項目の 3 通り）は、
/// ダッシュボードをテーマごとに描画して通す。ほかのページは `view.System` で描画する。描画に
/// 状態の分岐を足したら、ここにもその状態のページを足す。
pub fn pages(language: i18n.Language) -> List(String) {
  let row =
    dashboard.AccountRow(
      signer: "0123",
      npub: "npub1example",
      label: "label-a",
      uri: "bunker://0123?relay=x&secret=s",
      auth_uri: "bunker://0123?relay=x",
    )
  let pending =
    dashboard.PendingRow(
      token: "tok",
      signer: "0123",
      client: "4567",
      expires_in_seconds: 540,
      secret_mismatch: False,
      perms: "sign_event:1",
    )
  let empty =
    dashboard.Snapshot(
      accounts: Ok([]),
      skipped: Ok([]),
      pending: Ok([]),
      relays: Ok([]),
      sessions: Ok([]),
      plugins: [],
      now: 2000,
    )
  let pending_mismatch =
    dashboard.PendingRow(
      token: "tok2",
      signer: "0123",
      client: "4567",
      expires_in_seconds: 45,
      secret_mismatch: True,
      perms: "",
    )
  // アカウント一覧に無い署名者。`japanese_pages_have_no_english_words_test` が
  // 短縮した 16 進の英字を未知語として拾うので、数字だけの値にする。
  let pending_unknown_signer =
    dashboard.PendingRow(
      token: "tok3",
      signer: "9999888877776666555544443333222211110000999988887777666655554444",
      client: "4567",
      expires_in_seconds: 540,
      secret_mismatch: False,
      perms: "",
    )
  let full =
    dashboard.Snapshot(
      accounts: Ok([row]),
      skipped: Ok([
        dashboard.SkippedRow(
          pubkey: "8901",
          npub: "npub1example",
          label: "label-b",
          reason: vault.UndecryptablePrivateKey,
        ),
        dashboard.SkippedRow(
          pubkey: "not-a-pubkey",
          npub: "",
          label: "",
          reason: vault.MalformedPubkey,
        ),
      ]),
      pending: Ok([pending, pending_mismatch, pending_unknown_signer]),
      relays: Ok([
        dashboard.RelayRow(
          1,
          "wss://a",
          dashboard.Reported(relay_connection.Connected),
          dashboard.Reported(relay_connection.Disconnected),
        ),
        dashboard.RelayRow(
          2,
          "wss://b",
          dashboard.Reported(relay_connection.Connected),
          dashboard.Unused,
        ),
      ]),
      sessions: Ok([
        dashboard.SessionRow(
          signer: "0123",
          client: "4567",
          perms: "",
          created_at: 1000,
          last_used_at: 1000,
        ),
      ]),
      plugins: [
        dashboard.PluginRow("plugin-a", Some(plugin_runner.Running)),
        dashboard.PluginRow(
          "plugin-b",
          Some(plugin_runner.Overloaded(dropped: 1)),
        ),
        dashboard.PluginRow(
          "plugin-c",
          Some(plugin_runner.Disabled(reason: "boom", dropped: 1)),
        ),
        dashboard.PluginRow("plugin-d", None),
      ],
      now: 2000,
    )
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
          accounts: Error(i18n.Untranslated("reason")),
          pending: Error(i18n.Untranslated("reason")),
          relays: Error(i18n.Untranslated("reason")),
          sessions: Error(i18n.Untranslated("reason")),
        ),
      ),
      dashboard.render(
        language,
        view.System,
        dashboard.Snapshot(
          ..empty,
          relays: Ok([
            dashboard.RelayRow(
              1,
              "wss://a",
              dashboard.Reported(relay_connection.Connected),
              dashboard.Unused,
            ),
          ]),
        ),
      ),
      dashboard.approval_page(language, view.System, Ok([row]), pending),
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
        "label-a",
        "nsec1example",
      ),
      account_pages.private_key_page(language, view.System, row, "nsec1example"),
      account_pages.unreadable_delete_page(
        language,
        view.System,
        dashboard.SkippedRow(
          pubkey: "8901",
          npub: "npub1example",
          label: "label-b",
          reason: vault.UndecryptablePrivateKey,
        ),
        Some(reason),
      ),
      relay_pages.new_relay_page(
        language,
        view.System,
        "",
        Roles(True, True),
        None,
      ),
      relay_pages.new_relay_page(
        language,
        view.System,
        "https://relay.example",
        Roles(False, True),
        Some(reason),
      ),
      relay_pages.relay_action_page(
        language,
        view.System,
        relay_store.Relay(1, "wss://a", Roles(True, True)),
        dashboard.EditRelayRoles,
        Some(Roles(False, False)),
        Some(i18n.Translated(i18n.RelayRoleRequired)),
      ),
      relay_pages.relay_action_page(
        language,
        view.System,
        relay_store.Relay(1, "wss://a", Roles(True, True)),
        dashboard.DeleteRelay,
        None,
        Some(reason),
      ),
      connect_pages.connect_client_page(
        language,
        view.System,
        Ok([row]),
        "",
        "",
        None,
      ),
      connect_pages.connect_client_page(
        language,
        view.System,
        Ok([row]),
        "nostrconnect://0123",
        row.signer,
        Some(i18n.Translated(i18n.NotNostrconnectUri)),
      ),
      connect_pages.connect_client_page(
        language,
        view.System,
        Ok([]),
        "",
        "",
        None,
      ),
      connect_pages.connect_client_page(
        language,
        view.System,
        Error(reason),
        "",
        "",
        None,
      ),
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
          "label-a",
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
        [view.hint("ヒント")],
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

/// すべての言語のページ。言語に依らない検査（CSS、スクリプト）が使う。
pub fn all_pages() -> List(String) {
  list.flat_map(i18n.languages, pages)
}

/// ページに埋め込まれずに使う `view.gleam` の部品を、状態の分岐をすべて通して描いた文字列。
/// `view.gleam` に部品を足したらここにも足す。
pub fn components(language: i18n.Language) -> List(String) {
  list.flatten([
    list.map(
      [view.Neutral, view.Success, view.Warning, view.Failure, view.Info],
      fn(tone) { element.to_string(view.status_badge(tone, "text")) },
    ),
    [element.to_string(view.count_pill(3))],
    [
      element.to_string(
        view.details_panel("summary", [
          view.hint("content"),
        ]),
      ),
    ],
    [
      element.to_string(view.truncated_id(language, "0123456789abcdef", "copy")),
    ],
    [
      element.to_string(view.section_card("anchor", [view.hint("content")])),
      element.to_string(view.warning_card("anchor", [view.hint("content")])),
      element.to_string(
        view.detail_list([#("term", html.dd([], [view.hint("value")]))]),
      ),
      element.to_string(view.alert(view.Info, [view.hint("content")])),
    ],
    list.map(
      [view.Normal, view.Primary, view.Caution, view.Destructive],
      fn(weight) {
        element.to_string(view.icon_button_link(
          "/",
          view.plus_icon(),
          "text",
          weight,
        ))
      },
    ),
    list.map(
      [view.Normal, view.Primary, view.Caution, view.Destructive],
      fn(weight) {
        element.to_string(view.icon_only_link(
          "/",
          view.trash_icon(),
          "label",
          weight,
        ))
      },
    ),
    list.map(
      [view.Neutral, view.Success, view.Warning, view.Failure, view.Info],
      fn(tone) { element.to_string(view.tone_icon(tone)) },
    ),
    list.map(
      [
        view.logo_icon(),
        view.theme_icon(),
        view.language_icon(),
        view.info_icon(),
        view.check_circle_icon(),
        view.warning_triangle_icon(),
        view.x_circle_icon(),
        view.copy_icon(),
        view.plus_icon(),
        view.trash_icon(),
        view.pencil_icon(),
        view.plug_icon(),
        view.eye_icon(),
        view.key_icon(),
        view.rotate_icon(),
        view.users_icon(),
        view.clock_icon(),
        view.puzzle_icon(),
      ],
      element.to_string,
    ),
  ])
}
