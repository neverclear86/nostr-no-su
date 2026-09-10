# プラグイン API v1

Nostr-no-Su は、監視対象アカウントのイベントを受け取るプラグインを BEAM のモジュールとして読み込む。この文書はプラグインを書くために必要な仕様をまとめたもので、対象は API バージョン 1 である。

本体側の実装は `src/nostr_no_su/plugin.gleam`（検証と読み込み）、`src/nostr_no_su/plugin_loader.gleam`（走査とコードパスへの追加）、`src/nostr_no_su/plugin_config.gleam`（プラグイン固有の設定の切り出し）、`src/nostr_no_su/nostr/event.gleam`（イベント map の変換）にある。

## 1. 目的と信頼モデル

プラグインは、監視で受信したイベント 1 件ごとに呼ばれる処理を差し込む仕組みである。イベントを DB へ保存する、外部サービスへ通知する、といった用途を想定している。

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
- 上記以外のエクスポートは自由に増やしてよい。本体は必須の 3 つだけを見て読み込みを判定するので、未知のエクスポートがあっても読み込みには影響しない。本体が将来使う任意エクスポートは、存在するときだけ呼ばれる。

## 3. イベント map の仕様

`handle_event/1` が受け取るのは、NIP-01 のイベントを表す **Erlang の map** である。キーは次の 7 つで、**すべて binary**（`<<"id">>` など）。

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

- `handle_event/1` は**プラグインごとの専用プロセス**（ランナー）から、**イベント 1 件ごとに作られる使い捨てのプロセス**の上で呼ばれる。重複排除ディスパッチャーはイベントを各ランナーへ送るだけで戻る。
- したがって**プラグイン同士の実行順序は保証されない。** 同じプラグインの中では、イベントは届いた順に 1 件ずつ処理される。
- `self()` もプロセス辞書も**呼び出しをまたいで残らない。** 呼び出しごとに別のプロセスだからである。状態を持ちたいプラグインは自分でプロセスを起こし、その宛先を `handle_event/1` から参照すること。起こしたプロセスは本体のスーパービジョンツリーに載せられる（第 5 章）。
- **戻り値は無視される。** Erlang / Elixir なら `ok`、Gleam なら `Nil` を返すのが自然で、どちらでもよい。**正常終了とは `handle_event/1` から戻ることである。** プラグインが自分で `exit(normal)` を呼んだ場合は失敗として数える。
- **例外・異常終了は隔離される。** 落ちるのは使い捨てのプロセスだけで、ディスパッチャーも監視のリレー接続も他のプラグインも影響を受けない。プラグインの障害でスーパーバイザーの再起動が起きることはない。
- **クラッシュの詳細は本体がログに出す。** 本体はワーカーの中で例外を捕まえ、終了理由を `error:badarg` の形の 1 行に整える。そのため **BEAM の標準 error report は出ない。** 代わりに、理由とスタックトレース（いずれも長さを切ったもの）を本体が 1 行のログとして出力する。これは `handle_event/1` の失敗に限った話で、プラグインが申告した子プロセス（第 5 章）のクラッシュは BEAM の標準レポートとして出る。
- **`handle_event/2` があればそちらが呼ばれ**、第 2 引数にプラグイン固有の設定 map が渡る（第 6 章）。**どちらのアリティを呼ぶかの判定は読み込み時に 1 度だけ行う**ので、イベントごとのコストは増えない。
- **1 件あたりの実行時間には上限（30 秒）がある。** 超えるとワーカーを打ち切り、その 1 件を失敗として数える。
- **連続 5 回失敗したプラグインは無効化される。** 以後イベントは渡らず、捨てた件数を数えるだけになる。管理 UI の Plugins 欄には `disabled: <理由>` として残る。**再有効化の手段は 2 つ**で、本体の再起動と、そのランナープロセスの強制終了（スーパーバイザーが作り直し、状態は `running` から始まる）である。ホットリロードは対象外。ただし、子プロセスを諦めた後（第 5 章）はランナーを強制終了しても子は戻らない。この場合の復帰は本体の再起動だけである。
- **未処理のイベントが 1000 件を超えると、キューが空になるまでイベントを捨てる。** 追いついた時点で捨てた件数をログへ報告し、配信を再開する。**捨てるのは超過分だけではなく、そのとき積まれていたバックログ全体である。** 継続的に処理能力を超えるレートで届く場合はキューが何度も空になるので、捨てるのは追いつけないぶんだけで済む。一方、**一度に大量のイベントが届くバースト**（初回購読でリレーが保存済みイベントをまとめて返す場合など。監視のフィルターは `since` も `limit` も指定しない）では、上限を一瞬超えただけでバックログの大半が失われる。**したがって配信は best-effort であり、遅いプラグインは取りこぼす。** 取りこぼしたくない処理は、`handle_event/1` を短く保って自前のプロセスへ渡すこと。
- 同じイベント（同じ `id`）が複数のリレーから届いても、**通常は** `handle_event/1` は 1 回しか呼ばれない。ただし重複排除は有界なウィンドウ（直近の id を一定件数だけ記憶する）で行うため、容量を超えて古い id が押し出された後に同じイベントが再配信されると 2 回目が呼ばれる。ディスパッチャーが再起動したときもウィンドウは空になり、あわせて監視のリレー接続も張り直されるため、リレーが保存済みイベントを再送すれば同じイベントがもう一度届く。
- したがって **`handle_event/1` は冪等に書くこと。** 同じイベントを 2 回処理しても結果が変わらないようにする（保存するなら `id` を一意キーにする、通知するなら送信済みの `id` を記録する、など）。この仕組みが保証するのは at-least-once であって exactly-once ではない。

> Gleam で書いたプラグインの `panic` は、理由そのものに `file` / `line` / `message` が入るため冗長になり、切り詰められて読みにくくなる。外部プラグインは `erlang:error/1` を使うか、失敗を素直に返す形を選ぶとログが読みやすい（下の表の `error:badarg` は Erlang プラグインの形）。

### 4.1 実行時のログ行

接頭辞は `plugin <plugin_name/0 の値>` で、第 8.5 節の表（接頭辞 `plugin_loader` の読み込み失敗）とは別物である。

| 行 | 意味 |
| --- | --- |
| `handle_event failed (error:badarg); 2/5 at [{my_plugin,handle_event,1},...]` | 実行が失敗した。連続失敗数とスタックトレース（切り詰め）を添える |
| `disabled after 5 consecutive failures (error:badarg); events will be dropped` | 連続失敗の上限に達して無効化した |
| `handle_event failed (timed out after 30000ms); 1/5` | 1 件の実行が上限時間を超えて打ち切られた |
| `too slow: 1001 events queued (limit 1000); dropping until it catches up` | 未処理のイベントが上限を超えたので捨て始めた |
| `caught up; dropped 372 events while overloaded` | 追いついたので配信を再開した |

## 5. 状態を持つプラグイン（任意エクスポート `plugin_children`）

`handle_event/1` はイベントごとに別のプロセスで動くため、呼び出しをまたいで状態を持つには自分でプロセスを起こす必要がある（第 4 章）。任意エクスポート `plugin_children/0` を持つプラグインは、そのプロセスの子仕様を本体に申告できる。本体は起動時に 1 度だけこの関数を呼び、返ってきた子仕様をスーパービジョンツリーに載せる。

```erlang
plugin_children() -> [child_spec()].
```

**この関数は任意エクスポートであり、API バージョンは上げない**（第 7 章）。持たないプラグインは従来どおり動く。空のリストを返してもよい。

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
- **戻ること。** OTP のスーパーバイザーは子の起動にタイムアウトを持たない。`start` が戻らないとツリーの起動そのものが止まる。

### 5.3 登録名はプラグインの責任

本体は子プロセスの名前を作らず、渡しもしない。名前の登録は `start_link` の中で行うこと（`gen_server:start_link({local, Name}, ...)`）。MFA を丸ごとプラグインが書く以上、名前もそこで決まるのが自然である。

- **登録名は VM 全体で一意である。** プラグイン名を接頭辞にすること（`counter` プラグインなら `counter_store`）。衝突すると 2 つめの `register/2` が `badarg` で落ち、その子の起動が失敗する。
- **名前は再起動をまたいで同じでなければならない。** `handle_event/1` は毎回別のプロセスで動くので宛先を握り続けられず、名前で引くしかない。

### 5.4 失敗のモデル

子は普通の OTP プロセスなので、プラグインごとに用意された専用のスーパーバイザー（`one_for_one`、10 秒に 5 回まで）の下で再起動する。この歯止めを超えると、**そのプラグインの子はまとめて諦められ、本体を再起動するまで戻らない**。以後 `handle_event/1` は宛先を失って失敗し、連続 5 回で `disabled` になる（第 4 章）。**本体の他の部分（監視、バンカー、他のプラグイン）は影響を受けない。** ランナー自身は生き続けるので、管理 UI にはそのプラグインが `disabled: <理由>` として残る。

起動時に子の起動が失敗した場合は、そのプラグインを子なしで動かして起動を続ける。**アプリは起動する。**

子の起動に失敗したときに読む行は 2 つある。

```
[plugin counter] child "counter_store" failed to start (error:badarg)
[plugin counter] children failed to start; the reason is in the child line above, or in the =SUPERVISOR REPORT=; running without them
```

**理由が入っているのは 1 行目である。** 2 行目は理由を持っていない（スーパーバイザーの起動失敗は本体に理由を返さない）。上の例は登録名の衝突で、`start_link` の中の `register/2` が `badarg` で落ちた場合である。

**子のクラッシュは BEAM の標準レポートとして出る**（`=CRASH REPORT=` / `=SUPERVISOR REPORT=`）。本体が 1 行に整える `handle_event/1` の失敗（第 4.1 節）とは扱いが違う。

**外部資源に依存する子は、落ちずに数えて捨てる形を勧める。** 諦められた子は本体の再起動まで戻らないため、DB や HTTP に到達できないあいだ落ち続ける子は、歯止めを使い切って恒久的に失われる。内蔵のイベントロガーが DB 到達不能時に行っているのと同じく、到達できない件数を数えてプロセスは生かしておくほうがよい。

子の起動に必要な設定（接続文字列など）は、`plugin_children/1` の引数として受け取る（第 6 章）。設定が足りないときは子仕様を組み立てず、`{error, Reason}` を返してそのプラグインを読み込ませないこと。

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
- プラグインが受け取るのは `<KEY>` を**小文字にした binary キー**の map で、**値は環境変数の文字列そのまま**（binary）である。

```sh
PLUGIN_FILE_LOGGER_PATH=/tmp/nostr-no-su-events.log
```

```erlang
#{<<"path">> => <<"/tmp/nostr-no-su-events.log">>}
```

- **値が空文字列の変数は未設定として落とす。** docker compose は未設定の変数を空文字列として渡すため、この規則が無いと必須チェックが空文字列を通してしまう。
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

設定を受け取る口は「**任意エクスポートのアリティ +1**」という 1 つの規則で足してある。

| エクスポート | 本体の挙動 |
| --- | --- |
| `plugin_children/1` | あればこちらを呼び、設定 map を渡す。無ければ `plugin_children/0` を呼ぶ。どちらも無ければ問い合わせない |
| `handle_event/2` | あればこちらを呼び、第 2 引数に設定 map を渡す。無ければ `handle_event/1` を呼ぶ |

```erlang
plugin_children(Config) -> [child_spec()] | {error, Reason}.
handle_event(Event, Config) -> term().
```

`plugin_children/0` と `handle_event/1` しか持たないプラグインは**従来どおり動く**。設定を必要としないプラグインは何も変えなくてよい。

**設定 map は `plugin_name/0` の後にしか決まらない。** 接頭辞がプラグイン名から決まるため、本体の検証は `plugin_api_version` → `plugin_name` → 設定の切り出し → `plugin_children` の順に進む。

### 6.4 設定が足りないことの申告

`plugin_children/1` は、子仕様のリストの代わりに `{error, Reason}` を返せる。これは「**設定が足りない・不正なのでこのプラグインを読み込まないでほしい**」という申告である。`Reason` は binary で、環境変数名ではなく**キー名**を書けばよい（接頭辞は本体が添える）。

```erlang
plugin_children(#{<<"path">> := _Path}) -> [];
plugin_children(_Config) -> {error, <<"path is required">>}.
```

- **判別子は「1 番目の要素が atom の `error` であること」だけ**で、要素数は見ない。`{ok, 1}` のような他のタプルは子仕様のリストとして検証され、その形で弾かれる。
- **子プロセスを持たないプラグインも、設定の検査だけのためにこの関数を使える。** 設定が揃っていれば `[]` を返せばよい。上の例がその形である。
- 本体は次の 1 行をログに出し、**そのプラグインだけを無効にする。起動は止まらない**（走査の集計行では `skipped` に数えられる）。

  ```
  [plugin_loader] file_logger: plugin_children/1 rejected the configuration (path is required); 設定は PLUGIN_FILE_LOGGER_* で渡す
  ```

- **この行は子を持たないプラグインでも出る。** 関数名は「子仕様」と言っているが、設定は子仕様を組み立てるために要るものなので、設定の検査結果もこの関数から報告される。

宣言的な必須キーの一覧を本体に持たせていないのは、**値の妥当性まで検査できないため**である。`DATABASE_URL` が存在することと、それが Postgres の URL として解釈できることは別で、後者を読み込み時に検査できないと、不正な値が「子の起動失敗 → イベント処理の連続失敗 → `disabled`」という遠回りな症状に化ける。

### 6.5 古い本体との互換性

- `plugin_children/1` のような**普通の任意エクスポートは、知らない本体からは無視されるだけ**である。プラグインは設定を受け取らないまま動く。
- **`handle_event/2` だけをエクスポートするプラグインは違う。** この機能を持たない古い本体では `missing export handle_event/1` で丸ごと読み込まれない。`plugin_api_version() -> 1` と名乗っていても、v1 のすべての本体で動くとは限らない。

> `handle_event/2` だけをエクスポートするプラグインは、この機能を持つ本体でしか読み込めない。どの v1 本体でも動かしたいプラグインは `handle_event/1` もエクスポートすること。

### 6.6 接頭辞は隔離ではない

接頭辞は、何がどのプラグインへ渡るのかをログと文書と `docker-compose.yml` の上で読めるようにするための規約である。**プラグインを他の環境変数から隔離する仕組みではない。** プラグインは本体と同じ VM で動くので `os:getenv/1` を自由に呼べる（第 1 章の信頼モデル）。

## 7. バージョン方針

`plugin_api_version/0` の値は本体の対応バージョンと**完全一致**で判定する。一致しないモジュールは読み込まない。

機能の追加は**任意エクスポート**で行い、バージョンは上げない。本体は `erlang:function_exported/3` で個別に有無を問い合わせ、存在するときだけ呼ぶ。したがって、既存のプラグインを書き換えなくても本体の機能追加に追随できる。

**新しい引数が必要になったときも、既存の関数のアリティは変えない。** プラグイン固有の設定（第 6 章）がその実例である。`plugin_children/0` を `plugin_children/1` に変えるのではなく、`plugin_children/1` と `handle_event/2` を**任意エクスポート**として追加し、本体は存在すればそちらを優先して呼ぶ。`plugin_children/0` と `handle_event/1` しか持たないプラグインは従来どおり動き続ける。

このとき**必須側の判定を「`handle_event/1` または `handle_event/2`」に緩めたが、これは破壊的変更にあたらない。** `handle_event/1` を持つ既存のプラグインは 1 つも落ちず、必須エクスポートの削除でもアリティの変更でもないためである。**API バージョンは 1 のままである。** ただし逆方向、つまり `handle_event/2` だけを持つ新しいプラグインを古い本体で読むことはできない（第 6.5 節）。

バージョン番号を上げるのは、次の破壊的変更のときだけである。

- 必須エクスポートの削除
- 必須関数のアリティ変更
- イベント map のキーの**意味の変更**

イベント map への**キーの追加**は破壊的変更としない（第 3 章のとおり、知らないキーは無視すること）。

## 8. 配置と読み込み

本体は起動時に `PLUGIN_DIR` を 1 度だけ走査し、見つけたプラグインをコードパスへ足して読み込む。`PLUGIN_DIR` が未設定（空文字列を含む）なら外部プラグインの読み込みは行わない。

### 8.1 受け付けるレイアウト

置き方は次の 3 つである。`<name>` はプラグインの名前で、**エントリーモジュール名と一致させる**（次節）。

```
<PLUGIN_DIR>/<name>.beam            -- 単一モジュール
<PLUGIN_DIR>/<name>/ebin/           -- ebin 1 つ
<PLUGIN_DIR>/<name>/<app>/ebin/     -- アプリごとに ebin が分かれる形
```

3 つめは `gleam export erlang-shipment` の出力そのままの形である。**shipment を flatten せずそのまま置ける。** アプリごとのディレクトリー構造を崩すと `.app` ファイルとの対応が壊れるためで、同梱アプリケーションの起動（`application:ensure_all_started/1`）は今後の変更で入る。

探索は 2 段までで、再帰はしない。`.gitkeep` や `README.md`、shipment の `entrypoint.sh` のようにプラグインでないエントリーは黙って無視する。

### 8.2 エントリーモジュール規則

読み込みを試すのは **ディレクトリー名（ルート直下なら拡張子を除いたファイル名）と同じ名前のモジュールだけ**である。ebin に入っている BEAM を総当たりはしない。同梱した依存が勝手にプラグインとして読み込まれるのを防ぐためで、プラグイン作者から見れば「エントリーの名前は置き場所の名前と一致させる」という 1 つの規約になる。

- **Gleam**: プロジェクト名と同じトップレベルモジュール（`my_plugin/src/my_plugin.gleam`）をエントリーにし、ディレクトリー名も `my_plugin` にする。
- **Elixir**: `defmodule MyPlugin` は BEAM 上では `Elixir.MyPlugin` になる。**ディレクトリー名を `Elixir.MyPlugin` にすること。**
- **Erlang**: `-module(my_plugin)` なら `my_plugin`。

エントリーモジュール名が本体や先に読み込まれたプラグインと重なる場合、その候補はコードパスに何も足さずに丸ごと飛ばされる（次節）。

### 8.3 読み込み順

プラグインの**読み込み**は**モジュール名の昇順**で行い、`file:list_dir/1` が返す順序には依存しない。内蔵プラグイン（`console_logger`、`event_logger`）は常に外部プラグインより先に読み込まれる。ただし `handle_event/1` の**呼び出し順はプラグイン間では保証されない**（第 4 章）。

`plugin_name/0` の値が内蔵プラグインや既に読み込んだ外部プラグインと重なった場合、後から来た方は採用されない。名前はダッシュボードとログの識別子なので、内蔵・外部を区別せず一意にする。

### 8.4 コードパスと影（モジュール名前空間の衝突）

BEAM のモジュール名前空間はグローバルで、同じ名前のモジュールは VM 全体で 1 つしか存在できない。本体はプラグインの ebin を `code:add_pathz/1`（**末尾追加**）でコードパスへ足すため、次のようになる。

- **本体と本体の依存が常に優先される。** プラグインが新しい `gleam_stdlib` を同梱しても、使われるのは本体の版である。
- プラグイン同士では、名前順で先に読み込まれた側が勝つ。

食い違いは**読み込み時ではなく `handle_event/1` の実行時に `undef` として現れる。** 本体の版に無い関数を呼んだ時点で初めて失敗するので、`plugin.load` の検証では検出できない。したがって **プラグインは Dockerfile と同じ Gleam / OTP でビルドすること。** OTP が違う BEAM は `badfile` で拒否される。

影に入ったモジュールは、バンドルにつき 1 行にまとめて起動ログへ出る。

### 8.5 読み込みの失敗

**読み込みの失敗で本体の起動は止まらない。** 理由を 1 行出して、そのプラグインだけを無効にする。走査の最後には必ず集計行が出る。

| 行 | 意味 |
| --- | --- |
| `no PLUGIN_DIR set; external plugins disabled` | `PLUGIN_DIR` が未設定（または空文字列） |
| `<dir>: cannot read directory (enoent); external plugins disabled` | `PLUGIN_DIR` が読めない（`enotdir` / `eacces` も同じ形） |
| `<name>: cannot read directory (eacces); skipped` | プラグインのディレクトリーが読めない |
| `<name>: no ebin directory found (expected <name>/ebin or <name>/*/ebin)` | ディレクトリーはあるが ebin が見つからない |
| `<dir>: cannot add to code path (bad_directory); skipped` | `PLUGIN_DIR` 自身をコードパスへ足せなかった（ルート直下の `.beam` が対象） |
| `<name>: cannot add <ebin> to code path (bad_directory); skipped` | プラグインの ebin をコードパスへ足せなかった |
| `<name>: module <name> is already provided by the host or another plugin; skipped` | エントリーモジュール名が本体か他のプラグインと重なる |
| `<name>: N module(s) already provided by the host or another plugin are ignored (...)` | 同梱した依存が影に入った（読み込みは続行する） |
| `<mod>: duplicate plugin name "<name>"; keeping the first` | `plugin_name/0` の値が重複した |
| `loaded 2 plugin(s) from /plugins: file_logger, my_plugin (3 skipped)` | 集計。`skipped` は候補だったが読み込めなかったものの件数 |

モジュール自体の検証で失敗した場合の理由は第 9 章の表を参照すること。

### 8.6 同梱の例

同梱の例は 2 つある。どちらも Erlang 1 ファイルで、ビルド方法と置き方は各ディレクトリーの README を参照すること。

- `examples/plugins/file_logger/` は受信したイベントを 1 件 1 行でファイルへ追記する。**状態を持たない例**で、処理は `handle_event/2` の中で完結する。同時に**プラグイン固有の設定を受け取る例**でもあり、出力先を `PLUGIN_FILE_LOGGER_PATH` から受け取る。設定が必須なので `handle_event/1` はエクスポートせず、`plugin_children/1` で設定の有無だけを検査する（第 6 章）。
- `examples/plugins/counter/` は受信件数を gen_server で数える。**状態を持つ例**で、その gen_server を `plugin_children/0` で申告する（第 5 章）。設定を必要としないのでアリティ 0 のままであり、**既存のプラグインが無変更で動くことの実例**にもなっている。

第 10 章に載せる `test/support/minimal_plugin.erl` とは役割が違う。あちらは仕様の最小実装例で、本体の ebin に混ぜてコンパイルされるため最初からコードパス上にある（コードパスを足さなくても読めるので、ローダーの検証には使えない）。`file_logger` と `counter` はどちらも「外から持ち込む」側の例である。

## 9. 読み込まれない条件と理由の文字列

読み込みに失敗すると、次の形の 1 行がログに出る。先頭は BEAM のモジュール名である。自分のプラグインが読み込まれないときは、この文字列を手がかりにする。

| 理由の文字列 | 意味 |
| --- | --- |
| `<mod>: cannot load module (nofile)` | モジュールがコードパスに無い。ファイル名とモジュール名の不一致、置き場所の誤り |
| `<mod>: cannot load module (badfile)` | BEAM として読めない。壊れたファイル、または本体と違う OTP でビルドしたもの |
| `<mod>: missing export plugin_api_version/0` | 必須エクスポートが無い。`plugin_name/0` も同じ形で報告される |
| `<mod>: missing export handle_event/1 or handle_event/2` | イベント処理関数がどちらのアリティでも無い |
| `<mod>: plugin_api_version/0 crashed (error:badarg)` | メタデータの関数が例外を投げた。括弧内は `クラス:理由` |
| `<mod>: plugin_name/0 crashed (error:badarg)` | 同上。`plugin_name/0` が例外を投げた場合 |
| `<mod>: plugin_api_version/0 must return an Int, got Float` | 戻り値が整数でない |
| `<mod>: unsupported api version 2 (expected 1)` | 本体が対応していないバージョン |
| `<mod>: plugin_name/0 must return a String, got Int` | 名前が文字列（binary）でない |
| `<mod>: plugin_name/0 must not be empty` | 名前が空文字列 |
| `<mod>: plugin_children/0 crashed (error:badarg)` | 子仕様の問い合わせが例外を投げた |
| `<mod>: plugin_children/0 must return a list of child specification maps, got Dict` | 戻り値がリストでない（`dynamic.classify` は map を `Dict`、タプルを `Array` と呼ぶ） |
| `<mod>: plugin_children/0: child #0: must be a child specification map, got Array` | 子仕様が map でない。素の `{Module, Function, Args}` の短縮形はここで弾かれる（`dynamic.classify` はタプルを `Array` と呼ぶ） |
| `<mod>: plugin_children/0: child #0: missing id` | `id` が無い。番号は 0 起点のリストの位置 |
| `<mod>: plugin_children/0: child "store": missing start` | `start` が無い。`id` が読めた子はその値で名指しされる |
| `<mod>: plugin_children/0: child "store": unsupported shutdown (brutal_kill); use a number of milliseconds or infinity` | 表現できない `shutdown` |
| `<mod>: plugin_children/1 crashed (error:badarg)` | 設定を受け取る形の問い合わせが例外を投げた。理由の中のアリティは本体が呼んだ側のもの |
| `<mod>: plugin_children/1 rejected the configuration (path is required); 設定は PLUGIN_FILE_LOGGER_* で渡す` | プラグインが設定を受け付けなかった（第 6.4 節）。子を持たないプラグインでもこの行になる |
| `<mod>: plugin_children/1: error reason must be a String, got Atom` | `{error, Reason}` の `Reason` が binary でない |

検証は `plugin_api_version` → `plugin_name` → 設定の切り出し → `plugin_children` の順（上の表の順）で進み、最初に失敗したところで止まる。子仕様の誤りは 1 件だけ報告する。

## 10. Erlang での最小実装例

次のモジュールがそのまま動く最小のプラグインである（このファイルは `test/support/minimal_plugin.erl` としてテストにも使っており、読み込めることを検証している）。

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

## 12. Elixir で書くときの注意

- Elixir の `defmodule MyPlugin` は、BEAM 上では `Elixir.MyPlugin` という atom のモジュール名になる。**プラグインを置くディレクトリー名にはこの完全な名前を使うこと**（第 8 章のエントリーモジュール規則）。
- 関数は `def` で定義したものだけがエクスポートされる（`defp` は対象外）。
- 文字列リテラル `"minimal_plugin"` は binary なので、`plugin_name/0` の戻り値としてそのまま使える。
- イベント map のキーは binary である。`%{"kind" => kind}` でマッチすること。`%{kind: kind}` は atom キーになるためマッチしない。設定 map（第 6 章）も同じく binary キーである。
