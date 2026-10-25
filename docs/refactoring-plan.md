# リファクタリング計画

podcast-publishing-toolkit の保守性・堅牢性を高めるためのリファクタリング計画です。個人規模のツールであることを踏まえ、過剰な設計を避けつつ、各フェーズを独立してコミット・検証できる形にまとめています。

## 1. 現状の課題

本ツールキットは Ruby スクリプト 4 本からなるポッドキャスト公開パイプラインです。いずれも自己完結型（`main if __FILE__ == $PROGRAM_NAME`）で、外部 CLI（`ffmpeg` / `ffprobe` / `nlm` / `aws`）に依存しています。

| ファイル | 行数 | 役割 |
| --- | --- | --- |
| `convert_meet_recordings.rb` | 139 | mp4 → mp3 変換 |
| `master_for_podcast.rb` | 330 | 音声マスタリング |
| `create_notebooklm_notebooks.rb` | 348 | NotebookLM ノート・メタデータ生成 |
| `publish_to_spotify.rb` | 640 | R2 アップロード・RSS 更新 |

### 1.1 重複コード（共有ライブラリがなく、すべてコピペ）

- **nlm の notebook 一覧 → ファイル名マップ構築**: `fetch_notebooks_state`（`create_notebooklm_notebooks.rb:30-62`）と `fetch_filename_to_notebook_id_map`（`publish_to_spotify.rb:176-201`）がほぼ同一。
- **`PODCAST_NOTE_TITLE` 定数の二重定義**: `create_notebooklm_notebooks.rb:13` と `publish_to_spotify.rb:27`（クォートスタイルだけ違い、値は同じ）。
- **ffprobe による尺取得**: `get_audio_duration`（`master_for_podcast.rb:92`）と `mp3_duration_seconds`（`publish_to_spotify.rb:157`）が同じ ffprobe 呼び出し。
- **nlm query の回答抽出**: `extract_answer`（`create_notebooklm_notebooks.rb:99`）と `fetch_metadata_note_text` 内の `dig` パス（`publish_to_spotify.rb:241`）。
- **CLI/ディレクトリ処理のボイラープレート**: `parse_arguments` / `validate_source_directory` / `ensure_destination_directory` / `skip_existing_output?` / 出力パス生成が、`convert_meet_recordings.rb` と `master_for_podcast.rb` でほぼ逐語的に重複。

### 1.2 バグ・脆弱な箇所

- **シェル文字列補間による ffmpeg 呼び出し**（`convert_meet_recordings.rb:21`）: コマンドを補間文字列で組み立てて `Open3.capture3(文字列)` に渡している。他 3 スクリプトは配列形式（`capture3(*cmd)`）で安全。Meet のファイル名には空白・`:`・`～` などが含まれ、`"` が入るとコマンドが壊れる。**実害のあるバグ。**
- **`require 'set'` の欠落**（`create_notebooklm_notebooks.rb`）: `Set.new` を使うが require していない。Ruby 3.2 以上の autoload に依存しており、それ未満では `NameError`。`publish_to_spotify.rb:8` は正しく require しており不整合。
- **巨大関数 `run_publish`**（`publish_to_spotify.rb:415-544`, 約 130 行）: スケジュール解決・glob・feed 読み込み・ファイル単位ループ・dry-run/ステージング分岐・サマリ出力が混在。
- **脆弱なパース処理**（`publish_to_spotify.rb:203-265`）: `fetch_metadata_note_text` + `normalize_literal_escapes` + `unescape_once` が、nlm の不正な JSON エスケープ出力（二重 JSON・不正な `\[`・多段エスケープ）に対する 5 パスの un-escape 対応。壊れやすくテストがない。
- **CWD 相対の feed パス**（`publish_to_spotify.rb:30`）: `DEFAULT_LOCAL_FEED_PATH = 'feed.xml'` が CWD 相対で CLI 上書き不可。別ディレクトリから実行すると別の `feed.xml` を静かに使用/生成してしまう。

### 1.3 ツーリング・ドキュメントの欠如

- `Gemfile` / lockfile なし、テストなし、CI なし、`.rubocop.yml` なし（全ファイルに `# frozen_string_literal: true` はあるが linter 設定は無い）。
- README の記述がコードと不一致: 無音閾値を「1 秒以上」と記載しているが実装は `SILENCE_DURATION_SEC = 1.5`（`master_for_podcast.rb:22`）。また `silenceremove` に言及しているが、実際は atrim/afade/concat を使用。

## 2. 方針

- スクリプトはリポジトリ直下のまま、従来どおり `ruby publish_to_spotify.rb --dry-run` などで実行可能に保つ。**gem 化・Thor 等の CLI フレームワーク導入・クラス階層化はしない。**
- **2 スクリプト以上で実際に重複しているコードだけ**を `lib/` に抽出する。単一スクリプト固有のコード（feed/RSS、R2、マスタリングのフィルタ）はそのまま残す。
- 脆弱なコード（nlm un-escape、feed.xml の REXML シリアライズ）は、移動・変更する**前に**フィクスチャテストで挙動をロックする。
- 各スクリプトは `require_relative 'lib/podcast_toolkit/...'` で読み込む（スクリプト相対なので CWD に依存しない）。

## 3. フェーズ別計画

各フェーズは独立してコミット・検証可能で、どのフェーズで止めてもリポジトリは着手前より確実に良い状態になります。

### Phase 0 — 即効バグ修正（約 30 分）

構造変更を伴わない安全な修正。

1. `convert_meet_recordings.rb:21` を配列形式に変更（他 3 スクリプトと統一）:
   ```ruby
   # Before
   ffmpeg_cmd = "ffmpeg -i \"#{input_path}\" -vn -ab 192k -y \"#{output_path}\""
   # After
   Open3.capture3('ffmpeg', '-i', input_path, '-vn', '-ab', '192k', '-y', output_path)
   ```
2. `create_notebooklm_notebooks.rb` に `require 'set'` を追加。

**検証**: 両ファイルに `ruby -c`。ダブルクォート・空白を含むファイル名を持つディレクトリで convert スクリプトを実行。修正ごとに個別コミット。

### Phase 1 — 最小ツーリング（約 45 分）

- **Gemfile**: `gem 'minitest'` と `gem 'rake'` のみ。ランタイム依存は stdlib（open3, json, rexml, uri, yaml, fileutils）のみを維持。`.ruby-version` を追加（Gemfile の `ruby` ディレクティブはマシン更新で壊れやすいので省略）。
- **Rakefile**: **テストファイルごとに別プロセスで実行**する test タスク。
  ```ruby
  task :test do
    Dir['test/*_test.rb'].each { |f| sh RbConfig.ruby, f }
  end
  ```
  これはスタイルではなく必須。`publish_to_spotify.rb` と `create_notebooklm_notebooks.rb` は `PODCAST_NOTE_TITLE` と `SLEEP_BETWEEN` を**異なる値で**二重定義しており、1 プロセスで両方 require すると定数が衝突する。Phase 3 で重複を解消するまではプロセス分離で回避する。
- **RuboCop**: 当面見送り。4 ファイル・単独作者・貢献者なしの状況では、linter はクォートスタイルの差分churn を生むだけで安全性の利得がない。
- **CI**: 任意。GitHub 上にあるなら `.github/workflows/test.yml`（setup-ruby + `bundle exec rake test`、約 15 行）を追加する価値あり。ローカルのみなら見送り。

**検証**: `bundle install` → `bundle exec rake test`（空スイートが pass）。

### Phase 2 — 純粋関数のテストロック（2〜3 時間）

抽出・変更の**前に**テストを書き、挙動を固定する。各テストファイルは `require_relative '../<script>.rb'` で読み込む（`__FILE__ == $PROGRAM_NAME` ガードによりライブラリとして無変更で読める）。1 スクリプト = 1 テストファイル（Phase 1 のプロセス分離）。

**`test/publish_to_spotify_test.rb`（最重要・最も脆弱）**
- `unescape_once` / `normalize_literal_escapes`（`:203-227`）: `\\n`→改行、`\[`→`[`、多段 `\\\\n`、冪等性、非文字列入力、5 回上限。**実際の不正 nlm ノート出力を 2〜3 件フィクスチャ化**（`test/fixtures/nlm_note_*.json`）。これがこのコードの契約であり、これなしに後の「整理」は博打になる。
- `parse_metadata` / `strip_citations`（`:267-279`）: タイトル/説明の正常系、`：` と `:`、引用マーカー `[1]` `[1, 2]` `[1-3]`、説明欠落 → nil。
- `format_duration` / `compute_pub_date`（間隔計算、index 0）。
- `r2_key` / `r2_public_url`（リテラルな config ハッシュで）。
- **feed のゴールデンテスト**（Phase 4 のロック）: 合成した最小 `test/fixtures/feed_min.xml`（channel + item 1 つ、実構造を模す。**gitignore された実 feed.xml はコミットしない**）に対し、`load_feed`→`ensure_itunes_namespace`→`existing_guids`→`append_item(固定引数)`→`write_feed`(tempfile) を実行し、コミット済みゴールデン出力とバイト単位で比較。REXML のフォーマット癖こそ壊してはいけない部分。

**`test/master_for_podcast_test.rb`**
- `silence_to_cut_ranges`（`:126`）: truncate_to 未満の無音を drop、半分残しの計算。
- `keep_ranges_from_cuts`（`:136`）: 先頭カット、隣接カット、total_duration を超えるカット、1ms 未満レンジのフィルタ。
- `build_keep_filter_graph` / `keep_segment_filter`（`:147-178`）: 1 レンジ・3 レンジ入力の**フィルタグラフ文字列を完全一致で固定**。`%.6f` フォーマットと asplit/concat 配線は音声の契約。
- `extract_loudnorm_json`（`:180`）: 実 ffmpeg loudnorm stderr（ログノイズ + JSON、`rindex` の挙動）フィクスチャで。
- `filter_complex_for_processing` / `db_to_linear` / `acompressor_filter` / `output_path_for`。

**`test/create_notebooklm_test.rb`**
- `extract_answer`（`:99`）: `{"value":{"answer":...}}` / フラット `{"answer":...}` / 不正 JSON → 生テキスト fallback。
- `thinking_frame?` / `extract_notebook_id`（`"ID: abc123"` パース）。

**`test/convert_meet_recordings_test.rb`（小）**
- `generate_output_path` / `skip_chat_file?`。

**検証**: `bundle exec rake test` が green。以降すべての安全網になる。

### Phase 3 — 共有 lib の抽出（2〜3 時間）

```
lib/
  podcast_toolkit/
    cli.rb      # PodcastToolkit::CLI
    ffmpeg.rb   # PodcastToolkit::FFmpeg
    nlm.rb      # PodcastToolkit::Nlm
```

各モジュールは `module_function` を使用。autoloader やアンブレラファイルは作らず、3 つの明示 require で十分。**リスクの低い順**に 1 モジュールずつ。

**3a. `cli.rb`（最低リスク）** — convert/master の重複から:
- `parse_source_dest_args(usage_example:)`（両 `parse_arguments` を統合）
- `validate_source_directory` / `ensure_destination_directory`
- `skip_existing_output?` / `output_path_for(input_path, dest_dir, ext: '.mp3')`（master の `output_path_for` と convert の `generate_output_path` を統一）
- `convert_meet_recordings.rb` と `master_for_podcast.rb` を更新しローカルコピーを削除。**検証**: 両スクリプトを小さなサンプルディレクトリで実行し、コンソール出力が同一であること。

**3b. `ffmpeg.rb`**:
- `audio_duration(path)`（`get_audio_duration` と `mp3_duration_seconds` を統合、`Float` or `nil` を返す）。
- **検証**: master で 1 ファイル処理、publish `--dry-run` で同じ尺が出ること。

**3c. `nlm.rb`（最後・脆弱だが Phase 2 でテスト済み）**:
- `PODCAST_NOTE_TITLE` 定数（単一の source of truth。重複定数の衝突も解消）。
- `notebook_list` / `source_list(id)` / `note_list(id)`（`Open3.capture3('nlm', ...)` + `JSON.parse` の薄いラッパ。create 側の `force_encoding('UTF-8')` 処理を採用）。
- `notebooks_state`（create 版, `:30-62`）。publish の `fetch_filename_to_notebook_id_map` は `notebooks_state[:notebook_by_filename]` に置換（挙動同一）。
- `extract_answer` / `thinking_frame?`（create から）。
- `unescape_once` / `normalize_literal_escapes` / `fetch_note_text`（publish `:203-265` から）— **無編集で移動**。Phase 2 のフィクスチャを lib に向け直して green を維持。
- **検証**: 取り込み済みディレクトリで create スクリプト実行（全 skip 報告）。publish `<dir> --dry-run` の出力をリファクタ前キャプチャと diff。

**据え置くもの**: R2/aws ヘルパ、feed/RSS コード、env/config 読み込み（publish 専用）、マスタリングのフィルタ生成（master 専用）、プロンプト/タイムアウト（create 専用）。

### Phase 4 — `run_publish` の分解（1〜2 時間）

`publish_to_spotify.rb:415-544` を、同ファイル内の private トップレベル関数に分割（新規 lib は作らない）:

```ruby
def run_publish(mp3_dir, config, options)
  schedule  = resolve_schedule!(config, options)   # 416-421
  mp3_files = find_mp3_files!(mp3_dir)             # 423-427
  feed      = prepare_feed(config)                  # 429-433
  nb_map    = PodcastToolkit::Nlm.notebooks_state[:notebook_by_filename]
  counts    = publish_episodes(mp3_files, feed, nb_map, schedule, config, options)
  finalize_feed!(feed, counts, config, options)     # 522-539
  print_publish_summary(counts, mp3_files.size)     # 541-543
end
```

- `publish_episodes` がループと `counts = {added:, skipped:, failed:}` と `next_index` を保持。ファイル単位の処理は `publish_one_episode(mp3, index, ctx)` に切り出し `:added/:skipped/:failed` を返す。
- `publish_one_episode` 内で純粋な組み立てと副作用を分離:
  - `build_episode(mp3, notebook_id, pub_date, config)` → episode ハッシュ or `nil`（`:462-482`）。ノートテキストをスタブすればユニットテスト可能。
  - dry-run 分岐（`:484-494`）→ `print_dry_run(episode)`。
  - 実処理分岐（`:496-519`）→ upload + `append_item` + guid 管理。
- **保持すべき不変条件**（前後の `--dry-run` diff と Phase 2 の feed ゴールデンテストで確認）: skip/fail の判定順（guid → notebook → metadata → duration）、`next_index` は added 時のみ増加、`sleep SLEEP_BETWEEN` は実 add 時のみ、終了コード、すべての `puts`/`warn` 文字列。

**検証**: 現 `feed.xml` をバックアップ。リファクタ前 `--dry-run > before.txt`、後 `--dry-run > after.txt` を `diff`。次に `--no-publish` ステージ実行し `diff feed.xml feed.xml.bak` が期待どおりの新規 item のみであること。

### Phase 5 — 仕上げ（約 1 時間）

- **README 修正**: 無音閾値 1秒 → 1.5秒（`SILENCE_DURATION_SEC = 1.5` に一致）。`silenceremove` の記述を atrim+afade+concat の説明に置換（`master_for_podcast.rb` 冒頭コメントが正確なテキスト）。
- **`--feed <path>` フラグ**（`publish_to_spotify.rb`）: `parse_cli_args` に追加し、デフォルトを CWD 相対 `'feed.xml'` から `File.join(__dir__, 'feed.xml')` へ。リポジトリ直下実行では同結果、別ディレクトリからの誤配置を防ぐ。README にも記載。
- クォートスタイルの正規化はファイルを触るついでに手作業で（専用パスは設けない）。

## 4. 変更しないもの

- **feed.xml の REXML シリアライズ挙動**（`append_item` / `write_feed`, `:305-347`）: 要素順の変更・フォーマッタ変更・Nokogiri への切り替えをしない。Phase 2 のゴールデンテストがトリップワイヤー。
- **nlm un-escape のセマンティクス**（`:203-265`）: Phase 3c で無編集移動し、決して「簡略化」しない。実在の nlm バグへの対応をエンコードしている（`\[` に `JSON.parse` が使えない理由はコード内の日本語コメントが説明）。
- **マスタリングのフィルタ文字列・数値・`%.6f` フォーマット・パラメータ順**: 音声出力の同一性が依存。テストで文字列ロック。
- **各スクリプトの CLI インターフェース/フラグ**、手書きの `parse_cli_args`（動作しており OptionParser への書き換えは不要）。
- gem 化・Thor/dry-cli・クラス階層・DI は導入しない。4 スクリプト + 共有 3 モジュールが適正サイズ。

## 5. 工数見積

| Phase | 内容 | 見積 |
| --- | --- | --- |
| 0 | ffmpeg 配列形式 + `require 'set'` | 30 分 |
| 1 | Gemfile / Rakefile /（CI） | 30〜45 分 |
| 2 | ユニットテスト + フィクスチャ（実 nlm 出力の採取含む） | 2〜3 時間 |
| 3 | lib/ 抽出（cli → ffmpeg → nlm） | 2〜3 時間 |
| 4 | `run_publish` 分解 | 1〜2 時間 |
| 5 | README / `--feed` フラグ | 1 時間 |

**合計: おおよそ 1〜1.5 日**。各フェーズは独立してコミット・検証可能。
