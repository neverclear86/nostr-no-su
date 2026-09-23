// 管理 UI のスクリプト。ページ枠（src/nostr_no_su/admin/view.gleam の page）が全ページで
// モジュールとして読む。CSP（script-src 'self'）がインラインのスクリプトとイベント属性を実行させない
// ので、処理はこのファイルに置き、要素には data-action 属性で処理の名前だけを付ける。
//
// 文書に付けた 1 つのリスナーが、押された要素に最も近い [data-action] の名前で actions の関数を
// 呼ぶ（イベントの委譲）。処理を足すときは、actions に `名前(要素, イベント) {` の形で関数を足し、
// 描画のモジュールで要素に data-action を付ける（test/script_test.gleam が、描画しうる名前が
// すべてここにあることを検査する）。フォームの送信と画面の遷移は JS なしで動くので、ここには
// 表示を補う処理だけを置く。
//
// 押された要素の処理のほかに、読み込み時に `<time datetime>` の本文を閲覧者のローカルの時刻に
// 直す（サーバーは UTC で描く。view.gleam の time_of_day）。開いた状態で描いたダイアログもモーダルに開き直す。

const actions = {
  // コピーのボタン。直前の兄弟要素の入力欄を選択してクリップボードへ書き、書けたときだけ
  // コピーの欄の囲み（ボタンの親の親）に data-copied を 2 秒付ける。書けないときは data-selected を
  // 付け、欄の下に手動でコピーする案内を出す（2 秒では消さない）。値は DOM から読む。
  // 直前の data-copied が消える前に書けなかった場合に備え、data-selected を付ける前に
  // data-copied とその予約したタイマーを消す（両方が同時に見える状態を作らない）。
  copy(button) {
    const field = button.previousElementSibling;
    const wrapper = button.parentElement.parentElement;
    field.select();
    const selected = () => {
      clearTimeout(wrapper.copiedTimer);
      delete wrapper.dataset.copied;
      wrapper.dataset.selected = "1";
    };
    if (!navigator.clipboard) return selected();
    navigator.clipboard.writeText(field.value).then(() => {
      delete wrapper.dataset.selected;
      wrapper.dataset.copied = "1";
      clearTimeout(wrapper.copiedTimer);
      wrapper.copiedTimer = setTimeout(() => {
        delete wrapper.dataset.copied;
      }, 2000);
    }, selected);
  },
};

document.addEventListener("click", (event) => {
  const target = event.target.closest("[data-action]");
  if (target && Object.hasOwn(actions, target.dataset.action)) {
    actions[target.dataset.action](target, event);
  }
});

// <time datetime> の本文を、datetime 属性の時刻を閲覧者のローカルの時刻で表した時分秒にする。
// 書式はページの言語（<html lang>）に従う。
for (const element of document.querySelectorAll("time[datetime]")) {
  element.textContent = new Date(element.dateTime).toLocaleTimeString(
    document.documentElement.lang,
  );
}

// POST の応答で open 属性付きで描いたダイアログ（view.gleam の dialog）を、背景を操作できないモーダルに開き直す。
// showModal() は開いているダイアログには例外を投げるので、閉じてから開き直す。
for (const dialog of document.querySelectorAll("dialog[open]")) {
  dialog.close();
  dialog.showModal();
}
