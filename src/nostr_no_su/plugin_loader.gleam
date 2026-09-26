//// 外部プラグインの走査と読み込み。`PLUGIN_DIR` の中身を見て、プラグインの
//// BEAM をコードパスへ足し、`plugin.load` で検証したものを返す。`PLUGIN_DIR`
//// は `:` 区切りで複数のディレクトリーを並べられ、以下の `<PLUGIN_DIR>` は
//// そのうちの 1 つを指す。
////
//// 受け付けるレイアウトは 3 つで、`gleam export erlang-shipment` の出力を
//// そのまま置ける（同梱アプリの `.app` ファイルを壊さないよう flatten しない）。
////
//// - `<PLUGIN_DIR>/<name>.beam`
//// - `<PLUGIN_DIR>/<name>/ebin/`
//// - `<PLUGIN_DIR>/<name>/<app>/ebin/`
////
//// **エントリーモジュール規則。** 読み込みを試すのはディレクトリー名（ルート
//// 直下なら拡張子を除いたファイル名）と同じモジュールだけである。ebin に入って
//// いる BEAM を総当たりはしない。同梱された依存が勝手にプラグインとして読まれる
//// のを防ぐためで、プラグイン作者から見れば「エントリーの名前は置き場所の名前と
//// 一致させる」という 1 つの規約になる。
////
//// **影（モジュール名前空間の衝突）。** コードパスへの追加は `code:add_pathz`
//// （末尾追加）なので、本体と本体の依存、そして先に読み込まれたプラグインが常に
//// 勝つ。エントリーモジュールが既にコードパス上にある候補は、コードパスに何も
//// 足さずに丸ごと飛ばす。同梱された依存が影に入る場合は、バンドルごとに 1 行
//// 集約して報告する。報告には提供元のアプリと版を添える。ディレクトリーを
//// またいでも同じで、`PLUGIN_DIR` に先に並べたディレクトリーが勝つ。
////
//// **順序。** 読み込みはディレクトリーを指定された順に処理し、ディレクトリー
//// の中ではモジュール名の昇順で行い、`file:list_dir/1` の不定な順序に依存
//// しない。ただしコードパスへ足す順序だけは別で、ルート直下の
//// `.beam` が名前順に関係なく常にバンドルより先に入る。なおイベント処理関数の
//// 実行順はこれとは無関係である。プラグインはそれぞれ独立したランナープロセスで
//// 動くため、プラグイン間の実行順序は保証されない（`plugin_runner`）。
////
//// **プラグイン固有の設定はここでは切り出さない。** ローダーは `PLUGIN_*` の
//// 環境変数をそのまま `plugin.load` へ渡すだけで、接頭辞の規則を知らない。
//// 切り出しはプラグイン名が確定した後（`plugin.load` の中）で行われる。
////
//// **読み込みの失敗で起動を止めない。** 理由を 1 行ログに出して、そのプラグイン
//// だけを無効にする。

import gleam/dict.{type Dict}
import gleam/erlang/atom.{type Atom}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import nostr_no_su/log
import nostr_no_su/plugin.{type Plugin}
import nostr_no_su/plugin_runner

/// このモジュールが出すログ行の接頭辞。
pub const log_prefix = "plugin_loader"

/// アプリの分からないモジュールについて名前を挙げる件数。アプリが分かるものは
/// `shadow_sources` がすべて挙げる。
const shadow_sample_size = 3

/// 走査の報告 1 件。`Info` はログにだけ出す行（集計、影の報告、`PLUGIN_DIR`
/// 未設定）、`Failure` は候補 1 つを読み込めなかったこと。識別子と理由を分けて
/// 持つのは、管理 UI に理由だけを出すためである。
type Note {
  Info(text: String)
  Failure(id: String, reason: String)
}

/// 読み込めなかった候補 1 件。`id` はモジュール名かディレクトリー名で切らない。
/// `reason` はログの行で `<id>: ` に続く理由を `plugin_runner.max_reason_chars` に切ったもの。
pub type NotLoaded {
  NotLoaded(id: String, reason: String)
}

/// `load_all` の戻り値。`plugins` は読み込めたプラグイン。`notes` は今までどおり
/// `log.line` 済みの 1 行で、`not_loaded` は `notes` のうち失敗の行と同じ内容を
/// 構造にしたものである。
pub type LoadOutcome {
  LoadOutcome(
    plugins: List(Plugin),
    notes: List(String),
    not_loaded: List(NotLoaded),
  )
}

/// `PLUGIN_DIR`（`:` 区切りの 1 つ以上のディレクトリー）を左から順に走査して
/// 外部プラグインを読み込む。読み込めたプラグインと、起動ログに出す報告行と、
/// 読み込めなかった候補の一覧を `LoadOutcome` で返す。**失敗しても Error を
/// 返さない。**
///
/// `reserved` には内蔵プラグインの名前を渡す。プラグイン名はダッシュボードと
/// ログの識別子なので、内蔵と衝突する外部プラグインもここで弾く。
///
/// `plugin_env` には `PLUGIN_*` の環境変数（`config.plugin_env`）に本体の接続先を
/// `plugin_config.with_database_url` で足したものを渡す。走査・コードパス・影の
/// 判定には一切関与せず、`plugin.load` へそのまま渡すだけである。
///
/// `call_timeout_ms` は `plugin.load` へそのまま渡す、モジュールの読み込みと
/// メタデータ用のエクスポート 1 回ごとの期限。
///
/// `Plugin` は任意エクスポート `plugin_children/0` `plugin_children/1` から
/// 解決した子仕様（`children`）と、`plugin_pages` から解決した管理 UI の一覧
/// （実行の口 `plugin_page_action` の有無も同時に解決する）（`ui`）を持って
/// 返る。モジュール atom は `Plugin` に載せない（任意
/// エクスポートの問い合わせは、atom がまだ手元にある `plugin.load` の中で
/// 済ませる）。子仕様が API に合わないモジュールは `plugin.load` が弾くので、
/// ここでの扱いは他の検証失敗と同じ 1 行の報告になる。
pub fn load_all(
  plugin_dir: Option(String),
  reserved: List(String),
  plugin_env: Dict(String, String),
  call_timeout_ms: Int,
) -> LoadOutcome {
  let dirs = case plugin_dir {
    None -> []
    Some(raw) -> directories(raw)
  }
  let #(plugins, notes) = case dirs {
    [] -> #([], [Info("no PLUGIN_DIR set; external plugins disabled")])
    _ -> scan_all(dirs, reserved, plugin_env, call_timeout_ms)
  }
  LoadOutcome(
    plugins: plugins,
    notes: list.map(notes, note_line),
    not_loaded: list.filter_map(notes, fn(note) {
      option.to_result(to_not_loaded(note), Nil)
    }),
  )
}

/// `Note` をログの 1 行にする。`log.line` を呼ぶのはここだけである。
fn note_line(note: Note) -> String {
  case note {
    Info(text) -> log.line(log_prefix, text)
    Failure(id, reason) -> log.line(log_prefix, id <> ": " <> reason)
  }
}

/// `Failure` を `NotLoaded` にする。`Info` は候補ではないので `None`。理由は
/// `plugin_runner.max_reason_chars` に切る。
fn to_not_loaded(note: Note) -> Option(NotLoaded) {
  case note {
    Info(_) -> None
    Failure(id, reason) ->
      Some(NotLoaded(
        id: id,
        reason: plugin_runner.truncate(reason, plugin_runner.max_reason_chars),
      ))
  }
}

/// `PLUGIN_DIR` の生の値を、走査するディレクトリーの絶対パスの一覧にする。
/// `:` で分け、空の要素を落とす（`:` だけの指定は空リストになる）。
fn directories(raw: String) -> List(String) {
  string.split(raw, ":")
  |> list.filter(fn(part) { part != "" })
  |> list.map(absolute_path)
}

/// ディレクトリーを左から順に `scan` へ渡し、読み込めたプラグインと報告行を
/// 連結して返す。**順番に処理することが重要で**、`reserved` にはその時点で
/// 読み込めたプラグインの名前を足して渡す。これがないと 2 つ目以降の
/// ディレクトリーの同名プラグインが採用され、先勝ちが破れる。
fn scan_all(
  dirs: List(String),
  reserved: List(String),
  plugin_env: Dict(String, String),
  call_timeout_ms: Int,
) -> #(List(Plugin), List(Note)) {
  let #(plugins, notes) =
    list.fold(dirs, #([], []), fn(acc: #(List(Plugin), List(Note)), dir) {
      let #(plugins, notes) = acc
      let taken =
        list.append(reserved, list.map(plugins, fn(item) { item.name }))
      let #(found, dir_notes) = scan(dir, taken, plugin_env, call_timeout_ms)
      #(
        list.append(list.reverse(found), plugins),
        list.append(list.reverse(dir_notes), notes),
      )
    })
  #(list.reverse(plugins), list.reverse(notes))
}

/// 正規化済みのディレクトリーを走査して読み込む。ディレクトリーそのものが読め
/// なければ、理由を 1 行報告してこのディレクトリーだけを飛ばす（起動と他の
/// ディレクトリーの走査は続く）。
fn scan(
  dir: String,
  reserved: List(String),
  plugin_env: Dict(String, String),
  call_timeout_ms: Int,
) -> #(List(Plugin), List(Note)) {
  case list_dir(dir) {
    Error(reason) -> #([], [
      Failure(dir, "cannot read directory (" <> reason <> "); skipped"),
    ])
    Ok(names) -> {
      let #(bundles, beams) = entries(dir, list.sort(names, string.compare))
      let candidate_count = list.length(bundles) + list.length(beams)
      let #(flat_modules, flat_notes) = flat_candidates(dir, beams)
      let #(bundle_modules, bundle_notes) = bundle_candidates(dir, bundles)
      let modules =
        list.append(flat_modules, bundle_modules)
        |> list.sort(string.compare)
        |> list.unique
      let #(plugins, load_notes) =
        load_candidates(modules, reserved, plugin_env, call_timeout_ms)
      #(
        plugins,
        list.flatten([
          flat_notes,
          bundle_notes,
          load_notes,
          [Info(summary(dir, plugins, candidate_count))],
        ]),
      )
    }
  }
}

/// ディレクトリーの中身をバンドル候補（ディレクトリー）とルート直下の `.beam` に
/// 振り分ける。どちらでもないもの（`.gitkeep`、`README.md`、shipment の
/// `entrypoint.sh` など）は黙って無視する。ここで行を出すと、標準構成の起動ログが
/// ゴミ行だらけになる。
fn entries(dir: String, names: List(String)) -> #(List(String), List(String)) {
  let #(bundles, beams) =
    list.fold(names, #([], []), fn(acc, name) {
      case is_directory(join(dir, name)), string.ends_with(name, ".beam") {
        True, _ -> #([name, ..acc.0], acc.1)
        False, True -> #(acc.0, [name, ..acc.1])
        False, False -> acc
      }
    })
  #(list.reverse(bundles), list.reverse(beams))
}

/// ルート直下の `.beam` から候補モジュールを決める。エントリーが影のものは飛ばし、
/// 残った候補が 1 つ以上あるときだけディレクトリー自身をコードパスへ足す。
/// ここでは ebin の影の集計行を出さない。ルート直下では候補がディレクトリーの
/// 中身そのものなので、飛ばした候補ごとの行だけで足りる。
fn flat_candidates(
  dir: String,
  beams: List(String),
) -> #(List(String), List(Note)) {
  let #(modules, notes) =
    list.fold(beams, #([], []), fn(acc, file) {
      let module = beam_module_name(file)
      case entry_available(module) {
        True -> #([module, ..acc.0], acc.1)
        False -> #(acc.0, [shadowed_entry_note(module), ..acc.1])
      }
    })
  let modules = list.reverse(modules)
  let notes = list.reverse(notes)
  case modules {
    [] -> #([], notes)
    _ ->
      case add_code_path(dir) {
        Ok(Nil) -> #(modules, notes)
        Error(reason) -> #(
          [],
          list.append(notes, [
            Failure(dir, "cannot add to code path (" <> reason <> "); skipped"),
          ]),
        )
      }
  }
}

/// バンドル候補を順に処理して候補モジュールを決める。**順番に処理することが
/// 重要で**、先のバンドルがコードパスへ入った後に次のバンドルのエントリーを
/// 判定するため、プラグイン同士の影も名前順で「先勝ち」になる。
fn bundle_candidates(
  dir: String,
  bundles: List(String),
) -> #(List(String), List(Note)) {
  let #(modules, notes) =
    list.fold(bundles, #([], []), fn(acc, name) {
      let #(modules, notes) = acc
      case adopt_bundle(dir, name) {
        Ok(bundle_notes) -> #(
          [name, ..modules],
          list.append(list.reverse(bundle_notes), notes),
        )
        Error(note) -> #(modules, [note, ..notes])
      }
    })
  #(list.reverse(modules), list.reverse(notes))
}

/// バンドル 1 つをコードパスへ迎え入れる。採用できたら影の報告行（0 行か 1 行）
/// を、採用しなかったら理由の行を返す。
fn adopt_bundle(dir: String, name: String) -> Result(List(Note), Note) {
  use _ <- result.try(case entry_available(name) {
    True -> Ok(Nil)
    False -> Error(shadowed_entry_note(name))
  })
  use ebins <- result.try(ebin_dirs(dir, name))
  // ebin が複数あるバンドルで 2 つめ以降の追加が失敗すると、先に足した ebin は
  // コードパスに残ったままバンドルだけが捨てられる。`is_directory` が真の ebin を
  // `code:add_pathz/1` が拒むのは、確かめた直後に消える競合や、パスの途中に `.ez` で
  // 終わる名前がある置き方（アーカイブの中として読まれる）で、どれもまれなので
  // 巻き戻しは持たない。
  use shadows <- result.map(
    list.try_fold(ebins, [], fn(shadows, ebin) {
      // 影の集計は `add_code_path` の**前に**行う。足した後では自分自身の
      // モジュールがすべて「既にコードパス上にある」ことになってしまう。
      let found = shadowed(ebin)
      case add_code_path(ebin) {
        Ok(Nil) -> Ok(list.append(shadows, found))
        Error(reason) ->
          Error(Failure(
            name,
            "cannot add " <> ebin <> " to code path (" <> reason <> "); skipped",
          ))
      }
    }),
  )
  shadow_note(name, list.unique(shadows))
}

/// バンドルが持つ ebin ディレクトリー。`<name>/ebin` と `<name>/<app>/ebin` の
/// 2 段だけを見る（再帰探索はしない）。1 つも無ければ理由の行を Error で返す。
///
/// `<name>` 自身を読めないとき（`eacces` など）は専用の行を出す。「読めない
/// ディレクトリー」は `PLUGIN_DIR` 自身とは限らないため、黙って
/// `no ebin directory found` に丸めない。
fn ebin_dirs(dir: String, name: String) -> Result(List(String), Note) {
  let base = join(dir, name)
  let direct = case is_directory(join(base, "ebin")) {
    True -> [join(base, "ebin")]
    False -> []
  }
  use nested <- result.try(case list_dir(base), direct {
    Ok(subs), _ -> Ok(nested_ebins(base, subs))
    // `<name>/ebin` が直接見つかっているなら、読めなかったのは入れ子の探索だけ
    // なのでそのまま続行する。「辿れるが列挙できない」権限（`chmod 0111` など）
    // では実際にこの組み合わせになり、`file:list_dir/1` は `eacces` を返すのに
    // `filelib:is_dir/1` は真を返す。
    Error(_), [_, ..] -> Ok([])
    Error(reason), [] ->
      Error(Failure(name, "cannot read directory (" <> reason <> "); skipped"))
  })
  case list.append(direct, nested) {
    [] ->
      Error(Failure(
        name,
        "no ebin directory found (expected "
          <> name
          <> "/ebin or "
          <> name
          <> "/*/ebin)",
      ))
    found -> Ok(found)
  }
}

/// 入れ子になったアプリごとの ebin（`<name>/<app>/ebin`）。`gleam export
/// erlang-shipment` はアプリごとに ebin を分けるため、この形も受け付ける。
fn nested_ebins(base: String, subs: List(String)) -> List(String) {
  list.sort(subs, string.compare)
  |> list.map(fn(sub) { join(join(base, sub), "ebin") })
  |> list.filter(is_directory)
}

/// ebin の中で、既にコードパス上にあるモジュールの名前。`add_code_path` の前に
/// 呼ぶこと。
fn shadowed(ebin: String) -> List(String) {
  case list_dir(ebin) {
    Error(_) -> []
    Ok(names) ->
      list.sort(names, string.compare)
      |> list.filter(string.ends_with(_, ".beam"))
      |> list.map(beam_module_name)
      |> list.filter(fn(module) { !entry_available(module) })
  }
}

/// 影に入ったモジュールの報告。バンドルにつき 1 行に集約し、提供元のアプリと
/// 版をすべて、アプリの分からないモジュールは先頭数件の名前を挙げる。1 つも
/// 無ければ行を出さない。
fn shadow_note(name: String, modules: List(String)) -> List(Note) {
  case modules {
    [] -> []
    _ -> [
      Info(
        name
        <> ": "
        <> int.to_string(list.length(modules))
        <> " module(s) already provided by the host or another plugin are ignored ("
        <> shadow_sources(modules)
        <> ")",
      ),
    ]
  }
}

/// 影に入ったモジュールの提供元を括弧内の 1 行にする。アプリの分かるものは
/// `app vsn` を重複なしですべて、分からないものはモジュール名を
/// `shadow_sample_size` 件まで挙げる。
fn shadow_sources(modules: List(String)) -> String {
  let #(apps, unknowns) =
    list.fold(modules, #([], []), fn(acc, module) {
      let #(apps, unknowns) = acc
      case module_application(atom.create(module)) {
        Ok(#(app, vsn)) -> #([app <> " " <> vsn, ..apps], unknowns)
        Error(Nil) -> #(apps, [module, ..unknowns])
      }
    })
  let apps = list.reverse(apps) |> list.unique
  let unknowns = list.reverse(unknowns)
  let sample = list.take(unknowns, shadow_sample_size)
  let rest = case list.length(unknowns) > shadow_sample_size {
    True -> ", ..."
    False -> ""
  }
  string.join(list.append(apps, sample), ", ") <> rest
}

/// エントリーモジュールが影に入っている候補の報告。
fn shadowed_entry_note(name: String) -> Note {
  Failure(
    name,
    "module "
      <> name
      <> " is already provided by the host or another plugin; skipped",
  )
}

/// エントリーモジュール名として使えるか。コードパスに何かを足す**前に**問い合わ
/// せること。足した後に捨てる形にすると、採用しないプラグインの ebin が恒久的に
/// コードパスへ残り、後続のプラグインを影にしてしまう。
///
/// 判定を「ebin に入っている `.beam` の集合」から導いてはならない。エントリーの
/// BEAM を同梱していないバンドルでは集合に名前が入らず、判定が発火しないまま
/// ホスト側の同名モジュールを読み込んで成功してしまう。
fn entry_available(module: String) -> Bool {
  !is_on_code_path(atom.create(module))
}

/// 候補モジュールを名前順に読み込む。失敗理由は `plugin.load` が組み立てた
/// 1 行をそのまま出す。名前が内蔵プラグインや既出の外部プラグインと重なるものは
/// 採用せず、先に読み込んだ方を残す。
fn load_candidates(
  modules: List(String),
  reserved: List(String),
  plugin_env: Dict(String, String),
  call_timeout_ms: Int,
) -> #(List(Plugin), List(Note)) {
  let #(plugins, notes) =
    list.fold(modules, #([], []), fn(acc: #(List(Plugin), List(Note)), module) {
      let #(plugins, notes) = acc
      case plugin.load(atom.create(module), plugin_env, call_timeout_ms) {
        Error(reason) -> #(plugins, [Failure(module, reason), ..notes])
        Ok(loaded) -> {
          let taken =
            list.append(reserved, list.map(plugins, fn(item) { item.name }))
          case list.contains(taken, loaded.name) {
            True -> #(plugins, [
              Failure(
                module,
                "duplicate plugin name \""
                  <> loaded.name
                  <> "\"; keeping the first",
              ),
              ..notes
            ])
            False -> #([loaded, ..plugins], notes)
          }
        }
      }
    })
  #(list.reverse(plugins), list.reverse(notes))
}

/// 走査の結果をまとめる 1 行。`skipped` に数えるのは「プラグイン候補だったが
/// `Plugin` にならなかったもの」すべてで、`.gitkeep` のようにそもそも候補で
/// なかったエントリーは含めない。0 件のときは括弧ごと省く。
fn summary(dir: String, plugins: List(Plugin), candidates: Int) -> String {
  let skipped = candidates - list.length(plugins)
  let tail = case skipped {
    0 -> ""
    _ -> " (" <> int.to_string(skipped) <> " skipped)"
  }
  let head = case plugins {
    [] -> "loaded no plugins from " <> dir
    _ ->
      "loaded "
      <> int.to_string(list.length(plugins))
      <> " plugin(s) from "
      <> dir
      <> ": "
      <> string.join(list.map(plugins, fn(item) { item.name }), ", ")
  }
  head <> tail
}

/// パスを結合する。`dir` の末尾のスラッシュは吸収する。`directories` が
/// `absolute_path` を通すので、末尾にスラッシュが残るのは `PLUGIN_DIR` が `/` の
/// ときだけである。
pub fn join(dir: String, name: String) -> String {
  case string.ends_with(dir, "/") {
    True -> join(string.drop_end(dir, 1), name)
    False -> dir <> "/" <> name
  }
}

/// `.beam` のファイル名からモジュール名を取り出す。
fn beam_module_name(file: String) -> String {
  string.drop_end(file, string.length(".beam"))
}

/// ディレクトリーの中身（名前のみ）。失敗理由は `enoent` などの文字列。
@external(erlang, "nostr_no_su_plugin_ffi", "list_dir")
fn list_dir(path: String) -> Result(List(String), String)

/// パスがディレクトリーかどうか。
@external(erlang, "filelib", "is_dir")
fn is_directory(path: String) -> Bool

/// 相対パスを絶対パスにする。ログ行とコードパスの内容を食い違わせないため、
/// `PLUGIN_DIR` の各ディレクトリーは `directories` で 1 度だけこれを通す。
@external(erlang, "filename", "absname")
fn absolute_path(path: String) -> String

/// ディレクトリーをコードパスの末尾に足す。
@external(erlang, "nostr_no_su_plugin_ffi", "add_code_path")
fn add_code_path(path: String) -> Result(Nil, String)

/// モジュールが既にコードパス上にあるか。
@external(erlang, "nostr_no_su_plugin_ffi", "is_on_code_path")
fn is_on_code_path(module: Atom) -> Bool

/// モジュールとして使われる BEAM が属するアプリケーションの名前と版。ebin の
/// `.app` が 1 つに決まらなければ Error。
@external(erlang, "nostr_no_su_plugin_ffi", "module_application")
fn module_application(module: Atom) -> Result(#(String, String), Nil)
