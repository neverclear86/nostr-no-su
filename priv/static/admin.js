// 管理 UI のスクリプト。ページ枠（src/nostr_no_su/admin/view.gleam の page）が全ページで
// モジュールとして読む。CSP（script-src 'self'）がインラインのスクリプトとイベント属性を実行させない
// ので、処理はこのファイルに置き、要素には data-action 属性で処理の名前だけを付ける。
//
// 文書に付けた 1 つのリスナーが、押された要素に最も近い [data-action] の名前で actions の関数を
// 呼ぶ（イベントの委譲）。処理を足すときは、actions に `名前(要素, イベント) {` の形で関数を足し、
// 描画のモジュールで要素に data-action を付ける（test/script_test.gleam が、描画しうる名前が
// すべてここにあることを検査する）。フォームの送信と画面の遷移は JS なしで動くので、ここには
// 表示を補う処理だけを置く。

const actions = {
  // コピーのボタン。直前の兄弟要素の入力欄を選択してクリップボードへ書き、書けたときだけ
  // コピーの欄の囲み（ボタンの親の親）に data-copied を 2 秒付ける。値は DOM から読む。
  copy(button) {
    const field = button.previousElementSibling;
    const wrapper = button.parentElement.parentElement;
    field.select();
    if (!navigator.clipboard) return;
    navigator.clipboard.writeText(field.value).then(() => {
      wrapper.dataset.copied = "1";
      clearTimeout(wrapper.copiedTimer);
      wrapper.copiedTimer = setTimeout(() => {
        delete wrapper.dataset.copied;
      }, 2000);
    });
  },
};

document.addEventListener("click", (event) => {
  const target = event.target.closest("[data-action]");
  if (target && Object.hasOwn(actions, target.dataset.action)) {
    actions[target.dataset.action](target, event);
  }
});
