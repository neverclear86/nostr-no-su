//// テストが共有する、アカウント 1 件への操作の列挙。本体の一覧から操作が漏れたときに、
//// パスの往復のテストで検出できるよう、本体の一覧（`admin/dashboard` の
//// `account_actions`）を使わない。

import nostr_no_su/admin/dashboard

/// アカウント 1 件への操作のすべて。
pub const all = [
  dashboard.EditLabel,
  dashboard.RotateSecret,
  dashboard.DeleteAccount,
  dashboard.RevealPrivateKey,
]
