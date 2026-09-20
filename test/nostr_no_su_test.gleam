import gleeunit

/// テスト全体のエントリポイント。gleeunit が `*_test` 関数を集めて実行する。
///
/// 出力には次の行が混ざる。どれも検証したい振る舞いそのものなので、logger の水準を
/// 下げず、標準出力も抑えずにそのまま出している。
///
/// - `=SUPERVISOR REPORT=`: スーパービジョンツリーの復帰を確かめるテストがアクターや
///   プラグインの子を kill するためと、到達できない DB を使うテストでプール
///   （`pgo_pool_sup`）が接続に失敗するため
/// - `=ERROR REPORT=` の `beam_load` の行: プラグインローダーが壊れた BEAM を拒否する
///   ことを確かめているため
/// - `=NOTICE REPORT=`: バンカーの読み込み完了や管理 UI の操作など、アプリ自身が
///   通常運転として出す 1 行ログが OTP logger の notice 水準で出るため
/// - `=WARNING REPORT=`: wisp の `csrf_known_header_protection` が出す
///   `Origin-host mismatch`（別オリジンや `Host` の食い違う POST を拒否する管理 UI の
///   テスト）と、バンカー・管理 UI・プラグインが障害や無効化を報告する 1 行ログ
/// - アプリの 1 行ログ（`[bunker]`、`[admin]`、`[relay <中継名>]`、
///   `[plugin <プラグイン名>]`、`relay_client_test` の中継名の `[test]`、保存の再試行
///   を報告する `[resume_saver]`）: 障害や変更を起こすテストが本番と同じログの経路を
///   通るため
/// - `[account_store]`、`[account_reconcile]`、`[app]`、`[resume_store]`、
///   `[plugin_resume_store]` の skip の行:
///   `TEST_DATABASE_URL` が無いときに統合テストを飛ばしたことを知らせる
pub fn main() -> Nil {
  gleeunit.main()
}
