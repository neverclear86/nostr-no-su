//// ビルドした管理 UI のスタイルシート（`priv/static/admin.css`）の検査。

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import nostr_no_su/admin/account_pages
import nostr_no_su/admin/dashboard
import nostr_no_su/admin/view
import nostr_no_su/bunker/engine
import nostr_no_su/plugin_runner
import nostr_no_su/relay_connection
import support/account_actions

/// ファイルの中身を読む。
@external(erlang, "file", "read_file")
fn read_file(path: String) -> Result(BitArray, Dynamic)

/// 描画しうるページのクラスは、どれもビルドした CSS に定義がある。Tailwind はソースに完全な
/// 文字列で書かれたクラスしか出力しないので、連結で組み立てたクラス、綴りの誤り、CSS の
/// ビルドし直し忘れは、ここで定義の無いクラスとして見つかる。
pub fn stylesheet_defines_every_rendered_class_test() {
  let assert Ok(bytes) = read_file("priv/static/admin.css")
  let assert Ok(css) = bit_array.to_string(bytes)
  let undefined =
    pages()
    |> list.flat_map(classes)
    |> list.unique
    |> list.filter(fn(class) { !defines(css, class) })
  assert undefined == []
}

/// フォーカスできるボタン（`a` と `button` の `btn`）はフォーカスの輪郭を、入力欄（`input` の
/// `input`）は枠を、`base-content` の色にする（デザイン方針 6 節の規則）。daisyUI の既定では
/// 輪郭が塗りの色になり、枠は薄いので、付け忘れるとコントラストが足りなくなる。付け忘れても
/// クラスはほかの文字列で CSS に出力されるので、定義の検査では見つからない。フォーカス
/// できない要素（#50 の表示中の言語の `span` など）の `btn` は対象にしない。
pub fn buttons_and_inputs_follow_the_color_rules_test() {
  let violations =
    pages()
    |> list.flat_map(tagged_classes)
    |> list.unique
    |> list.filter(fn(element) {
      let #(tag, classes) = element
      case tag {
        "a" | "button" ->
          list.contains(classes, "btn")
          && !list.contains(classes, "focus-visible:outline-base-content")
        "input" ->
          list.contains(classes, "input")
          && !list.contains(classes, "border-base-content/60")
        _ -> False
      }
    })
  assert violations == []
}

/// 状態ごとに違うクラスがすべて現れるよう、描画のどの分岐も通したページ。描画に状態の
/// 分岐を足したら、ここにもその状態のページを足す。
fn pages() -> List(String) {
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
      pending: [],
      relays: [],
      sessions: [],
      plugins: [],
    )
  let full =
    dashboard.Snapshot(
      accounts: Ok([row]),
      pending: [pending],
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
      sessions: [engine.Session(signer: "abcd", client: "ef01")],
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
  list.flatten([
    [
      dashboard.render(full),
      dashboard.render(empty),
      dashboard.render(dashboard.Snapshot(..empty, accounts: Error("reason"))),
      dashboard.approval_page(pending),
      account_pages.new_account_page(Some("reason")),
      account_pages.generated_key_page("nsec1example", Some("reason")),
      account_pages.registered_page("npub1example", "main", "nsec1example"),
      account_pages.private_key_page(row, "nsec1example"),
    ],
    list.map(
      [view.Neutral, view.Success, view.Warning, view.Failure],
      dashboard.notice_page("Notice", "reason", _),
    ),
    list.map(account_actions.all, account_pages.account_action_page(
      row,
      _,
      Some("reason"),
    )),
  ])
}

/// ページの `class` 属性に現れるクラス名。値はエスケープされて `"` を含まないので、次の `"` までが
/// 属性値である。
fn classes(page: String) -> List(String) {
  page
  |> string.split(" class=\"")
  |> list.drop(1)
  |> list.flat_map(fn(rest) {
    let assert Ok(#(value, _)) = string.split_once(rest, "\"")
    string.split(value, " ")
  })
}

/// ページの開始タグごとの、要素名と `class` 属性のクラス名。`class` 属性の無い要素は含めない。
/// テキストと属性値はエスケープされて `<` と `>` を含まないので、`<` から次の `>` までが
/// 開始タグである。
fn tagged_classes(page: String) -> List(#(String, List(String))) {
  page
  |> string.split("<")
  |> list.filter_map(fn(chunk) {
    use #(tag, _) <- result.try(string.split_once(chunk, ">"))
    use #(name, attributes) <- result.try(string.split_once(tag, " "))
    use #(_, rest) <- result.try(string.split_once(attributes, "class=\""))
    use #(value, _) <- result.map(string.split_once(rest, "\""))
    #(name, string.split(value, " "))
  })
}

/// CSS にクラスのセレクターがあるか。`.btn` が `.btn-sm` の先頭に一致しないよう、セレクターの
/// 直後がクラス名の続きでないものだけを数える。
fn defines(css: String, class: String) -> Bool {
  css
  |> string.split("." <> escape_selector(class))
  |> list.drop(1)
  |> list.any(fn(rest) { !continues_class_name(rest) })
}

/// Tailwind がセレクターの中でエスケープする記号を、バックスラッシュでエスケープする。
fn escape_selector(class: String) -> String {
  list.fold(
    [":", "/", "[", "]", "(", ")", ",", "."],
    class,
    fn(escaped, symbol) { string.replace(escaped, symbol, "\\" <> symbol) },
  )
}

/// 文字列がクラス名の続き（英数字、`-`、`_`、エスケープ）で始まるか。
fn continues_class_name(rest: String) -> Bool {
  case string.first(rest) {
    Ok(char) ->
      string.contains(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_\\",
        char,
      )
    Error(Nil) -> False
  }
}
