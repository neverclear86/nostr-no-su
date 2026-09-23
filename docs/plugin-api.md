# プラグイン API v1

Nostr-no-Su は、バンカーに登録したアカウントのイベントを受け取るプラグインを BEAM のモジュールとして読み込む。この文書はプラグインを書くために必要な仕様をまとめたもので、対象は API バージョン 1 である。

本体側の実装は `src/nostr_no_su/plugin.gleam`（検証と読み込み）、`src/nostr_no_su/plugin_loader.gleam`（走査とコードパスへの追加）、`src/nostr_no_su/plugin_config.gleam`（プラグイン固有の設定の切り出し）、`src/nostr_no_su/nostr/event.gleam`（イベント map の変換）、`src/nostr_no_su/admin/plugin_view.gleam`（ページの記述から管理 UI の部品への変換）、`src/nostr_no_su/admin/plugin_pages.gleam`（ページ枠とタブの組み立て）、`src/nostr_no_su/plugin_api.gleam`（プラグインが呼ぶ本体側の口）にある。

## 1. 目的と信頼モデル

プラグインは、監視で受信したイベント 1 件ごとに呼ばれる処理を差し込む仕組みである。イベントを DB へ保存する、外部サービスへ通知する、といった用途を想定している。監視が受け取るのは、バンカーに登録した全アカウントが作ったイベントで、ephemeral イベント（kind 20000〜29999。バンカーの NIP-46 の通信を含む）は含まない。監視は、リレーが返したイベントの作者を登録アカウントと照合する。登録していないアカウントのイベントは、リレーが返してもプラグインへ渡さない（取り直しの購読で届いたものも同じ）。

**プラグインは信頼できるものだけを置くこと。** プラグインはサンドボックスの中では動かない。本体と同じ BEAM の VM で動くため、次のことができてしまう。

- 秘密鍵を保持しているプロセスへ到達する（`sys:get_state/1` など）
- 本体のアクターへメッセージを送る、プロセスを停止させる
- ファイルシステムやネットワークへ自由にアクセスする

したがってプラグインディレクトリは、サーバーの管理者が内容を把握しているモジュールだけを置く場所として扱う。第三者から受け取ったプラグインは、ソースを読んでから置くこと。

## 2. モジュールの要件

プラグインは 1 つの BEAM モジュールである。次の 3 つを必ずエクスポートする。

| 関数 | アリティ | 戻り値 | 本体側の検証 |
| --- | --- | --- | --- |
| `plugin_api_version` | 0 | 整数 | `1` と完全一致すること |
| `plugin_name` | 0 | 文字列（Erlang の binary） | 文字列であり、空でないこと |
| `handle_event` | 1 **または** 2 | 任意（無視する） | どちらか一方が存在すること |

- `plugin_name/0` の値は管理 UI の表示名とログの識別子に使う。**プラグイン間で一意にすること。**
- **`handle_event` は `/1` と `/2` のどちらか一方があればよい。** `/2` はプラグイン固有の設定を第 2 引数で受け取る形で（第 6 章）、両方あれば本体は `/2` を優先する。**設定が必須のプラグインは `/2` だけをエクスポートしてよい。** 設定が無ければ正しく書けない `handle_event/1` を、形だけ揃えるために持たせる必要はない。
- 上記以外のエクスポートは自由に増やしてよい。未知のエクスポートは読み込みに影響しない。本体が使う任意エクスポート（`plugin_children`、`plugin_min_host_version`、`plugin_required_versions`、`plugin_pages`、`plugin_page_content`、`plugin_page_action`）は存在するときだけ呼ばれ、その結果で読み込まれないことがある。
- **`plugin_api_version/0` と `plugin_name/0`、任意エクスポートの `plugin_children/0` `/1` `plugin_min_host_version/0` `plugin_required_versions/0` `plugin_pages/0` `/1` は即座に戻ること。** 本体は起動時にこれらを 1 回ずつ使い捨てのプロセスで呼び、5 秒以内に戻らなければそのプロセスを kill して、そのプラグインを読み込まない（起動は続く）。定数を返すか、受け取った設定を検査するだけにし、時間のかかる準備は子プロセス（第 5 章）に任せる。呼び出しのプロセスは戻るとすぐに正常でない理由で終わる（打ち切りでは `killed`）。そこでリンクして起こしたプロセス（`spawn_link` や `*_start_link`）は、exit を trap していなければ一緒に終わり、trap していれば `{'EXIT', Pid, Reason}` を受け取る。そこで作った登録名、プロセス辞書、ETS テーブル、ポートは所有者の終了で消える。プロセスは子仕様（第 5 章）で起こすこと。
- **`-on_load` を使うなら即座に戻ること。** 本体はモジュールの読み込み（`code:ensure_loaded/1`）もメタデータの呼び出しと同じ 5 秒の期限で打ち切り、戻らなければそのプラグインを読み込まない（起動は続く）。打ち切っても `-on_load` の処理そのものは VM の中で走り続けるので、その中で待ち合わせをしないこと。

## 3. イベント map の仕様

イベント処理関数が第 1 引数に受け取るのは、NIP-01 のイベントを表す **Erlang の map** である。キーは次の 7 つで、**すべて binary**（`<<"id">>` など）。

| キー | Erlang 上の型 |
| --- | --- |
| `<<"id">>` | binary（64 文字の小文字 16 進） |
| `<<"pubkey">>` | binary（64 文字の小文字 16 進） |
| `<<"created_at">>` | integer（Unix 秒） |
| `<<"kind">>` | integer |
| `<<"tags">>` | binary のリストのリスト |
| `<<"content">>` | binary（UTF-8） |
| `<<"sig">>` | binary（128 文字の小文字 16 進） |

リテラルで書くと次の形になる。

```erlang
#{
    <<"id">> => <<"556f29ae…2385">>,
    <<"pubkey">> => <<"3bf0c63f…459d">>,
    <<"created_at">> => 1700000000,
    <<"kind">> => 1,
    <<"tags">> => [[<<"t">>, <<"test">>]],
    <<"content">> => <<"hello nostr">>,
    <<"sig">> => <<"00…">>
}
```

形は NIP-01 の JSON オブジェクトと同一なので、受け取った map をそのまま JSON へエンコードしたり、既存の Nostr ライブラリーへ渡したりできる。

注意点が 2 つある。

- **atom キーは受け付けない。** Elixir では `%{id: ...}` と書きがちだが、この map のキーは binary である。パターンマッチは `#{<<"kind">> := Kind}` と書くこと。
- **知らないキーは無視すること。** 将来キーが追加されても API バージョンは上がらない（第 7 章）。`#{<<"kind">> := Kind}` のような部分マッチは安全だが、7 キーちょうどを前提にした処理は壊れる。

## 4. 実行モデル

- イベント処理関数は**プラグインごとの専用プロセス**（ランナー）から、**イベント 1 件ごとに作られる使い捨てのプロセス**の上で呼ばれる。重複排除ディスパッチャーはイベントを各ランナーへ送るだけで戻る。
- したがって**プラグイン同士の実行順序は保証されない。** 同じプラグインの中では、イベントは届いた順に 1 件ずつ処理される。
- `self()` もプロセス辞書も**呼び出しをまたいで残らない。** 呼び出しごとに別のプロセスだからである。状態を持ちたいプラグインは自分でプロセスを起こし、その宛先をイベント処理関数から参照すること。起こしたプロセスは本体のスーパービジョンツリーに載せられる（第 5 章）。
- **戻り値は無視される。** Erlang / Elixir なら `ok`、Gleam なら `Nil` を返すのが自然で、どちらでもよい。**正常終了とはイベント処理関数から戻ることである。** プラグインが自分で `exit(normal)` を呼んだ場合は失敗として数える。
- **例外・異常終了は隔離される。** 落ちるのは使い捨てのプロセスだけで、ディスパッチャーも監視のリレー接続も他のプラグインも影響を受けない。プラグインの障害でスーパーバイザーの再起動が起きることはない。
- **クラッシュの詳細は本体がログに出す。** 本体はワーカーの中で例外を捕まえ、終了理由を `error:badarg` の形の 1 行に整える。そのため **BEAM の標準 error report は出ない。** 代わりに、理由とスタックトレース（いずれも長さを切ったもの）を本体が 1 行のログとして出力する。これはイベント処理関数の失敗に限った話で、プラグインが申告した子プロセス（第 5 章）のクラッシュは BEAM の標準レポートとして出る。
- **`handle_event/2` があればそちらが呼ばれ**、第 2 引数にプラグイン固有の設定 map が渡る（第 6 章）。**どちらのアリティを呼ぶかの判定は読み込み時に 1 度だけ行う**ので、イベントごとのコストは増えない。
- **1 件あたりの実行時間には上限（30 秒）がある。** 超えるとワーカーを打ち切り、その 1 件を失敗として数える。
- **連続 5 回失敗したプラグインは無効化される。** 以後イベントは渡らず、捨てた件数を数えるだけになる。管理 UI の Plugins 欄には `disabled: <理由>` として残る。**再有効化の手段は 2 つ**で、本体の再起動と、管理 UI の Plugins 欄の「再有効化」（`Re-enable`）ボタンである。ボタンはランナーを `running` に戻し、連続失敗数を 0 から数え直す。無効の間に捨てたイベントは、再有効化のときにそのプラグインの再開点から取り直して配信する（第 4.2 節）。ホットリロードは対象外。ただし、子プロセスを諦めた後（第 5 章）は再有効化しても子は戻らない。子を失ったプラグインは再有効化しても連続 5 回で再び無効になる。この場合の復帰は本体の再起動だけである。
- **未処理のイベントが 1000 件を超えると、500 件以下に減るまでイベントを捨てる。** 減った時点で捨てた件数をログへ報告し、配信を再開する。**捨てるのは超過分だけではなく、そのとき積まれていたバックログのうち新しい側の約 500 件を除く全部である。** 上限をわずかに超えただけなら約半分で済むが、キュー長を確かめるのはイベントを 1 件取り出すときだけなので、1 件の実行（最大 30 秒）の間に届いたイベントの分だけ、気付いた時点のバックログは上限を大きく超えうる。一度に大量のイベントが届くバースト（再開点の無いリレーへの最初の購読で、リレーが保存済みイベントをまとめて返す場合など）では、上限を超えるたびにこれが起きる。**したがって配信は best-effort であり、遅いプラグインは取りこぼす。** 取りこぼしたくない処理は、イベント処理関数を短く保って自前のプロセスへ渡すこと。この切り捨ては復帰したときの取り直し（第 4.2 節）の対象ではない。取り直すのは無効化と再起動の間に渡らなかったぶんだけである。
- **ランナーの再起動中に届いたイベントは、その場では渡らない。** ディスパッチャーはその件数を数え、ランナーに再び届いた時点でログへ報告する（第 4.1 節）。再起動したランナーは保存済みの再開点から取り直しを要求するので、その分は後から配信されうる（第 4.2 節）。
- 同じイベント（同じ `id`）が複数のリレーから届いても、**通常は**イベント処理関数は 1 回しか呼ばれない。ただし重複排除は有界なウィンドウ（直近の id を一定件数だけ記憶する）で行うため、容量を超えて古い id が押し出された後に同じイベントが再配信されると 2 回目が呼ばれる。ディスパッチャーが再起動したときもウィンドウは空になり、あわせて監視のリレー接続も張り直されるため、リレーが保存済みイベントを再送すれば同じイベントがもう一度届く。張り直した購読は DB に保存した再開点から始まるので、再送されるのは再開点以降のイベントである。本体の停止（正常な停止を含む）や異常終了のときも、最後の保存からの数秒ぶんのイベントがもう一度届きうる。
- したがって**イベント処理関数は冪等に書くこと。** 同じイベントを 2 回処理しても結果が変わらないようにする（保存するなら `id` を一意キーにする、通知するなら送信済みの `id` を記録する、など）。重複排除は重複を防ぎきらず（exactly-once ではない）、上のとおり取りこぼしもある（best-effort）。

> Gleam で書いたプラグインの `panic` は、理由そのものに `file` / `line` / `message` が入るため冗長になり、切り詰められて読みにくくなる。外部プラグインは `erlang:error/1` を使うか、失敗を素直に返す形を選ぶとログが読みやすい（下の表の `error:badarg` は Erlang プラグインの形）。

### 4.1 実行時のログ行

接頭辞は `plugin <plugin_name/0 の値>` で、第 8.5 節の表（接頭辞 `plugin_loader` の読み込み失敗）とは別物である。

| 行 | 意味 |
| --- | --- |
| `handle_event failed (error:badarg); 2/5 at [{my_plugin,handle_event,1},...]` | 実行が失敗した。連続失敗数とスタックトレース（切り詰め）を添える |
| `disabled after 5 consecutive failures (error:badarg); events will be dropped` | 連続失敗の上限に達して無効化した |
| `handle_event failed (timed out after 30000ms); 1/5` | 1 件の実行が上限時間を超えて打ち切られた |
| `too slow: 1001 events queued (limit 1000); dropping until it catches up` | 未処理のイベントが上限を超えたので捨て始めた |
| `caught up; dropped 501 events while overloaded` | 未処理のイベントが上限の半分以下に減ったので配信を再開した |
| `runner is unavailable; dropping events until it is back` | ランナーが居ない（再起動中）ので、ディスパッチャーがイベントを捨て始めた |
| `runner is back; dropped 3 events while it was unavailable; it will re-request them if it has a resume point` | ランナーに再び届くようになった。居なかった間に捨てた件数を添える |
| `re-enabled by the operator; dropped 12 events while disabled; it will re-request them if it has a resume point` | 管理 UI から再有効化した。無効の間に捨てた件数を添える |
| `catch-up finished; re-delivered 7 events` | 取り直しの購読が保存済みイベントの終わりに達した。取り直しで渡した件数を添える |

プラグイン自身のログは OTP logger（`logger:log/2`）に出せば、時刻と水準が付いた本体と同じ行の形になる（`io:format` は時刻と水準が付かない）。実例は `plugins-src/event_logger`。この文書の例のコードは短さのために `io:format` を使う。

### 4.2 復帰したときの取り直し

復帰（本体の再起動、ランナーのクラッシュからの復帰、管理 UI からの再有効化）のときは、そのプラグインの再開点から復帰の時刻までの範囲でリレーへ取り直しを要求する。
ただし、その範囲のうちリレーごとの監視の購読がこれから運ぶ部分（その購読の再開点以降）は取り直しに含めないので、その部分のイベントは取り直しではなく通常の配信（第 4 章）で届く。
過負荷からの復帰では要求せず、再開点が保存されていなければ要求しない。
取り直しで届いたイベントは、取り直しを要求したプラグインにだけ渡る。
ランナーは取り直しで渡した id を有界なウィンドウで覚えているので、複数のリレーが同じ範囲を返しても 1 回しか渡らない。ランナーがクラッシュするとこの記憶も失われるため、同じイベントが 2 度渡ることはある。
取り直しは、リレーが保存済みイベントの終わり（EOSE）を告げた時点で終わり、件数をログに出して購読を閉じる。

## 5. 状態を持つプラグイン（任意エクスポート `plugin_children`）

イベント処理関数はイベントごとに別のプロセスで動くため、呼び出しをまたいで状態を持つには自分でプロセスを起こす必要がある（第 4 章）。任意エクスポート `plugin_children/0` を持つプラグインは、そのプロセスの子仕様を本体に申告できる。本体は起動時に 1 度だけこの関数を呼び（第 2 章の期限が掛かる）、返ってきた子仕様をスーパービジョンツリーに載せる。

```erlang
plugin_children() -> [child_spec()] | {error, Reason}.
```

**この関数は任意エクスポートであり、API バージョンは上げない**（第 7 章）。持たないプラグインは従来どおり動く。空のリストを返してもよい。`{error, Reason}` は読み込みを断る申告である（第 6.4 節）。

### 5.1 子仕様の形

子仕様は OTP の `supervisor:child_spec()` と同じ **map** である。Gleam のレコードではないので、Erlang でも Elixir でもそのまま書ける。

| キー | 型 | 既定値 | 本体側の検証 |
| --- | --- | --- | --- |
| `id` | atom または binary | なし（必須） | 存在すること。**OTP へは渡らない**（本体がログと理由の文字列に使う） |
| `start` | `{Module, Function, Args}` | なし（必須） | 3 要素タプルであること。実際の呼び出しは起動時と再起動時 |
| `restart` | `permanent` / `transient` / `temporary` | `permanent` | この 3 つのいずれか |
| `shutdown` | 非負整数（ミリ秒）または `infinity` | worker は `5000` | 整数か `infinity`。`brutal_kill` は不可 |
| `type` | `worker` / `supervisor` | `worker` | どちらか。`supervisor` のときは `shutdown` を書かないか `infinity` にすること |

受け付けない形が 3 つある。いずれも読み込み時に理由を 1 行出して、**そのプラグインを読み込まない**。

- **素の `{Module, Function, Args}` の短縮形。** `restart` も `shutdown` も `type` も表現できない。子仕様が map でないことは `child #0: must be a child specification map, got Array` として報告する。
- **`shutdown => brutal_kill`。** 本体が使う Gleam の子仕様が表現できない。`0` ミリ秒に丸めると意味が変わってしまう。
- **`type => supervisor` かつ `shutdown` が `infinity` 以外。** 本体側でスーパーバイザーの `shutdown` は `infinity` に固定されるため、書いた値が黙って別の意味になる。`shutdown => infinity` に直せば通る。

`ignore` を返す `start` も未対応である。本体は Pid を要求する。ただしこれは呼んでみるまで分からないので、検出は起動時になり、次節の「起動に失敗した子」と同じ扱いになる。

### 5.2 `start` の MFA に課す約束

- **必ずリンクを張る関数であること**（`gen_server:start_link/4` など）。本体は起動直後に、子が自分のリンク集合に入ったかを確かめる。生きているのに入っていない子は、その場で kill して起動失敗にする。リンクを張らない子は誰にも監視されず、落ちても気付かれないまま登録名だけを握り続けるからである。
- **`{ok, Pid}` または `{ok, Pid, Info}` を返すこと。** Gleam で書くときは注意が要る。`pog.start/1` の実際の戻り値は `{ok, {started, Pid, Conn}}` であって `{ok, Pid}` ではないため、本体が弾く。**Gleam のプラグインは `{ok, Pid}` を返す薄いシムを 1 つ書くこと。**
- **戻ること。** OTP のスーパーバイザーは子の起動にタイムアウトを持たない。`start` が戻らないとツリーの起動そのものが止まる。**本体もここに期限を設けない。** 期限を設けるには `start` を別のプロセスで呼ぶことになり、スーパーバイザーと子のリンクが張られなくなるためである（この節の最初の項目「必ずリンクを張る関数であること」）。
- **同梱したアプリケーションはプラグインが自分で起動すること。** 本体はコードパスを足すだけで、同梱したアプリケーションを起動しない（第 8.1 節）。必要なら `start` の MFA の中で `application:ensure_all_started/1` を呼ぶ。冪等なので、子が再起動するたびに呼ばれても害はない。**本体がたまたま同じアプリケーションを起動していても、それに依存しないこと。** 本体の依存は予告なく変わりうるし、本体を持たない環境でプラグインをテストすることもある（本体は現在アカウントストアのために `pgo` を起動しているが、`event_logger` は自分でも起動する）。実例が `plugins-src/event_logger/` である。`pgo` を起動しないと `pg_types` のアプリが立たず、`pgo_type_server` が `pg_types:update_map/3` の `application:get_key/2` で `badmatch` して即死し、接続プールごと落ちる。

### 5.3 登録名はプラグインの責任

本体は子プロセスの名前を作らず、渡しもしない。名前の登録は `start_link` の中で行うこと（`gen_server:start_link({local, Name}, ...)`）。MFA を丸ごとプラグインが書く以上、名前もそこで決まるのが自然である。

- **登録名は VM 全体で一意である。** プラグイン名を接頭辞にすること（`counter` プラグインなら `counter_store`）。衝突すると 2 つめの `register/2` が `badarg` で落ち、その子の起動が失敗する。
- **名前は再起動をまたいで同じでなければならない。** イベント処理関数は毎回別のプロセスで動くので宛先を握り続けられず、名前で引くしかない。

### 5.4 失敗のモデル

子は普通の OTP プロセスなので、プラグインごとに用意された専用のスーパーバイザー（`one_for_one`、10 秒に 5 回まで）の下で再起動する。この歯止めを超えると、**そのプラグインの子はまとめて諦められ、本体を再起動するまで戻らない**。以後イベント処理関数は宛先を失って失敗し、連続 5 回で `disabled` になる（第 4 章）。**本体の他の部分（監視、バンカー、他のプラグイン）は影響を受けない。** ランナー自身は生き続けるので、管理 UI にはそのプラグインが `disabled: <理由>` として残る。

起動時に子の起動が失敗した場合は、そのプラグインを子なしで動かして起動を続ける。**アプリは起動する。**

子の起動に失敗したときに読む行は 2 つある。

```
[plugin counter] child "counter_store" failed to start (error:badarg)
[plugin counter] children failed to start; the reason is in the child line above, or in the supervisor report; running without them
```

**理由が入っているのは 1 行目である。** 2 行目は理由を持っていない（スーパーバイザーの起動失敗は本体に理由を返さない）。上の例は登録名の衝突で、`start_link` の中の `register/2` が `badarg` で落ちた場合である。

**子のクラッシュは BEAM の標準レポートとして出る**（`error crasher: ...` / `error Supervisor: ...` の 1 行）。本体が 1 行に整えるイベント処理関数の失敗（第 4.1 節）とは扱いが違う。

**外部資源に依存する子は、落ちずに数えて捨てる形を勧める。** 諦められた子は本体の再起動まで戻らないため、DB や HTTP に到達できないあいだ落ち続ける子は、歯止めを使い切って恒久的に失われる。同梱の `event_logger` が DB 到達不能時に行っているのと同じく、到達できない件数を数えてプロセスは生かしておくほうがよい。

子の起動に必要な設定（接続文字列など）は、`plugin_children/1` の引数として受け取る（第 6 章）。設定が足りないときは子仕様を組み立てず、`{error, Reason}` を返してそのプラグインを読み込ませないこと。`{error, Reason}` は `plugin_children/0` も返せる（第 6.4 節）。

### 5.5 Erlang の例

`examples/plugins/counter/src/counter.erl` の抜粋である。全文とビルド方法は同ディレクトリーの README を参照すること。

```erlang
-module(counter).
-behaviour(gen_server).
-export([plugin_api_version/0, plugin_name/0, plugin_children/0, handle_event/1]).
-export([start_link/0, init/1, handle_call/3, handle_cast/2]).

-define(STORE, counter_store).

plugin_api_version() -> 1.
plugin_name() -> <<"counter">>.

plugin_children() ->
    [#{id => ?STORE,
       start => {?MODULE, start_link, []},
       restart => permanent,
       shutdown => 5000,
       type => worker}].

%% call を使うのは、store が居ないことをランナーに失敗として見せるため。
%% cast は宛先が居なくても成功するので、障害が黙って消える。
handle_event(#{<<"id">> := Id}) ->
    gen_server:call(?STORE, {seen, Id}).

start_link() -> gen_server:start_link({local, ?STORE}, ?MODULE, [], []).
init([]) -> {ok, 0}.
handle_call({seen, Id}, _From, Count) ->
    io:format("[counter] ~b events (last ~ts)~n", [Count + 1, Id]),
    {reply, ok, Count + 1};
handle_call(count, _From, Count) -> {reply, Count, Count}.
handle_cast(_Msg, Count) -> {noreply, Count}.
```

## 6. プラグイン固有の設定

出力先のパスや接続文字列のように、プラグインごとに違う値は**環境変数**で渡す。本体は起動時に環境変数を 1 度だけ読み、プラグイン名から決まる接頭辞に一致するものだけを、そのプラグインへ map として渡す。

### 6.1 渡し方

```
PLUGIN_<NAME>_<KEY>=<値>
```

- `<NAME>` は `plugin_name/0` の値を大文字にし、`[A-Z0-9]` 以外の文字を `_` に置き換えたものである。`file_logger` なら `PLUGIN_FILE_LOGGER_` が接頭辞になる。
- プラグインが受け取るのは `<KEY>` を**小文字にした binary キー**の map で、**値は環境変数の文字列そのまま**（binary）である。管理 UI のページと実行の呼び出し（第 13 章）に渡す map だけは、これに加えて予約キー `<<"Accounts">>` を持つ。キーを小文字にする規則があるため、大文字を含むこのキーが環境変数から作られることはない。この値もアカウントの一覧を JSON にした binary なので、設定 map を binary → binary の辞書として読む書き方はそのまま通る。

```sh
PLUGIN_FILE_LOGGER_PATH=/tmp/nostr-no-su-events.log
```

```erlang
#{<<"path">> => <<"/tmp/nostr-no-su-events.log">>}
```

- **値が空文字列の変数は未設定として落とす。** docker compose は未設定の変数を空文字列として渡すため、この規則が無いと必須チェックが空文字列を通してしまう。
- **キーは小文字にするので、大文字小文字だけが違う変数は衝突する。** `PLUGIN_X_PATH` と `PLUGIN_X_Path` を両方設定すると、プラグインからはどちらも `<<"path">>` になり、どちらの値が残るかは決まらない。片方だけを設定すること。
- **一致する変数が 1 つも無ければ空の map を渡す。** 「設定なし」を別の形（`undefined` など）にはしないので、プラグイン側の場合分けは増えない。
- **型変換は行わない。** 整数として読むべきか URL として読むべきかを本体は知らないため、変換はプラグインの責任である。失敗は次節の `{error, Reason}` で報告できる。
- **docker compose の `environment:` は明示的な列挙である。** 同梱の `docker-compose.yml` に自分のプラグインの変数を書き足さないと、ホストで設定してもコンテナーには届かない。

### 6.2 名前の正規化がもたらす曖昧さ

正規化の結果、次の 3 つが起こりうる。いずれもプラグイン名は一意なので、設定が別のプラグインへ**取り違えて届くことはない**。起きるのは「同じ値が複数のプラグインから見える」ことだけである。

1. **区切り文字の違いが潰れる。** `my-plugin` と `my_plugin` はどちらも `PLUGIN_MY_PLUGIN_` になる。
2. **名前が包含関係にあると重なる。** `event` という名前のプラグインは、`PLUGIN_EVENT_LOGGER_DATABASE_URL` を `logger_database_url` というキーとして見る。
3. **非 ASCII の名前はすべて `_` に潰れる。** `日本語` は `PLUGIN_____` になる。

**プラグイン名には ASCII（英小文字・数字・アンダースコア）を使うこと。** 環境変数名に非 ASCII を使うのは移植性がなく、上の 3 番はそれを避けるための挙動である。

### 6.3 受け取り方

設定を受け取る口は「**任意エクスポートのアリティ +1**」という 1 つの規則で足してある。管理 UI のページと実行の呼び出し（第 13 章）だけは、渡す設定 map に予約キー `Accounts`（値はアカウントの一覧を JSON にした文字列）が加わる。

| エクスポート | 本体の挙動 |
| --- | --- |
| `plugin_children/1` | あればこちらを呼び、設定 map を渡す。無ければ `plugin_children/0` を呼ぶ。どちらも無ければ問い合わせない |
| `handle_event/2` | あればこちらを呼び、第 2 引数に設定 map を渡す。無ければ `handle_event/1` を呼ぶ |
| `plugin_page_content/2` | あればこちらを呼び、第 2 引数に `Accounts` を含む設定 map を渡す。無ければ `plugin_page_content/1` を呼ぶ |
| `plugin_page_action/3` | あればこちらを呼び、第 3 引数に `Accounts` を含む設定 map を渡す。無ければ `plugin_page_action/2` を呼ぶ |

```erlang
plugin_children(Config) -> [child_spec()] | {error, Reason}.
handle_event(Event, Config) -> term().
```

`plugin_children/0` と `handle_event/1` しか持たないプラグインは**従来どおり動く**。設定を必要としないプラグインは何も変えなくてよい。

**設定 map は `plugin_name/0` の後にしか決まらない。** 接頭辞がプラグイン名から決まるため、本体の検証はモジュールの読み込み → 必須エクスポート → `plugin_api_version` → `plugin_min_host_version` → `plugin_required_versions` → `plugin_name` → 設定の切り出し → `plugin_children` の順に進む。

### 6.4 設定が足りないことの申告

`plugin_children/1` と `plugin_children/0` は、子仕様のリストの代わりに `{error, Reason}` を返せる。これは「**設定が足りない・不正なのでこのプラグインを読み込まないでほしい**」という申告である。`Reason` は binary で、環境変数名ではなく**キー名**を書けばよい（接頭辞は本体が添える）。

```erlang
plugin_children(#{<<"path">> := _Path}) -> [];
plugin_children(_Config) -> {error, <<"path is required">>}.
```

- **判別子は「1 番目の要素が atom の `error` であること」だけ**で、要素数は見ない。`{ok, 1}` のような他のタプルは子仕様のリストとして検証され、その形で弾かれる。
- **子プロセスを持たないプラグインも、設定の検査だけのためにこの関数を使える。** 設定が揃っていれば `[]` を返せばよい。上の例がその形である。
- 本体は次の 1 行をログに出し、**そのプラグインだけを無効にする。起動は止まらない**（走査の集計行では `skipped` に数えられる）。行の関数名は本体が呼んだアリティになり、`plugin_children/0` が返した場合も末尾に環境変数の接頭辞が付く。

  ```
  [plugin_loader] file_logger: plugin_children/1 rejected the configuration (path is required); configure it with PLUGIN_FILE_LOGGER_*
  ```

- **この行は子を持たないプラグインでも出る。** 関数名は「子仕様」と言っているが、設定は子仕様を組み立てるために要るものなので、設定の検査結果もこの関数から報告される。

宣言的な必須キーの一覧を本体に持たせていないのは、**値の妥当性まで検査できないため**である。`DATABASE_URL` が存在することと、それが Postgres の URL として解釈できることは別で、後者を読み込み時に検査できないと、不正な値が「子の起動失敗 → イベント処理の連続失敗 → `disabled`」という遠回りな症状に化ける。

### 6.5 古い本体との互換性

- `plugin_children/1` のような**普通の任意エクスポートは、知らない本体からは無視されるだけ**である。プラグインは設定を受け取らないまま動く。
- **`handle_event/2` だけをエクスポートするプラグインは違う。** この機能を持たない古い本体では `missing export handle_event/1` で丸ごと読み込まれない。`plugin_api_version() -> 1` と名乗っていても、v1 のすべての本体で動くとは限らない。

> `handle_event/2` だけをエクスポートするプラグインは、この機能を持つ本体でしか読み込めない。どの v1 本体でも動かしたいプラグインは `handle_event/1` もエクスポートすること。

この節の症状は版の下限の宣言では変わらない。必須エクスポートの検査は `plugin_min_host_version/0` の照合より先に走り、`handle_event/2` を知らない本体はこの任意エクスポートも知らないので、`missing export handle_event/1` のまま弾かれる。`plugin_min_host_version/0`（第 7 章）が効くのは、この照合を持つ本体より後に足した機能に依存するプラグインで、そのときは理由が `requires nostr-no-su 0.2.0 or later, but this is 0.1.0` の 1 行になり、原因が版であることが読める。

### 6.6 接頭辞は隔離ではない

接頭辞は、何がどのプラグインへ渡るのかをログと文書と `docker-compose.yml` の上で読めるようにするための規約である。**プラグインを他の環境変数から隔離する仕組みではない。** プラグインは本体と同じ VM で動くので `os:getenv/1` を自由に呼べる（第 1 章の信頼モデル）。ただし本体の秘密（`DATABASE_URL`、`ACCOUNT_MASTER_KEY`、`ADMIN_PASSWORD`）は起動時に読んだ後で環境から消すので、`os:getenv/1` では読めない。これも隔離ではない（第 1 章）。

## 7. バージョン方針

`plugin_api_version/0` の値は本体の対応バージョンと**完全一致**で判定する。一致しないモジュールは読み込まない。

機能の追加は**任意エクスポート**で行い、バージョンは上げない。本体は `erlang:function_exported/3` で個別に有無を問い合わせ、存在するときだけ呼ぶ。したがって、既存のプラグインを書き換えなくても本体の機能追加に追随できる。

**新しい引数が必要になったときも、既存の関数のアリティは変えない。** プラグイン固有の設定（第 6 章）がその実例である。`plugin_children/0` を `plugin_children/1` に変えるのではなく、`plugin_children/1` と `handle_event/2` を**任意エクスポート**として追加し、本体は存在すればそちらを優先して呼ぶ。`plugin_children/0` と `handle_event/1` しか持たないプラグインは従来どおり動き続ける。

このとき**必須側の判定を「`handle_event/1` または `handle_event/2`」に緩めたが、これは破壊的変更にあたらない。** `handle_event/1` を持つ既存のプラグインは 1 つも落ちず、必須エクスポートの削除でもアリティの変更でもないためである。**API バージョンは 1 のままである。** ただし逆方向、つまり `handle_event/2` だけを持つ新しいプラグインを古い本体で読むことはできない（第 6.5 節）。

任意エクスポートで足した機能のもう 1 つの実例が、依存する本体側アプリケーションの版の照合である。プラグインは `plugin_required_versions/0` で、アプリケーション名から版文字列への map（binary キー・binary 値）を返せる。本体は読み込み時に、宣言された各アプリケーションの版をコードパス上の `.app` の版と**完全一致**で照合し、1 件でも合わなければそのプラグインを読み込まない。比較の相手は「実行時に実際に使われる版」（第 8.4 節）であり、宣言しなければ照合しない。この機能もバージョンを上げずに任意エクスポートとして足したので、**API バージョンは 1 のまま**である。管理 UI のページ（第 13 章）も同じ形の追加で、`plugin_pages` と `plugin_page_content` を持たないプラグインは UI を持たないものとして今までどおり読み込まれる。**API バージョンは 1 のままである。** 入力と実行（`plugin_page_action`）も同じ形の追加で、**API バージョンは 1 のまま**である。プラグインが本体を呼ぶ口（第 14 章）は任意エクスポートですらなく本体側の関数の追加なので、第 2 章のエクスポート仕様は変わらず、**API バージョンは 1 のまま**である。複数の公開鍵の取得（`fetch_events/2`、第 14.10 節）も後から足した本体側の関数で、**API バージョンは 1 のまま**である。

任意エクスポートで足した機能は、古い本体では単に無視される。そこで**プラグインの側から本体の版の下限を宣言できる**ようにしてある。`plugin_min_host_version/0` が `X.Y.Z` の binary を返すと、本体は読み込み時に自分の版と `MAJOR.MINOR.PATCH` の数値比較で照合し、本体のほうが小さければそのプラグインを読み込まない（理由は第 9 章）。pre-release（`0.2.0-rc.1`）と build metadata（`0.2.0+build.1`）は扱わず、形の誤りとして読み込まない。0.x の間は minor が破壊的変更を表すので、新しい任意エクスポートや新しい本体側の関数（第 14 章）に依存するプラグインは、その機能が入った版を下限に書けばよい。この照合そのものを持たない本体はこのエクスポートを無視するので、下限の宣言が効くのは照合が入った版以降の本体である。この照合もバージョンを上げずに足したので、**API バージョンは 1 のまま**である。

```erlang
plugin_min_host_version() -> <<"0.2.0">>.
```

**照合の相手は本体の `nostr_no_su.app` の `vsn`（`gleam.toml` の `version`）である。** 開発中の本体は前のリリースの版を名乗り（最初のリリースまでは `0.0.0`。[貢献の手引き](../CONTRIBUTING.md) の「版数」）、版を上げるのはリリースの PR だけである。そのため、まだリリースされていない機能が入る版を下限に書いたプラグインは、その機能を含む main のビルドでも `requires nostr-no-su 0.2.0 or later, but this is 0.0.0` の形の理由で読み込まれない。リリース前の main で試すあいだは下限の宣言を外し、その機能を含む版がリリースされてから宣言する。

**依存の版の照合（`plugin_required_versions/0`）と用途を分けること。** 本体の版の下限にはこの節の `plugin_min_host_version/0` を使い、`plugin_required_versions/0` は影に入る依存（第 8.4 節）の版の照合に使う。後者は完全一致なので、本体の版をそこに書くと本体が上がるたびに宣言も上げ直すことになる。

バージョン番号を上げるのは、次の破壊的変更のときだけである。

- 必須エクスポートの削除
- 必須関数のアリティ変更
- イベント map のキーの**意味の変更**
- 第 14 章の本体側の関数の名前・アリティ・引数と戻り値の形の変更

イベント map への**キーの追加**は破壊的変更としない（第 3 章のとおり、知らないキーは無視すること）。第 14 章の本体側の関数についても同じ方針で、引数の map へのキーの追加（呼び出し側が渡すかどうかを選べる任意のキーに限る）と、新しい関数の追加は破壊的変更としない。

呼び出しに使うモジュール名 `nostr_no_su@plugin_api` は、Gleam のモジュール名 `nostr_no_su/plugin_api` を Erlang に写したもので、**安定した契約である**。この名前を変えることも破壊的変更にあたる。`@` を含まない別名モジュールは用意しない。

## 8. 配置と読み込み

本体は起動時に `PLUGIN_DIR` を 1 度だけ走査し、見つけたプラグインをコードパスへ足して読み込む。`PLUGIN_DIR` は `:` 区切りで複数のディレクトリーを並べられ、**左から順に**走査する（以下で `<PLUGIN_DIR>` と書くのはそのうちの 1 つである）。`PLUGIN_DIR` が未設定（空文字列や `:` だけの指定を含む）なら外部プラグインの読み込みは行わない。docker イメージは `ENV PLUGIN_DIR=/app/plugins` を持ち、同梱の `event_logger` と `profile` をそこに置いている。

### 8.1 受け付けるレイアウト

置き方は次の 3 つである。`<name>` はプラグインの名前で、**エントリーモジュール名と一致させる**（次節）。

```
<PLUGIN_DIR>/<name>.beam            -- 単一モジュール
<PLUGIN_DIR>/<name>/ebin/           -- ebin 1 つ
<PLUGIN_DIR>/<name>/<app>/ebin/     -- アプリごとに ebin が分かれる形
```

3 つめは `gleam export erlang-shipment` の出力そのままの形である。**shipment を flatten せずそのまま置ける。** アプリごとのディレクトリー構造を崩すと `.app` ファイルとの対応が壊れる。**同梱アプリケーションの起動はプラグインの責任である**（第 5.2 節）。本体が任意の同梱アプリケーションを自動で起動するのは信頼モデルの上でも別の判断が要るため、行わない。

探索は 2 段までで、再帰はしない。`.gitkeep` や `README.md`、shipment の `entrypoint.sh` のようにプラグインでないエントリーは黙って無視する。

### 8.2 エントリーモジュール規則

読み込みを試すのは **ディレクトリー名（ルート直下なら拡張子を除いたファイル名）と同じ名前のモジュールだけ**である。ebin に入っている BEAM を総当たりはしない。同梱した依存が勝手にプラグインとして読み込まれるのを防ぐためで、プラグイン作者から見れば「エントリーの名前は置き場所の名前と一致させる」という 1 つの規約になる。

- **Gleam**: プロジェクト名と同じトップレベルモジュール（`my_plugin/src/my_plugin.gleam`）をエントリーにし、ディレクトリー名も `my_plugin` にする。
- **Elixir**: `defmodule MyPlugin` は BEAM 上では `Elixir.MyPlugin` になる。**ディレクトリー名を `Elixir.MyPlugin` にすること。**
- **Erlang**: `-module(my_plugin)` なら `my_plugin`。

エントリーモジュール名が本体や先に読み込まれたプラグインと重なる場合、その候補はコードパスに何も足さずに丸ごと飛ばされる（次節）。

### 8.3 読み込み順

プラグインの**読み込み**は**`PLUGIN_DIR` に並べた順**にディレクトリーを処理し、ディレクトリーの中では**モジュール名の昇順**で行う。`file:list_dir/1` が返す順序には依存しない。内蔵プラグイン（`console_logger`。`PLUGIN_CONSOLE_LOGGER_ENABLED=false` なら置かない）は `PLUGIN_DIR` から読み込むのではなく本体に組み込まれており、プラグインの並びの先頭に置かれる。ただしイベント処理関数の**呼び出し順はプラグイン間では保証されない**（第 4 章）。

`plugin_name/0` の値が内蔵プラグインや既に読み込んだ外部プラグインと重なった場合、後から来た方は採用されない。名前はダッシュボードとログの識別子なので、内蔵・外部を区別せず一意にする。内蔵プラグインを無効にしても名前 `console_logger` は予約されたままで、外部プラグインは使えない。

### 8.4 コードパスと影（モジュール名前空間の衝突）

BEAM のモジュール名前空間はグローバルで、同じ名前のモジュールは VM 全体で 1 つしか存在できない。本体はプラグインの ebin を `code:add_pathz/1`（**末尾追加**）でコードパスへ足すため、次のようになる。

- **本体と本体の依存が常に優先される。** プラグインが新しい `gleam_stdlib` を同梱しても、使われるのは本体の版である。
- プラグイン同士では、先に読み込まれた側（先に並べたディレクトリー、同じディレクトリーなら名前順で先）が勝つ。

食い違いは、`plugin_required_versions/0` で依存の版を宣言すれば読み込み時に弾かれる（第 7 章）。宣言しなければ**読み込み時ではなくイベント処理関数の実行時に `undef` として現れる。** 本体の版に無い関数を呼んだ時点で初めて失敗するので、`plugin.load` の検証では検出できない。したがって **プラグインは Dockerfile と同じ Gleam / OTP でビルドすること。** OTP が違う BEAM は `badfile` で拒否される。

影に入ったモジュールは、バンドルにつき 1 行にまとめて起動ログへ出る。報告にはモジュールの提供元となるアプリケーションと版が `app vsn` の形で添えられる（アプリが分からないモジュールは名前を数件だけ挙げる）。同梱の `event_logger` の場合は 120 モジュールが影に入り、起動ログに出るのはその 1 行だけである（Dockerfile と同じイメージでビルドしたときの値）。

```
event_logger: 120 module(s) already provided by the host or another plugin are ignored (backoff 1.1.6, exception 2.1.1, gleam_erlang 1.3.0, gleam_json 3.1.0, gleam_otp 1.2.0, gleam_stdlib 1.0.3, gleam_time 1.10.0, opentelemetry_api 1.5.0, pg_types 0.6.0, pgo 0.20.0, pog 4.1.0)
```

### 8.5 読み込みの失敗

**読み込みの失敗で本体の起動は止まらない。** 理由を 1 行出して、そのプラグインだけを無効にする。走査したディレクトリーごとに必ず集計行が出る。下の表の行のうち `no PLUGIN_DIR set`、影の集計、集計行を除いたものは、管理 UI のダッシュボードの「読み込めなかったプラグイン」のカードにも、識別子と理由（`<識別子>: ` の接頭辞を外し、120 文字を超えるものは切って `...` を付けたもの）として出る。

| 行 | 意味 |
| --- | --- |
| `no PLUGIN_DIR set; external plugins disabled` | `PLUGIN_DIR` が未設定（空文字列や `:` だけで、有効なパスを 1 つも含まないときも同じ） |
| `<dir>: cannot read directory (enoent); skipped` | `PLUGIN_DIR` のディレクトリーが読めない（`enotdir` / `eacces` も同じ形）。他のディレクトリーの走査は続く |
| `<name>: cannot read directory (eacces); skipped` | プラグインのディレクトリーが読めない |
| `<name>: no ebin directory found (expected <name>/ebin or <name>/*/ebin)` | ディレクトリーはあるが ebin が見つからない |
| `<dir>: cannot add to code path (bad_directory); skipped` | `PLUGIN_DIR` のディレクトリー自身をコードパスへ足せなかった（ルート直下の `.beam` が対象） |
| `<name>: cannot add <ebin> to code path (bad_directory); skipped` | プラグインの ebin をコードパスへ足せなかった |
| `<name>: module <name> is already provided by the host or another plugin; skipped` | エントリーモジュール名が本体か他のプラグインと重なる |
| `<name>: N module(s) already provided by the host or another plugin are ignored (gleam_stdlib 1.0.3, ...)` | 同梱した依存が影に入った（読み込みは続行する） |
| `<mod>: duplicate plugin name "<name>"; keeping the first` | `plugin_name/0` の値が重複した |
| `loaded 2 plugin(s) from /plugins: file_logger, my_plugin (3 skipped)` | 集計。`skipped` は候補だったが読み込めなかったものの件数 |
| `loaded no plugins from /plugins (3 skipped)` | 集計。1 件も読み込めなかったとき。`skipped` が 0 なら括弧ごと省く |

モジュール自体の検証で失敗した場合の理由は第 9 章の表を参照すること。

### 8.6 同梱の例

同梱の例は 4 つある。ビルド方法と置き方は各ディレクトリーの README を参照すること。

- `examples/plugins/file_logger/` は受信したイベントを 1 件 1 行でファイルへ追記する。**状態を持たない例**で、処理は `handle_event/2` の中で完結する。同時に**プラグイン固有の設定を受け取る例**でもあり、出力先を `PLUGIN_FILE_LOGGER_PATH` から受け取る。設定が必須なので `handle_event/1` はエクスポートせず、`plugin_children/1` で設定の有無だけを検査する（第 6 章）。
- `examples/plugins/counter/` は受信件数を gen_server で数える。**状態を持つ例**で、その gen_server を `plugin_children/0` で申告する（第 5 章）。設定を必要としないのでアリティ 0 のままであり、**既存のプラグインが無変更で動くことの実例**にもなっている。

- `plugins-src/event_logger/` は監視で受信したイベントを Postgres へ保存する。例示ではなく**第一級の同梱プラグイン**で、Gleam プロジェクトを `gleam export erlang-shipment` の出力として置く実例である。状態（保存アクター）を持ち、**独自の依存を同梱する**（`pog` / `pgo` ほか。本体も `pog` に依存するので、共有パッケージ 120 モジュールが影に入る）実例でもあり、**同梱アプリケーションを自分で起動する**（第 5.2 節）唯一の例でもある。設定の表示に第 13 章の記述を使う。
- `plugins-src/profile/` は登録アカウントの現在のプロフィール（kind 0）を管理 UI に出し、`form` から編集して送り直せる。**DB を持たない第一級の同梱プラグイン**で、ページを開くたびに第 14.7 節の取得の口でリレーから最新の 1 件を取り、第 14.1 節の送信の口で更新を送る実例であり、第 13.3 節の `image` のブロックと `text` / `textarea` の欄を使う唯一の同梱の例でもある。持つ状態は直前の送信の結果だけで、1 回の描画まで保持する子プロセスを `plugin_children/0` で申告する。

上の 2 つが Erlang 1 ファイルなのは、ネストしたビルドディレクトリーと依存管理を `examples/` へ持ち込まないためである。`event_logger` と `profile` は Gleam で書くので、`plugins-src/` に独立した Gleam プロジェクトとして置いてある。

第 10 章に載せる `test/support/minimal_plugin.erl` とは役割が違う。あちらは仕様の最小実装例で、本体の ebin に混ぜてコンパイルされるため最初からコードパス上にある（コードパスを足さなくても読めるので、ローダーの検証には使えない）。`file_logger` と `counter` はどちらも「外から持ち込む」側の例である。

## 9. 読み込まれない条件と理由の文字列

読み込みに失敗すると、次の形の 1 行がログに出る。先頭は BEAM のモジュール名である。自分のプラグインが読み込まれないときは、この文字列を手がかりにする。

| 理由の文字列 | 意味 |
| --- | --- |
| `<mod>: cannot load module (nofile)` | モジュールがコードパスに無い。ファイル名とモジュール名の不一致、置き場所の誤り |
| `<mod>: cannot load module (badfile)` | BEAM として読めない。壊れたファイル、または本体と違う OTP でビルドしたもの |
| `<mod>: cannot load module (timed out after 5000ms)` | `-on_load` が 5 秒以内に戻らなかった。モジュールの読み込みもメタデータの呼び出しと同じ期限で打ち切る |
| `<mod>: missing export plugin_api_version/0` | 必須エクスポートが無い。`plugin_name/0` も同じ形で報告される |
| `<mod>: missing export handle_event/1 or handle_event/2` | イベント処理関数がどちらのアリティでも無い |
| `<mod>: plugin_api_version/0 crashed (error:badarg)` | メタデータの関数が例外を投げた。括弧内は `クラス:理由`。呼び出しのプロセスごと終了した場合は括弧内が終了理由（`killed` など） |
| `<mod>: plugin_name/0 crashed (error:badarg)` | 同上。`plugin_name/0` が例外を投げた場合 |
| `<mod>: plugin_name/0 timed out after 5000ms` | メタデータの関数が 5 秒以内に戻らなかった（第 2 章）。`plugin_api_version/0`、`plugin_min_host_version/0`、`plugin_required_versions/0`、`plugin_children/0` `/1`、`plugin_pages/0` `/1` も同じ形で報告される |
| `<mod>: plugin_api_version/0 must return an Int, got Float` | 戻り値が整数でない |
| `<mod>: unsupported api version 2 (expected 1)` | 本体が対応していないバージョン |
| `<mod>: plugin_min_host_version/0 must return a version string like "0.1.0", got Int` | 戻り値が文字列（binary）でない |
| `<mod>: plugin_min_host_version/0 must return a version string like "0.1.0", got "0.2.0-rc.1"` | 戻り値が `MAJOR.MINOR.PATCH` に読めない。pre-release と build metadata はここで弾かれる |
| `<mod>: requires nostr-no-su 0.2.0 or later, but this is 0.1.0` | 宣言した本体の版の下限より本体が古い |
| `<mod>: plugin_required_versions/0 must return a map of application names to version strings (expected String, got Int at gleam_stdlib)` | 戻り値の形が API に合わない。括弧内は `decode` の最初のエラー |
| `<mod>: requires gleam_stdlib 1.0.2, but the code path provides 1.0.3` | 宣言した版がコードパス上の版と食い違う |
| `<mod>: requires foo 1.0.0, but no foo.app is on the code path` | 宣言したアプリケーションがコードパスに無い |
| `<mod>: plugin_name/0 must return a String, got Int` | 名前が文字列（binary）でない |
| `<mod>: plugin_name/0 must not be empty` | 名前が空文字列 |
| `<mod>: plugin_children/0 crashed (error:badarg)` | 子仕様の問い合わせが例外を投げた |
| `<mod>: plugin_children/0 must return a list of child specification maps, got Dict` | 戻り値がリストでない（`dynamic.classify` は map を `Dict`、タプルを `Array` と呼ぶ） |
| `<mod>: plugin_children/0: child #0: must be a child specification map, got Array` | 子仕様が map でない。素の `{Module, Function, Args}` の短縮形はここで弾かれる（`dynamic.classify` はタプルを `Array` と呼ぶ） |
| `<mod>: plugin_children/0: child #0: missing id` | `id` が無い。番号は 0 起点のリストの位置 |
| `<mod>: plugin_children/0: child "store": missing start` | `start` が無い。`id` が読めた子はその値で名指しされる |
| `<mod>: plugin_children/0: child #0: id must be an atom or a string, got Int` | `id` が atom でも binary でもない |
| `<mod>: plugin_children/0: child "store": start must be a {Module, Function, Args} tuple, got List` | `start` が 3 要素のタプル（atom、atom、リスト）でない |
| `<mod>: plugin_children/0: child "store": unsupported shutdown (brutal_kill); use a number of milliseconds or infinity` | 表現できない `shutdown` |
| `<mod>: plugin_children/0: child "store": unsupported restart (always); use permanent, transient or temporary` | 表現できない `restart` |
| `<mod>: plugin_children/0: child "store": unsupported type (dynamic); use worker or supervisor` | 表現できない `type` |
| `<mod>: plugin_children/0: child "store": supervisor children must use shutdown => infinity` | `type => supervisor` の子に有限の `shutdown` を書いた |
| `<mod>: plugin_children/1 crashed (error:badarg)` | 設定を受け取る形の問い合わせが例外を投げた。理由の中のアリティは本体が呼んだ側のもの |
| `<mod>: plugin_children/1 rejected the configuration (path is required); configure it with PLUGIN_FILE_LOGGER_*` | プラグインが設定を受け付けなかった（第 6.4 節）。子を持たないプラグインでもこの行になる。`plugin_children/0` が返した場合は `plugin_children/0 rejected the configuration (…); configure it with PLUGIN_<NAME>_*` になる |
| `<mod>: plugin_children/1: error reason must be a String, got Atom` | `{error, Reason}` の `Reason` が binary でない |
| `<mod>: plugin_pages/0 but no plugin_page_content/1 or /2` | 一覧はあるが中身のエクスポートが無い（第 13 章） |
| `<mod>: plugin_page_content/1 but no plugin_pages/0 or /1` | 中身のエクスポートはあるが一覧が無い |
| `<mod>: plugin_page_action/3 but no plugin_pages/0 or /1` | 実行のエクスポートはあるが一覧が無い |
| `<mod>: plugin_pages/1 must return a list of page maps, got Dict` | 一覧の戻り値がリストでない |
| `<mod>: plugin_pages/1 must return at least one page` | 一覧が 0 件 |
| `<mod>: plugin_pages/1: page #0: must be a page map, got Array` | ページの記述が map でない。素の `{key, title}` のようなタプルはここで弾かれる（`dynamic.classify` はタプルを `Array` と呼ぶ） |
| `<mod>: plugin_pages/1: page #0: missing key` | ページの記述に `key` が無い。番号は 0 起点のリストの位置 |
| `<mod>: plugin_pages/1: duplicate page key "settings"` | ページのキーが重複している |
| `<mod>: plugin_pages/1: page key "A b" must match [a-z0-9_-]+` | ページのキーが許された文字集合の外 |
| `<mod>: plugin_pages/1: page key "status": missing title` | `key` を読んだ後の検査は `page #<index>` ではなく `page key "<key>"` で位置を示す |

子仕様の行の `got` の後は受け取った値の `dynamic.classify` の分類名、`unsupported …` の括弧の中は受け取った値そのもの（`~0p` で 1 行にしたもの）で、表の値は例示である。

検証はモジュールの読み込み → 必須エクスポート（`plugin_api_version/0`、`plugin_name/0`、`handle_event/1` か `/2`）→ `plugin_api_version` → `plugin_min_host_version` → `plugin_required_versions` → `plugin_name` → 設定の切り出し → `plugin_children` → `plugin_pages` の順で進み、最初に失敗したところで止まる。子仕様の誤りは 1 件だけ報告する。

## 10. Erlang での最小実装例

次のモジュールがそのまま動く最小のプラグインである（`test/support/minimal_plugin.erl` は先頭のコメントを除いてこのモジュールと同じ内容で、テストで読み込めることを検証している）。

```erlang
-module(minimal_plugin).
-export([plugin_api_version/0, plugin_name/0, handle_event/1]).

plugin_api_version() -> 1.
plugin_name() -> <<"minimal_plugin">>.

handle_event(Event) ->
    #{<<"kind">> := Kind, <<"content">> := Content} = Event,
    io:format("~p ~ts~n", [Kind, Content]),
    ok.
```

## 11. Gleam で書くときの注意

- Gleam の公開関数は、名前とアリティがそのまま BEAM のエクスポートになる。`pub fn handle_event(event: Dynamic) -> Nil` と書けば `handle_event/1` になる。
- **モジュールはプロジェクトのトップレベルに置くこと。** サブディレクトリに置くと BEAM のモジュール名が `dir@name` になる（例: `src/plugins/foo.gleam` → `plugins@foo`）。
- Gleam の `String` は binary、`Nil` は atom の `nil` である。イベント map と設定 map（第 6 章）はどちらも binary キーなので、`Dynamic` として受け取って `gleam/dynamic/decode` でデコードする（設定なら `decode.dict(decode.string, decode.string)`）。
- **Gleam ではアリティ違いの同名関数を定義できない。** `handle_event/1` と `handle_event/2` の両方を持たせることはできないので、設定が要るなら `/2` だけを書くことになる（第 6.5 節の注意がそのまま当てはまる）。
- 本体と同じ `Event` 型を使いたい場合は、`nostr_no_su/nostr/event` の `from_map/1` がイベント map を `Event` に戻す。ただしプラグインは本体とは別のプロジェクトとしてビルドするため、`nostr_no_su` をコンパイル時の依存に持てず `import` はできない。実行時に外部関数として呼ぶ。

  ```gleam
  @external(erlang, "nostr_no_su@nostr@event", "from_map")
  fn from_map(value: Dynamic) -> Result(Event, String)
  ```

  この `Event` は本体のレコードなので、プラグイン側にも同じフィールドを同じ順で持つ型を宣言しておく（Gleam のレコードは実行時にはタグ付きタプルなので、コンストラクター名（`Event`）とフィールドの並びが一致していれば読める。フィールド名は実行時には残らない）。本体の型に追随する手間を避けたい場合は、`gleam/dynamic/decode` で map を直接読むほうが簡単である。
- `plugin_required_versions/0` は `dict.from_list([#("gleam_stdlib", "1.0.3")])` のように `Dict(String, String)` を返せばよい。版は自分の `manifest.toml` に書かれた値を使う。
- `plugin_min_host_version/0` は `pub fn plugin_min_host_version() -> String { "0.2.0" }` のように binary を返す。
- 第 13 章の記述は binary キーの map なので、`gleam/dynamic` の `properties` / `list` / `string` で組む（`properties` は Erlang では map になる）。

## 12. Elixir で書くときの注意

- Elixir の `defmodule MyPlugin` は、BEAM 上では `Elixir.MyPlugin` という atom のモジュール名になる。**プラグインを置くディレクトリー名にはこの完全な名前を使うこと**（第 8 章のエントリーモジュール規則）。
- 関数は `def` で定義したものだけがエクスポートされる（`defp` は対象外）。
- 文字列リテラル `"minimal_plugin"` は binary なので、`plugin_name/0` の戻り値としてそのまま使える。
- イベント map のキーは binary である。`%{"kind" => kind}` でマッチすること。`%{kind: kind}` は atom キーになるためマッチしない。設定 map（第 6 章）も同じく binary キーである。

## 13. 管理 UI のページ（任意エクスポート `plugin_pages` / `plugin_page_content` / `plugin_page_action`）

任意エクスポート `plugin_pages` と `plugin_page_content` を**両方**持つプラグインは、管理 UI にページを供給できる。どちらか片方だけでは読み込まない（第 9 章）。両方とも無いプラグインは今までどおり UI を持たずに読み込まれる。**API バージョンは 1 のままである**（第 7 章）。さらに任意エクスポート `plugin_page_action` があれば、そのページはフォーム（第 13.3 節の `form` ブロック）の送信を受け取れる（第 13.6 節）。`plugin_pages` / `plugin_page_content` を持たずに `plugin_page_action` だけを持つプラグインは読み込まない。

### 13.1 エクスポート

| 関数 | アリティ | 戻り値 | 本体側の検証 |
| --- | --- | --- | --- |
| `plugin_pages` | 0 または 1 | ページの記述のリスト（第 13.2 節） | 読み込み時に 1 度だけ検証する |
| `plugin_page_content` | 1 または 2 | ページの記述 map（第 13.3 節） | 読み込み時には呼ばない。ページの表示のたびに呼ぶ |
| `plugin_page_action` | 2 または 3 | `ok` または `{error, Reason}`（第 13.6 節） | 読み込み時には呼ばない。フォームの送信のたびに呼ぶ |

`/1` があれば `plugin_pages/0` より優先し、設定 map（第 6 章）を渡す。`plugin_page_content` も同様に `/2` があれば `/1` より優先し、第 1 引数にページの `key`、第 2 引数に設定 map を渡す。`plugin_page_action` も同様に `/3` があれば `/2` より優先し、設定 map を最後の引数で渡す。

```erlang
plugin_pages() -> [page_map(), ...].
plugin_page_content(Key :: binary()) -> description_map().
```

`plugin_page_content` と `plugin_page_action` の 1 回の呼び出しの期限は `call_timeout_ms`（本番の既定は 5 秒）で、超えたページと超えた送信は 503 になる。例外も同じ 503 で、理由の文字列に `crashed (error:badarg)` の形で現れる。第 2 章の「即座に戻ること」の列挙にはこの 2 つのエクスポートを含めない。起動時ではなく画面の表示と送信のたびに呼ばれるためである。

### 13.2 ページの一覧

`plugin_pages` はページの記述の**リスト**を返す。**1 件以上必要**で、`key` は**重複できない**。

| キー | 型 | 本体側の検証 |
| --- | --- | --- |
| `key` | binary | `[a-z0-9_-]+` に一致すること。URL の path 片になる |
| `title` | binary | 必須。管理 UI の表示名（プラグイン由来の英語） |

ページの URL は `/plugins/<plugin_name/0 の値を percent-encode したもの>/<key>` である。入口はダッシュボードのプラグインの節の操作列に出るリンクで、一覧の先頭のページを指す。2 ページ以上のプラグインは、ページの上のタブで行き来する。

理由の文字列は第 9 章の表のとおり（`plugin_pages/1 must return at least one page` など）。

### 13.3 ページの記述

`plugin_page_content` はページ 1 件の記述を返す。記述は**段ごとに種別を閉じた 3 段の binary キーの map**である。段に合わない種別を置くと、その段を読む本体側の decoder が失敗するため、3 段を超える入れ子は構造的に `Error` になる。

最上位は `#{<<"sections">> => [節, ...]}`。

| 段 | 種別 | 必須のキー | 任意のキー |
| --- | --- | --- | --- |
| 節 | `section` | `title`、`blocks`（ブロックのリスト） | 無し |
| ブロック | `text` / `note` | `text` | 無し |
| ブロック | `pairs` | ``items``（``#{<<"term">> => binary, <<"value">> => `text`・`code`・`id` のインライン}``のリスト） | 無し |
| ブロック | `table` | `headers`（binary のリスト）、`rows`（インラインのリストのリスト） | 無し |
| ブロック | `alert` | `text` | `tone`（既定 `info`） |
| ブロック | `link` | `page`（同じプラグインのページのキー）、`text` | 無し |
| ブロック | `form` | `fields`（欄の記述のリスト、後掲）、`submit`（送信ボタンの文字列） | 無し |
| ブロック | `details` | `summary`、`text` | 無し |
| ブロック | `image` | `url`（`http` / `https` の画像の URL）、`alt`（代替文） | 無し |
| インライン | `text` / `code` | `text` | 無し |
| インライン | `badge` | `text` | `tone`（既定 `neutral`）（`table` のセルだけ） |
| インライン | `id` | `text` | 無し（`pairs` の値だけ） |

`details` はブロックの中にブロックを置けない。`summary` は折りたたみのボタンの文字列、`text` は開いたときに出す整形済みのテキスト（改行はそのまま、長い行は折り返す）である。`id` は 64 桁の 16 進のような識別子を先頭 10 桁と末尾 6 桁に省略し、コピーのボタンを添えて出す。`image` は URL の指す画像を枠の幅と高さ 192px に収めて出し、`url` の scheme が `http` / `https` でないときは画像を描かず、代替文だけを枠に出す（節の描画は止まらない）。

`form` の宛先は本体が決め（`POST /plugins/<プラグイン名を percent-encode したもの>/<key>` に固定）、プラグインは指定できない。`fields` は**1 件以上必要**。`text` は 1 行、`textarea` は 4 行の入力欄になる。大きさも書体もプラグインは選べない。

| 欄の種別 | 必須のキー | 任意のキー |
| --- | --- | --- |
| `checkbox` | `name`（`[A-Za-z0-9_-]+` に一致する送信名）、`label` | `hint`（説明）、`checked`（真偽値、既定 `false`） |
| `text` | `name`（`[A-Za-z0-9_-]+` に一致する送信名）、`label` | `hint`（説明）、`value`（初期値、既定は空文字列） |
| `textarea` | `name`（`[A-Za-z0-9_-]+` に一致する送信名）、`label` | `hint`（説明）、`value`（初期値、既定は空文字列） |

`tone` は `neutral`・`success`・`warning`・`failure`・`info` の 5 値のみで、それ以外はその節ひとつぶんの `Error` になる。`pairs` の `items` が 0 件のときと、節の `blocks` が 0 件のときは、空の状態の文（`Nothing to show.` の訳）を出す。`sections` そのものが 0 件のときは、ページ全体に表示する内容が無い旨の案内を出す。`table` の `rows` が 0 件のときは見出し行だけの表になる。

未知の種別、型の合わない値、深すぎる入れ子は、その節ひとつぶんの `Error` にする。他の節の描画は止まらない。

### 13.4 制約

- **プラグインが選べるのは文字列・種別・`tone`・真偽値だけである。** クラス名、`href`、生の HTML、色は渡せない。すべて管理 UI の共通部品（`src/nostr_no_su/admin/view.gleam`）にだけ写す。`image` も渡せるのは URL と代替文だけで、大きさ・枠・配置は選べない。
- **秘密はプラグインが返す前に自分でマスクする。本体は値をマスクしない**（第 1 章の信頼モデルと同じ理由）。
- 返す文字列はすべて `lang="en"` で出る。表示の言語（日本語・英語）には訳さない。
- `plugin_page_content` に `{error, Reason}` を返す約束は無い。描けない事情はページの記述の `alert` で自分で表すこと。返しても中身の形の誤りとして扱われ、例外・期限超過と同じ 503 になる。
- **`plugin_page_content` の中で自前の DB に問い合わせてもよい。** 1 回の呼び出しの期限（既定 5 秒、第 13.1 節）に収めるため問い合わせ側にも期限を付け、失敗は `alert` のブロックで自分で表すこと（同梱の `event_logger` は 2 秒である）。
- **`image` の URL は管理者のブラウザーが直接取りに行く。** 本体は中継せず、取得の可否も内容も検査しない。プラグインのページの GET の応答だけ CSP の `img-src` を `data: https: http:` に広げている（[管理 UI](admin-ui.md) の「状態を変えるリクエストと枠への埋め込み」）。管理 UI を https で配信している場合、`http` の画像は混在内容としてブラウザーが遮る。

### 13.5 Erlang の例

```erlang
plugin_pages() ->
    [#{<<"key">> => <<"status">>, <<"title">> => <<"Status">>}].

plugin_page_content(<<"status">>) ->
    #{<<"sections">> => [
        #{<<"type">> => <<"section">>,
          <<"title">> => <<"Queue">>,
          <<"blocks">> => [
              #{<<"type">> => <<"pairs">>,
                <<"items">> => [
                    #{<<"term">> => <<"pending">>,
                      <<"value">> => #{<<"type">> => <<"text">>,
                                       <<"text">> => <<"3">>}}
                ]}
          ]}
    ]}.
```

Gleam の実装例は `plugins-src/event_logger/src/event_logger/page.gleam` にあり、秘密のマスク（第 13.4 節）の実例でもある。

`plugin_page_content` と `plugin_page_action` に渡す設定 map には、これまでの環境変数由来のキーに加えて予約キー `Accounts` が入る。値はバンカーに登録したアカウントの一覧を JSON にした binary で、要素は `pubkey`（16 進）・`npub`・`label`（すべて文字列）のオブジェクトであり、登録が 0 件なら `[]` である。このキーは `plugin_pages` と `plugin_children` の呼び出しには渡らない。読み方は次のとおり（`json` は OTP 27 以降の標準モジュールで、`gleam_json` も同じものを使う）。

```erlang
Accounts = json:decode(maps:get(<<"Accounts">>, Config)).
```

### 13.6 入力と実行（任意エクスポート `plugin_page_action`）

`form` ブロック（第 13.3 節）を持つページは、任意エクスポート `plugin_page_action` でフォームの送信を受け取れる。宛先は本体が決め、`POST /plugins/<プラグイン名を percent-encode したもの>/<key>` に固定する。プラグインはこの宛先を指定できない。

受け取る `Values` は、欄の `name` → 送信された値の binary キー・binary 値の map である。`checkbox` はチェックされた欄だけが `<<"on">>` で届き、チェックしなかった欄は届かない。`text` と `textarea` は常に届き、空のまま送られた欄は `<<>>` になる（本体は空の値を落とさない）。

戻り値は `ok` か `{error, Reason}`（`Reason` は binary）のいずれかである。

- `ok` を返すと、本体はそのページへ 303 でリダイレクトする。
- `{error, Reason}` を返すと、本体は `Reason` を理由に 503 の通知ページを出す。
- `ok` でも `{error, Reason}` でもない値を返すと、戻り値の形の誤りとして同じく 503 になる。
- 呼び出しの例外・期限超過も 503 になる（第 13.1 節）。

`plugin_page_action` を持たないページへの `POST` は、`plugin_page_content` を持つページと同じく `405 Method Not Allowed`（`allow: GET`）になる。持つページは `allow: GET, POST` になる。

```erlang
plugin_page_action(<<"settings">>, #{<<"main">> := <<"on">>}, _Config) ->
    ok;
plugin_page_action(<<"settings">>, _Values, _Config) ->
    {error, <<"select at least one account">>}.
```

送信の失敗の理由は次の形で 503 のページに出る。

- `<mod>: plugin_page_action/3 rejected the request (select at least one account)`
- `<mod>: plugin_page_action/3 must return ok or {error, Reason}, got Atom`
- `<mod>: plugin_page_action/3: error reason must be a String, got Atom`

### 13.7 古い本体との互換性

`plugin_pages` / `plugin_page_content` / `plugin_page_action` は、これらを知らない古い本体では**黙って無視される**。ページを持つプラグインは読み込まれ、管理 UI にページが出ないだけになるので、症状から原因が読めない。ページが前提のプラグインは `plugin_min_host_version/0`（第 7 章）でこの機能が入った本体の版を下限に宣言し、古い本体では理由つきで読み込まれないようにすること。

## 14. プラグインから本体を呼ぶ（イベントの送信と取得）

この口はサンドボックスではない。第 1 章のとおりプラグインは本体と同じ VM で動くので、この口は秘密鍵に触れずに送信と取得を行うための**簡便な手段**であって、権限の境界ではない。送信は第 14.1〜14.4 節と第 14.6 節、1 件の取得は第 14.7〜14.9 節、複数の公開鍵の取得は第 14.10 節で、第 14.5 節の古い本体との互換性はすべてに当てはまる。

### 14.1 呼び出しの形

プラグインは `nostr_no_su@plugin_api:publish_event(Pubkey, Draft)` を外部関数として呼ぶ。

| 引数・戻り値 | 型 | 意味 |
| --- | --- | --- |
| `Pubkey` | binary | 64 桁 16 進の公開鍵。登録アカウントのものであること |
| `Draft` | binary キーの map | `kind`（整数）・`tags`（binary のリストのリスト）・`content`（binary） |
| 戻り値（成功） | `{ok, EventMap}` | `EventMap` は `nostr_no_su@nostr@event:to_map/1` と同じ形 |
| 戻り値（失敗） | `{error, Reason}` | `Reason` は binary |

```erlang
Draft = #{<<"kind">> => 1, <<"tags">> => [], <<"content">> => <<"hello">>},
case nostr_no_su@plugin_api:publish_event(Pubkey, Draft) of
    {ok, #{<<"id">> := Id}} -> Id;
    {error, Reason} -> {error, Reason}
end.
```

`created_at` と `id` と `sig` は本体が入れる。プラグインが指定する余地は無い。

### 14.2 送信先とリレーの応答

送信先は**監視の用途**のリレーである。バンカーの用途のリレーは kind 24133 以外の購読を拒みうるため（第 1 章の信頼モデルとは別に、`docs/architecture.md` の用途の分離を参照）、送信先には使わない。

リレーの OK（NIP-01 の `["OK", ...]`）は待たない。`{ok, _}` は「生きた監視リレーの接続に少なくとも 1 本渡した」ことだけを意味し、リレーが保存したことは意味しない。

### 14.3 理由の文字列

| 理由の文字列 | 意味 |
| --- | --- |
| `the plugin API is not installed` | 本体がこの口を有効にしていない |
| `pubkey must be a String` | `Pubkey` が binary でない |
| `no monitor relay is registered` | 監視の用途のリレーが一覧に無い |
| `no monitor relay is connected` | 監視の用途のリレーはあるが、生きたソケットに 1 本も渡せなかった |
| `the relay list is not responding` | リレーの一覧を持つアクターが応答しない |
| `accounts are not loaded yet` | バンカーがまだアカウントを読み込んでいない |
| `account is not registered` | `Pubkey` が登録アカウントに無い |
| `failed to sign the event` | 署名に失敗した |
| `bunker is not responding` | バンカーが応答しない |

`Draft` の記述が誤っているときの理由は、`nostr_no_su@nostr@event:from_map/1`（第 11 章）と同じ整形（`describe_decode_errors`）で、欠けているフィールドや型の不一致を 1 行にまとめたものになる。

### 14.4 期限

通常は数ミリ秒から 1 秒で戻る。バンカーが応答しないときは 5 秒、リレーの一覧が応答しないときは 15 秒（`relay_list.call_timeout_ms`）で理由を返す。**`plugin_page_content` の中では呼ばないこと。** ページを表示するたびに送信することになる。`plugin_page_action` から呼ぶのは想定内で、バンカーかリレーの一覧が応答しないときに限って第 13.1 節の 5 秒を超えて 503 になる（そのときは管理 UI の他のページも同時に失敗している）。

リレーごとの応答は本体が起こす使い捨てのプロセスで集めるので、期限の後に届いた応答が呼び出し元のプロセスに残ることはない。集計の結果 1 件だけは、呼び出し元（イベント処理やページの送信のたびに使い捨てられるプロセス）が受け取る。

### 14.5 古い本体との互換性

この章の 3 つの口はどれも本体側の関数なので、`plugin_api_version/0` では有無を判定できない。持たない本体に置いたプラグインは読み込みまでは成功し、呼んだ時点で `undef` になって第 4 章の 1 件の失敗として数えられる（連続 5 回で無効化）。読み込み時に弾きたいプラグインは `plugin_min_host_version/0` でこの口が入った本体の版を下限に宣言すること（第 7 章）。照合は下限との比較なので、本体の版が上がっても宣言を上げ直す必要は無い。

### 14.6 送ったイベントの配信

送ったイベントは監視の購読で戻ってくる。登録アカウントが作ったイベントなので、自分を含む全プラグインの `handle_event` に渡る（第 4 章）。`handle_event` の中から呼ぶプラグインは、自分の送信でもう一度呼ばれることを前提に、送る条件を `kind` や `tags` で絞ること。

### 14.7 取得の呼び出しの形

プラグインは `nostr_no_su@plugin_api:fetch_event(Pubkey, Kind)` を外部関数として呼ぶ。

| 引数・戻り値 | 型 | 意味 |
| --- | --- | --- |
| `Pubkey` | binary | 64 桁 16 進の公開鍵。登録アカウントのものであること |
| `Kind` | 整数 | 取得するイベントの kind |
| 戻り値（成功） | `{ok, EventMap}` | `EventMap` は `nostr_no_su@nostr@event:to_map/1` と同じ形で、`created_at` が最新の 1 件 |
| 戻り値（該当なし） | `{ok, none}` | どのリレーにも無かった |
| 戻り値（失敗） | `{error, Reason}` | `Reason` は binary |

```erlang
case nostr_no_su@plugin_api:fetch_event(Pubkey, 0) of
    {ok, none} -> none;
    {ok, #{<<"content">> := Content}} -> Content;
    {error, Reason} -> {error, Reason}
end.
```

リレーが返したイベントは、問い合わせた `Pubkey` と `Kind` の両方に一致するものだけを候補にし、一致しないものは捨てる。複数のリレーが違うイベントを返したときは `created_at` が最大の 1 件を選ぶ。同じ `created_at` が複数あるときは、リレーの一覧で先のもの（同じリレーの中では先に届いたもの）を選ぶ。

### 14.8 問い合わせ先と期限

問い合わせ先は**監視の用途**のリレーである。**リレー 1 本につき新しい接続を 1 本開いて閉じる**。常駐の監視接続の購読には載せないので、`fetch_event` を呼ぶたびにリレーの本数だけハンドシェイクが増える。1 回の描画でアカウントごとに `fetch_event` を呼ぶと、開く接続はアカウントの件数 × リレーの本数になる。複数のアカウントを取るときは、リレー 1 本につき接続 1 本と REQ 1 件にまとめる `fetch_events`（第 14.10 節）を使うこと。

NIP-42 の AUTH には応答しないので、読み取りに AUTH を要求するリレーは `auth-required` の CLOSED を返す。EOSE が届かないまま期限に達するので、応答しなかった本として数えられる（そのリレーしか無ければ `{error, <<"no monitor relay is connected">>}` になり、`{ok, none}` にはならない）。

期限は 3.2 秒で、それを超えたら `{error, Reason}` を返す。**第 14.4 節と違って、`plugin_page_content` の中から呼ぶのが想定の用途である**（ページを開いたときに現在の値を取るため）。バンカーが応答しないときは 5 秒、リレーの一覧が応答しないときは 15 秒まで延び、第 13.1 節の 5 秒を超えて 503 になりうる。

### 14.9 取得の理由の文字列

| 理由の文字列 | 意味 |
| --- | --- |
| `the plugin API is not installed` | 本体がこの口を有効にしていない |
| `pubkey must be a String` | `Pubkey` が binary でない |
| `pubkeys must be a List of Strings` | `fetch_events` の `Pubkeys` が binary のリストでない（第 14.10 節） |
| `kind must be an Int` | `Kind` が整数でない |
| `accounts are not loaded yet` | バンカーがまだアカウントを読み込んでいない |
| `account is not registered` | `Pubkey` が登録アカウントに無い |
| `bunker is not responding` | バンカーが応答しない |
| `the relay list is not responding` | リレーの一覧を持つアクターが応答しない |
| `no monitor relay is registered` | 監視の用途のリレーが一覧に無い |
| `no monitor relay is connected` | 監視の用途のリレーはあるが、どの 1 本とも接続できなかったか、期限までに応答しなかった |

### 14.10 複数の公開鍵の取得

プラグインは `nostr_no_su@plugin_api:fetch_events(Pubkeys, Kind)` を外部関数として呼ぶ。

| 引数・戻り値 | 型 | 意味 |
| --- | --- | --- |
| `Pubkeys` | binary のリスト | 64 桁 16 進の公開鍵。登録アカウントのものであること |
| `Kind` | 整数 | 取得するイベントの kind |
| 戻り値（成功） | `{ok, Results}` | `Results` は `Pubkeys` と同じ順・同じ件数のリストで、各要素は `fetch_event` の戻り値と同じ形（`{ok, EventMap}`、`{ok, none}`、`{error, Reason}`） |
| 戻り値（失敗） | `{error, Reason}` | `Reason` は binary |

```erlang
case nostr_no_su@plugin_api:fetch_events([PubkeyA, PubkeyB], 0) of
    {ok, Results} ->
        [case Result of
             {ok, none} -> none;
             {ok, #{<<"content">> := Content}} -> Content;
             {error, Reason} -> {error, Reason}
         end || Result <- Results];
    {error, Reason} -> {error, Reason}
end.
```

問い合わせ先と期限は第 14.8 節と同じで、**リレー 1 本につき新しい接続を 1 本開き、REQ を 1 件だけ送る**。REQ の `authors` は `Pubkeys` のうち登録アカウントのもの（重複を除く）、`kinds` は `[Kind]`、`limit` は `authors` の件数である。公開鍵ごとの 1 件の選び方は第 14.7 節と同じで、作者と kind の両方が一致するイベントだけを候補にする。

`limit` が件数どまりなので、全員の最新が返ると言えるのは、リレーが作者ごとに最新の 1 件だけを持つ replaceable の kind（0、3、10000〜19999）である。それ以外の kind では、リレーが `limit` を 1 人の作者のイベントで使い切り、他の作者が `{ok, none}` になりうる。

要素の `{error, Reason}` は、その公開鍵が登録アカウントに無いときの `account is not registered` だけである。`Pubkeys` に登録アカウントが 1 件も無い（空のリストを含む）ときは、リレーに問い合わせずに要素ごとの結果を返す。それ以外の失敗は外側の `{error, Reason}` で、理由は第 14.9 節の表のうち `pubkey must be a String` と `account is not registered` を除いたものである。
