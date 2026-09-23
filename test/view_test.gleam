//// 管理 UI のページ枠と共通の部品（`admin/view`）の単体テスト。

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/element
import lustre/element/html
import nostr_no_su/admin/i18n
import nostr_no_su/admin/view

/// 64 桁の 16 進のように長い値は、先頭 10 桁と末尾 6 桁を `…` でつなぐ。
pub fn shorten_keeps_the_head_and_tail_test() {
  let hex = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  assert view.shorten(hex) == "0123456789…abcdef"
}

/// 17 文字以下の値はそのまま返す。
pub fn shorten_returns_short_values_unchanged_test() {
  assert view.shorten("01234567890123456") == "01234567890123456"
  assert view.shorten("") == ""
}

/// 状態のチップは、変種ごとに決まったクラスとアイコンで描く。未使用だけ点線の枠で、
/// ほかは薄い塗りにトーンの色を付ける（中立は色の修飾なし）。
pub fn status_chip_follows_the_state_vocabulary_test() {
  let soft = "badge badge-soft badge-sm whitespace-nowrap gap-1"
  let cases = [
    #(view.ActiveChip, soft <> " badge-success", "m9 12 2 2 4-4"),
    #(view.DisconnectedChip, soft <> " badge-warning", "m19 5 3-3"),
    #(view.UnansweredChip, soft <> " badge-warning", "M12 6v6l4 2"),
    #(
      view.UnusedChip,
      "badge badge-dash badge-sm whitespace-nowrap gap-1",
      "M8 12h8",
    ),
    #(view.OverloadedChip, soft <> " badge-warning", "m12 14 4-4"),
    #(view.DisabledChip, soft <> " badge-error", "M4.929 4.929 19.07 19.071"),
    #(view.LoadFailedChip, soft <> " badge-error", "M15.312 2a2 2 0 0 1"),
    #(view.SecretNotOfferedChip, soft, "M20 13c0 5-3.5 7.5-7.66 8.95"),
    #(view.SecretMismatchChip, soft <> " badge-warning", "M12 8v4"),
    #(view.ToneChip(view.Neutral), soft, "M12 16v-4"),
    #(view.ToneChip(view.Success), soft <> " badge-success", "m9 12 2 2 4-4"),
    #(view.ToneChip(view.Warning), soft <> " badge-warning", "M12 9v4"),
    #(view.ToneChip(view.Failure), soft <> " badge-error", "m15 9-6 6"),
    #(view.ToneChip(view.Info), soft <> " badge-info", "M12 16v-4"),
  ]
  use #(chip, class, path) <- list.each(cases)
  let html = element.to_string(view.status_chip(chip, "t"))
  assert string.contains(html, "class=\"" <> class <> "\"")
  assert string.contains(html, path)
}

/// ボタンの種類と置き場所の組ごとに、daisyUI のクラスが決まる。行は `button_link`、
/// フォームは `post_form` の送信ボタンで確かめる。
pub fn button_kinds_map_to_daisyui_classes_test() {
  let focus = " focus-visible:outline-base-content"
  let cases = [
    #(view.PrimaryButton, view.InRow, "btn btn-primary btn-sm"),
    #(view.OutlineButton, view.InRow, "btn btn-outline btn-sm"),
    #(view.GhostButton, view.InRow, "btn btn-ghost btn-sm"),
    #(view.DangerButton, view.InRow, "btn btn-error btn-sm"),
    #(view.DangerGhostButton, view.InRow, "btn btn-ghost btn-sm text-error"),
    #(
      view.WarningOutlineButton,
      view.InRow,
      "btn btn-outline btn-warning btn-sm",
    ),
    #(view.PrimaryButton, view.InForm, "btn btn-primary self-start"),
    #(view.OutlineButton, view.InForm, "btn btn-outline self-start"),
    #(view.GhostButton, view.InForm, "btn btn-ghost self-start"),
    #(view.DangerButton, view.InForm, "btn btn-error self-start"),
    #(
      view.DangerGhostButton,
      view.InForm,
      "btn btn-ghost self-start text-error",
    ),
    #(
      view.WarningOutlineButton,
      view.InForm,
      "btn btn-outline btn-warning self-start",
    ),
  ]
  use #(kind, placement, class) <- list.each(cases)
  let html = case placement {
    view.InRow -> element.to_string(view.button_link("/", "t", kind))
    view.InForm ->
      element.to_string(view.post_form("/", [], "t", kind, view.InForm))
  }
  assert string.contains(html, "class=\"" <> class <> focus <> "\"")
}

/// 節の見出しは、`primary` を薄く混ぜた面のアイコン、題の直後の件数のピル、補助の文字の色の
/// 説明、右端の操作の並びを出す。
pub fn section_heading_shows_the_count_description_and_actions_test() {
  let html =
    element.to_string(
      view.section_heading(
        view.plug_icon(),
        "Relays",
        Some(2),
        Some("Where the bunker listens."),
        [view.hint("action")],
      ),
    )
  assert string.contains(
    html,
    "<span class=\"grid size-7.5 shrink-0 place-items-center rounded-field bg-primary/13 text-primary\"><svg",
  )
  assert string.contains(
    html,
    "Relays</h2><span class=\"badge badge-sm border-base-300 bg-base-100 font-mono font-bold text-muted tabular-nums\">2</span>",
  )
  assert string.contains(
    html,
    "<p class=\"text-sm text-muted sm:pl-10\">Where the bunker listens.</p>",
  )
  assert string.contains(
    html,
    "<div class=\"flex flex-wrap justify-end gap-2\"><p class=\"text-sm text-muted\">action</p></div>",
  )
}

/// 件数、説明、操作を渡さなければ、ピル、説明の行、操作の並びを出さない。
pub fn section_heading_leaves_out_the_absent_parts_test() {
  let html =
    element.to_string(
      view.section_heading(view.plug_icon(), "Relays", None, None, []),
    )
  assert !string.contains(html, "badge")
  assert !string.contains(html, "<p class")
  assert !string.contains(html, "justify-end")
}

/// 行の一覧は面と枠線を持つ `list` で、行は並べ方ごとのクラスを `list-row` に重ねる。
pub fn row_list_frames_the_rows_test() {
  let html =
    element.to_string(
      view.row_list([
        view.list_row(view.InlineRow, [html.text("a")]),
        view.list_row(view.StackedRow, [html.text("b")]),
      ]),
    )
  assert html
    == "<ul class=\"list rounded-box border border-base-300 bg-base-100\">"
    <> "<li class=\"list-row flex flex-wrap items-center justify-between gap-x-6 gap-y-3\">a</li>"
    <> "<li class=\"list-row flex flex-col gap-3\">b</li></ul>"
}

/// 全幅の帯は、`id` を付けた `section` に、`primary` を混ぜた地と枠、縦に積むクラスを付ける。
pub fn band_stacks_its_content_test() {
  let html = element.to_string(view.band("pending", [html.text("content")]))
  assert html
    == "<section class=\"flex flex-col gap-4 rounded-box border border-primary/28 bg-primary/8 p-4 sm:p-6\" id=\"pending\">content</section>"
}

/// 残り時間は「分:秒」にし、秒を 2 桁に 0 埋めし、負の値を 0 とみなす。
pub fn countdown_pads_seconds_test() {
  assert view.countdown(492) == "8:12"
  assert view.countdown(45) == "0:45"
  assert view.countdown(600) == "10:00"
  assert view.countdown(-3) == "0:00"
}

/// コピーのボタンは、アイコンだけを見せ、語を `aria-label` と `title` に置き、`copy` の処理を指す。
pub fn copy_button_names_the_copy_action_test() {
  let html = element.to_string(view.copy_button("Copy client"))
  assert string.starts_with(
    html,
    "<button aria-label=\"Copy client\" class=\"btn btn-ghost btn-sm btn-square text-muted group-data-copied:text-success focus-visible:outline-base-content\" data-action=\"copy\" title=\"Copy client\" type=\"button\">",
  )
}

/// 時刻の部品は、`datetime` 属性に RFC 3339 の UTC の全文を置き、本文に 0 埋めした UTC の時分秒を
/// 表示の言語の「UTC」の表記つきで出す（JS が無いときに見える形）。
pub fn time_of_day_renders_utc_with_datetime_test() {
  let cases = [
    #(i18n.English, "05:02:04 UTC"),
    #(i18n.Japanese, "05:02:04（UTC）"),
  ]
  use #(language, text) <- list.each(cases)
  let html = element.to_string(view.time_of_day(language, 1_789_275_724))
  assert html == "<time datetime=\"2026-09-13T05:02:04Z\">" <> text <> "</time>"
}
