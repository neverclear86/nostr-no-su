//// 管理 UI のページ枠と共通の部品（`admin/view`）の単体テスト。

import gleam/list
import gleam/string
import lustre/element
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
