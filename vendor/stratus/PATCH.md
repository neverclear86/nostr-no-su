# vendor/stratus の由来とパッチ

このディレクトリーは、WebSocket クライアントの stratus を hex から取り込み、nostr-no-su が改変したものである。
この文書は、取り込んだ上流の版と、上流に当てたパッチと、パッチを戻す条件を記録する。

`dev/check_vendor_stratus.sh` は、上流の tar にパッチを当てた結果が、このディレクトリー（この文書と `patches/` を除く）と一致するかを検査する。
CI の `vendor-stratus` ジョブがこの検査を実行する。

## 上流

検査のスクリプトが「版」と「tar の SHA-256」の行を読むので、行の書式（`| 項目 | ` のあとにバッククォートで囲んだ値）を変えない。

| 項目 | 値 |
| --- | --- |
| 版 | `3.0.0` |
| tar の SHA-256 | `21c93d657e4e7964e36eacde83609459f259289df403b5febd3c60612594be24` |
| commit | `34f9ed786ab1dcb3161aab34ae6d5abd2b0531e1` |

- tar は `https://repo.hex.pm/tarballs/stratus-<版>.tar` である。SHA-256 は tar 全体に対するもので、hex の API（`https://hex.pm/api/packages/stratus/releases/<版>`）が返す `checksum` と同じ値である。
- commit は GitHub の rawhat/stratus のタグ `v<版>` が指すものである。そのツリーの `LICENSE`、`README.md`、`gleam.toml`、`src/` は、tar の中身から下の生成物を除いたものと一致する。上流の履歴を読むための参照で、検査には使わない。
- ライセンスは Apache License 2.0 で、本文は `LICENSE` にある。

## 上流の tar から取り込む範囲

tar の中の `contents.tar.gz` を展開し、hex への公開のときに Gleam が生成したファイル（`include/`、`src/stratus.app.src`、`src/stratus.erl`、`src/stratus@*.erl`）を除いたものを、パッチを当てる前の中身とする。
これらの生成物は `gleam build` の成果物に影響しない（残してビルドしても `stratus.beam` は同じになる）。
一方で `src/stratus.erl` はパッチを当てる前のコードから生成されたもので、`permessage-deflate` のオファーを含む。
同梱すると、読み手が当たっていないコードを読むことになるので除く。

## パッチ

パッチは 1 件につき 1 ファイルで、`patches/<4 桁の番号>-<名前>.patch` に置く。
検査はファイル名の順に `patch -p1 --fuzz=0 --no-backup-if-mismatch` で当てる。
前後の文脈の行が一致すれば行の位置のずれは許されるので、変更した行と前後の文脈の行が重ならないパッチどうしは、当てる順序に依存しない。
重なって検査が失敗したときは、後からマージする側が手順 2 でパッチを作り直す。

### 0001 permessage-deflate をオファーしない

- ファイル: `patches/0001-no-permessage-deflate.patch`
- 変更: `src/stratus.gleam` の `make_upgrade` から、ハンドシェイクの `sec-websocket-extensions: permessage-deflate` の行を消し、理由のコメントを置く。
- 理由: gramps 6.0.1 は、断片化されたメッセージの各フレームを、連結する前に inflate する（`gramps/websocket.gleam` の `decode_frame` がフレームごとに `inflate` を呼び、`aggregate_frames` がその後で連結する）。strfry 系のリレーが送る複数フレームの圧縮メッセージは、この順序では zlib の `data_error` でクラッシュする。拡張をオファーしなければ、リレーは圧縮しないフレームを送る。
- 戻す条件: gramps が断片を連結してから inflate する版を hex に出し、stratus がその版を使えるようになったとき（rawhat/gramps#7 がこの変更を含む。2026-09-12 の時点で未マージ）。戻す前に、strfry から複数フレームの圧縮メッセージを受け取れることを確かめる。

### 0002 README に改変版である旨を書く

- ファイル: `patches/0002-readme-modified-notice.patch`
- 変更: `README.md` の冒頭に、改変して同梱したものであることと、この文書の場所を書く。
- 理由: 上流の README は hex 版の導入の手順（`gleam add stratus`）と機能の一覧（Per-message deflate を含む）を載せており、このディレクトリーの中身と食い違う。
- 戻す条件: ほかのパッチがすべて不要になり、vendor をやめて hex の stratus に戻すとき。

### 0003 名前解決の失敗をソケットの理由に加える

- ファイル: `patches/0003-nxdomain-socket-reason.patch`
- 変更: `src/stratus/internal/socket.gleam` と `src/stratus.gleam` の `SocketReason` に `Nxdomain` を足し、`src/stratus.gleam` の `convert_socket_reason` と `src/stratus_ffi.erl` の `parse_known_socket_reason/1` に対応を足す。
- 理由: `gen_tcp:connect` と `ssl:connect` は、ホスト名を名前解決できないと `{error, nxdomain}` を返す。上流の `SocketReason` にはこの値が無く、`perform_handshake` の中の `convert_socket_reason` が `case_clause` で落ちる。アクターの初期化の中で落ちるので、再接続の試行ごとにクラッシュレポートが出て、`start` はスタックトレースを含む `InitExited` を返す（nostr-no-su の #46）。
- 戻す条件: 上流の stratus が名前解決の失敗で落ちない版を hex に出し、その版に上げるとき。2026-09-13 の時点で hex の最新は 3.0.0 で、rawhat/stratus の main の `src/stratus.gleam` にも `nxdomain` の扱いは無い。

### 0004 ハンドシェイクの失敗を error の水準でログに出さない

- ファイル: `patches/0004-handshake-failure-debug-log.patch`
- 変更: `src/stratus.gleam` の `start` で、ハンドシェイクの失敗の文を `logging.log` に渡す水準を `Error` から `Debug` にする。
- 理由: 同じ文は `InitFailed` で呼び出し元に返る。nostr-no-su はそれを再接続の予告と一緒に 1 行で出すので、error の水準のままだと、試行ごとに `=ERROR REPORT====` の 2 行が重なる。Erlang の logger で抑えるには `logging` モジュール全体の水準を下げるしかなく、同じ `logging` パッケージを使う mist、glisten、wisp のエラーも消える。
- 戻す条件: 上流の stratus がハンドシェイクの失敗を error の水準で出さなくなった版に上げるとき。

### 0005 受信バッファに上限を設ける

- ファイル: `patches/0005-receive-buffer-limit.patch`
- 変更: `src/stratus.gleam` に `max_buffer_bytes`（4 MiB）を足し、`start` の `Data` の処理で、まだフレームにデコードしていないバイトがこれを超えたら、アクターを `stop_abnormal` で止める。上限はヘッダーを含むバイト数に掛かり、ペイロード長の上限ではない。
- 理由: 上流は受信したバイトを `State` の `buffer` に上限なく溜める。gramps の `decode_many_frames` は、揃っていないフレームも不正なフレームも残りとして返すので、巨大な長さを宣言したフレームや不正なバイトを送るリレーが、プロセスのメモリを使い尽くしうる（nostr-no-su の #87）。止めたアクターは、nostr-no-su の `relay_connection` が張り直す。
- 戻す条件: 上流の stratus が受信のバッファかフレーム長に上限を持つ版を hex に出し、その版に上げるとき。2026-09-13 の時点で hex の最新は 3.0.0 で、rawhat/stratus の main の `src/stratus.gleam` にも上限は無い。

### 0006 受信した pong をユーザーのループへ渡す

- ファイル: `patches/0006-deliver-pong.patch`
- 変更: `src/stratus.gleam` の `Message` に `Pong(BitArray)` を足し、`handle_frame` の pong の枝でユーザーのループを呼ぶ。Text / Binary の枝と共通の処理は `run_user_loop` にまとめた。
- 理由: 上流は pong を黙って捨てるので、自分から送った ping への応答を観測できず、ハーフオープンの接続を検知できない（nostr-no-su の #83）。
- 戻す条件: 上流の stratus が pong をハンドラーへ渡すか、キープアライブを持つ版を hex に出し、その版に上げるとき。2026-09-13 の時点で hex の最新は 3.0.0 で、rawhat/stratus の main の `src/stratus.gleam` にも pong をユーザーのループへ渡す変更は無い。

## パッチを足す手順

1. このディレクトリーの中のファイルを直し、直した箇所に `VENDORED PATCH (nostr-no-su):` で始まるコメントで変更と理由を書く。README のような文書は、0002 のように冒頭に注記を置く。Apache License 2.0 の 4 (b) が、改変したファイルに改変した旨を示すことを求めるためである。
2. リポジトリのルートで `sh dev/check_vendor_stratus.sh > vendor/stratus/patches/<番号>-<名前>.patch` を実行する。残った差分がそのままパッチのファイルになり、検査は 1 で終わる。書き出し先は実行の最初に空のファイルとして作られるが、`patch` は空のパッチを何もせずに読み飛ばす。
3. 「パッチ」の節に、ファイル、変更、理由、戻す条件を書いた節を足す。
4. `sh dev/check_vendor_stratus.sh` が 0 で終わることを確かめる。

パッチのファイルは手で書かず、手順 2 の出力から作る。
差分の書式（`index` の行の hash の桁数など）は git の設定で変わりうるが、パッチの適用と検査の結果には影響しない。

番号は main にある最大の番号に 1 を足したものにする。
並行するブランチと番号が重なったら、後からマージする側が振り直す。

上流の版を上げるときは、「上流」の表の版、tar の SHA-256、commit を書き換え、各パッチを新しい版に当たるように作り直す。
