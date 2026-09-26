//// テストが共有する、アカウント 1 件への操作の列挙。本体の一覧から操作が漏れたときに、
//// パスの往復のテストで検出できるよう、本体の一覧（`admin/routes` の
//// `account_actions`）を使わない。

import nostr_no_su/admin/routes

/// アカウント 1 件への操作のすべて（どれも POST のフォームを持つ）。
pub const all = [
  routes.EditLabel,
  routes.RotateSecret,
  routes.DeleteAccount,
  routes.RevealPrivateKey,
]
