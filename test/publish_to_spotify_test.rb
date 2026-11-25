# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'time'
require 'stringio'
require_relative '../publish_to_spotify'

class PublishToSpotifyTest < Minitest::Test
  FIXTURES = File.join(__dir__, 'fixtures')

  # nlm escape normalization now lives in PodcastToolkit::Nlm; see
  # podcast_toolkit_nlm_test.rb for its contract tests.

  # ---- citation stripping & metadata parsing ----

  def test_strip_citations_removes_various_markers
    assert_equal 'Hello world end.', strip_citations('Hello [1] world [2, 3] end [4-6].')
  end

  def test_parse_metadata_happy_path
    result = parse_metadata("タイトル: My Title\n\n説明: A description here.")
    assert_equal 'My Title', result[:title]
    assert_equal 'A description here.', result[:description]
  end

  def test_parse_metadata_fullwidth_colon_and_citations
    result = parse_metadata("タイトル：全角 [1]\n\n説明：本文です。")
    assert_equal '全角', result[:title]
    assert_equal '本文です。', result[:description]
  end

  def test_parse_metadata_returns_nil_for_bad_format
    assert_nil parse_metadata('no recognizable format')
  end

  def test_parse_metadata_returns_nil_for_nil
    assert_nil parse_metadata(nil)
  end

  # ---- local_feed_path resolution ----

  def test_local_feed_path_prefers_cli_options
    opts = { feed_path: '/custom/path/feed.xml' }
    cfg = { 'feed_path' => '../other/feed.xml' }
    assert_equal '/custom/path/feed.xml', local_feed_path(opts, cfg)
  end

  def test_local_feed_path_falls_back_to_config
    opts = {}
    cfg = { 'feed_path' => 'relative/feed.xml' }
    expected = File.expand_path('relative/feed.xml', File.expand_path('..', __dir__))
    assert_equal expected, local_feed_path(opts, cfg)
  end

  def test_local_feed_path_resolves_existing_parent_relative_path
    Dir.mktmpdir do |dir|
      # dir/repo/script.rb から見て ../neighbor/feed.xml が実際は ../../neighbor/feed.xml にある場合
      repo_dir = File.join(dir, 'sub', 'repo')
      neighbor_dir = File.join(dir, 'neighbor')
      FileUtils.mkdir_p(repo_dir)
      FileUtils.mkdir_p(neighbor_dir)
      target_file = File.join(neighbor_dir, 'feed.xml')
      File.write(target_file, '<xml/>')

      # repo_dir 基準で ../neighbor/feed.xml は存在しないが、../../neighbor/feed.xml は存在するケース
      opts = {}
      cfg = { 'feed_path' => '../neighbor/feed.xml' }

      resolved = local_feed_path(opts, cfg, base_dir: repo_dir)
      assert_equal target_file, resolved
    end
  end

  def test_local_feed_path_empty_string_falls_back_to_default
    opts = {}
    cfg = { 'feed_path' => '' }
    expected = File.join(File.expand_path('..', __dir__), DEFAULT_LOCAL_FEED_PATH)
    assert_equal expected, local_feed_path(opts, cfg)
  end

  def test_local_feed_path_defaults_to_local_feed_xml
    opts = {}
    cfg = {}
    expected = File.join(File.expand_path('..', __dir__), DEFAULT_LOCAL_FEED_PATH)
    assert_equal expected, local_feed_path(opts, cfg)
    assert_equal expected, local_feed_path(opts)
  end

  # ---- duration & schedule ----

  def test_format_duration
    assert_equal '01:01:01', format_duration(3661)
    assert_equal '00:00:59', format_duration(59)
    assert_equal '00:00:00', format_duration(0)
  end

  def test_compute_pub_date_index_zero
    assert_equal 'Thu, 01 Jan 2026 09:00:00 +0900',
                 compute_pub_date('2026-01-01T09:00:00+09:00', 7, 0).rfc2822
  end

  def test_compute_pub_date_advances_by_interval
    assert_equal 'Thu, 15 Jan 2026 09:00:00 +0900',
                 compute_pub_date('2026-01-01T09:00:00+09:00', 7, 2).rfc2822
  end

  def test_clamp_start_date_keeps_future_start
    latest = Time.parse('2026-01-01T09:00:00+09:00')
    assert_equal '2026-02-01T09:00:00+09:00', clamp_start_date('2026-02-01T09:00:00+09:00', 7, latest)
    assert_equal '2026-02-01T09:00:00+09:00', clamp_start_date('2026-02-01T09:00:00+09:00', 7, nil)
  end

  def test_clamp_start_date_moves_past_start_after_latest
    latest = Time.parse('2026-01-01T09:00:00+09:00')
    assert_equal Time.parse('2026-01-08T09:00:00+09:00'),
                 Time.parse(clamp_start_date('2025-12-01T09:00:00+09:00', 7, latest))
    # 同時刻も重複なので繰り上げ
    assert_equal Time.parse('2026-01-08T09:00:00+09:00'),
                 Time.parse(clamp_start_date('2026-01-01T09:00:00+09:00', 7, latest))
  end

  # ---- 収録日ルール (収録日 + 7 日の次の火曜 07:00 JST) ----

  def rec(date_time)
    "カタルシス - #{date_time} JST～Recording.mp3"
  end

  def test_recording_time_from_filename
    assert_equal Time.parse('2025-06-07T21:30:00+09:00'), recording_time_from_filename(rec('2025 06 07 21:30'))
    assert_nil recording_time_from_filename('no-date.mp3')
    assert_nil recording_time_from_filename(rec('2025 13 45 99:99'))
    assert_nil recording_time_from_filename(rec('2025 02 31 21:30'))
  end

  # bytecafe-fm/feed#3 の既存 7 話 (#1..#7) の期待値
  FEED3_EXPECTED = {
    '2025 06 07 21:30' => 'Tue, 17 Jun 2025 07:00:00 +0900', # 土 → +7 土 → 火
    '2025 05 31 21:30' => 'Tue, 10 Jun 2025 07:00:00 +0900',
    '2025 05 24 21:30' => 'Tue, 03 Jun 2025 07:00:00 +0900',
    '2025 05 10 21:30' => 'Tue, 20 May 2025 07:00:00 +0900',
    '2025 04 26 21:30' => 'Tue, 06 May 2025 07:00:00 +0900',
    '2025 04 20 21:30' => 'Tue, 29 Apr 2025 07:00:00 +0900', # 日 → +7 日 → 火
    '2025 03 29 21:30' => 'Tue, 08 Apr 2025 07:00:00 +0900'
  }.freeze

  def test_rule_pub_date_matches_feed3_expectations
    FEED3_EXPECTED.each do |recorded, expected|
      t = recording_time_from_filename(rec(recorded))
      assert_equal expected, rule_pub_date(t).rfc2822, recorded
    end
  end

  def test_rule_pub_date_is_strictly_after_when_plus7_is_the_weekday
    # 火曜収録 → +7 日も火曜 → 「その日より後」なので翌週火曜
    t = Time.parse('2025-06-03T21:30:00+09:00')
    assert_equal 'Tue, 17 Jun 2025 07:00:00 +0900', rule_pub_date(t).rfc2822
  end

  def test_rule_pub_date_uses_jst_date_for_utc_input
    # UTC 2025-06-07 20:00 は JST 06-08 05:00 (日) → +7 日 06-15(日) → 06-17
    assert_equal 'Tue, 17 Jun 2025 07:00:00 +0900', rule_pub_date(Time.utc(2025, 6, 7, 20, 0)).rfc2822
  end

  def test_build_publish_rule_overrides
    rule = build_publish_rule({ 'schedule' => { 'publish_rule' => { 'offset_days' => 3, 'weekday' => 'fri', 'time' => '08:30' } } }, {})
    assert_equal({ offset_days: 3, weekday: 5, hour: 8, min: 30 }, rule)
    assert_equal 7, build_publish_rule({}, {})[:offset_days]
    assert_equal 1, build_publish_rule({}, { weekday: 'Mon' })[:weekday]
    assert_raises(ArgumentError) { build_publish_rule({}, { weekday: 'xyz' }) }
    assert_raises(ArgumentError) { build_publish_rule({}, { publish_time: '7am' }) }
    assert_raises(ArgumentError) { build_publish_rule({}, { publish_time: '25:00' }) }
    assert_raises(ArgumentError) { build_publish_rule({}, { offset_days: '-1' }) }
  end

  def test_decide_pub_date_sources
    rule = build_publish_rule({}, {})
    base = { start_date: '2026-01-01T09:00:00+09:00', interval_days: 7, rule: rule, explicit_start: false }
    t, src = decide_pub_date(rec('2025 06 07 21:30'), base, 3)
    assert_equal [:rule, 'Tue, 17 Jun 2025 07:00:00 +0900'], [src, t.rfc2822]
    t, src = decide_pub_date('nodate.mp3', base, 2)
    assert_equal [:legacy, 'Thu, 15 Jan 2026 09:00:00 +0900'], [src, t.rfc2822]
    assert_equal [nil, nil], decide_pub_date('nodate.mp3', base.merge(start_date: nil), 0)
    t, src = decide_pub_date(rec('2025 06 07 21:30'), base.merge(explicit_start: true), 1)
    assert_equal [:explicit, 'Thu, 08 Jan 2026 09:00:00 +0900'], [src, t.rfc2822]
  end

  def test_warn_pub_date_conflicts_warns_but_keeps_date
    feed = { latest_pub_date: Time.parse('2025-06-17T07:00:00+09:00') }
    episode = { pub_date: Time.parse('2025-06-17T07:00:00+09:00'), pub_date_source: :rule }
    _out, err = capture_io { warn_pub_date_conflicts(episode, feed) }
    assert_match(/既存 feed の最新/, err)
    assert_equal Time.parse('2025-06-17T07:00:00+09:00'), episode[:pub_date]
    later = { pub_date: Time.parse('2025-06-24T07:00:00+09:00'), pub_date_source: :rule }
    _out, err = capture_io { warn_pub_date_conflicts(later, feed) }
    assert_equal '', err
    assert_equal later[:pub_date], feed[:latest_pub_date]
  end

  def test_latest_pub_date_picks_max
    doc = REXML::Document.new('<rss><channel><item><pubDate>Thu, 01 Jan 2026 09:00:00 +0900</pubDate></item>' \
                              '<item><pubDate>Thu, 15 Jan 2026 09:00:00 +0900</pubDate></item>' \
                              '<item><pubDate>Mon, 05 Jan 2026 09:00:00 +0900</pubDate></item></channel></rss>')
    assert_equal Time.parse('2026-01-15T09:00:00+09:00'), latest_pub_date(doc)
  end

  # ---- R2 key / URL construction ----

  def test_r2_key_with_prefix
    cfg = { 'r2' => { 'key_prefix' => 'pod/' } }
    assert_equal 'pod/a b.mp3', r2_key(cfg, 'a b.mp3')
  end

  def test_r2_key_without_prefix
    assert_equal 'a b.mp3', r2_key({ 'r2' => {} }, 'a b.mp3')
  end

  def test_r2_public_url_encodes_and_joins
    cfg = { 'r2' => { 'key_prefix' => 'pod/', 'public_base_url' => 'https://ex.com/' } }
    assert_equal 'https://ex.com/pod/a%20b.mp3', r2_public_url(cfg, 'a b.mp3')
  end

  def test_r2_public_url_without_prefix
    cfg = { 'r2' => { 'public_base_url' => 'https://ex.com' } }
    assert_equal 'https://ex.com/a%20b.mp3', r2_public_url(cfg, 'a b.mp3')
  end

  # ---- feed golden test (locks REXML serialization) ----

  def test_append_item_matches_golden_serialization
    doc = load_feed(File.join(FIXTURES, 'feed_min.xml'))
    ensure_itunes_namespace(doc)

    assert_equal ['existing.mp3'], existing_guids(doc).to_a

    pub = Time.parse('2026-02-01T09:00:00+09:00')
    append_item(
      doc,
      title: 'New & Shiny <Episode>',
      description: "Line one\nLine two with [brackets]",
      pub_date: pub,
      guid: 'new episode.mp3',
      mp3_url: 'https://ex.com/new%20episode.mp3',
      mp3_size: 12_345,
      duration_sec: 3661.7
    )

    actual = Dir.mktmpdir do |dir|
      out = File.join(dir, 'feed.xml')
      write_feed(doc, out)
      File.read(out)
    end

    expected = File.read(File.join(FIXTURES, 'feed_after_append.xml'))
    assert_equal expected, actual
  end

  def test_ensure_itunes_namespace_is_idempotent
    doc = load_feed(File.join(FIXTURES, 'feed_min.xml'))
    ensure_itunes_namespace(doc)
    ensure_itunes_namespace(doc)
    assert_equal ITUNES_NS, doc.root.namespaces['itunes']
  end

  # ---- build_episode (pure episode assembly) ----

  def test_build_episode_resolves_all_fields
    Dir.mktmpdir do |dir|
      mp3 = File.join(dir, 'ep.mp3')
      File.write(mp3, 'x' * 2048)
      config = { 'r2' => { 'key_prefix' => 'pod/', 'public_base_url' => 'https://ex.com' } }
      schedule = { start_date: '2026-01-01T09:00:00+09:00', interval_days: 7 }
      metadata = { title: 'T', description: 'D' }

      episode = build_episode(mp3, 'ep name.mp3', metadata, 3661, schedule, 1, config)

      assert_equal 'T', episode[:title]
      assert_equal 'D', episode[:description]
      assert_equal 'ep name.mp3', episode[:guid]
      assert_equal 'pod/ep name.mp3', episode[:mp3_key]
      assert_equal 'https://ex.com/pod/ep%20name.mp3', episode[:mp3_url]
      assert_equal 2048, episode[:mp3_size]
      assert_equal 3661, episode[:duration_sec]
      # index 1 with a 7-day interval advances one week from the start date.
      assert_equal 'Thu, 08 Jan 2026 09:00:00 +0900', episode[:pub_date].rfc2822
    end
  end
end
