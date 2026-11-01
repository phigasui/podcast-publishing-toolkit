# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'stringio'
require_relative '../generate_episode_metadata'

# The retry loop sleeps between attempts; keep this test process fast.
def sleep(*) = nil

class GenerateEpisodeMetadataTest < Minitest::Test
  Agy = PodcastToolkit::Agy
  OK = { 'title' => 'T', 'description' => 'D', 'cut_requests' => [] }.freeze

  def setup
    @calls = []
    @original = Agy.method(:generate)
  end

  def teardown
    Agy.define_singleton_method(:generate, @original)
  end

  # results: one [metadata, error] per call, the last one repeated
  def fake_generate(*results)
    calls = @calls
    Agy.define_singleton_method(:generate) do |mp3, **|
      calls << File.basename(mp3)
      results[[calls.size - 1, results.size - 1].min]
    end
  end

  # Minitest::Test#run shadows the script's top-level run, so call it on main.
  def run_script(files, force:)
    TOPLEVEL_BINDING.receiver.send(:run, files, model: 'm', force: force)
  end

  def test_parse_args
    assert_equal({ force: true, model: 'm', mp3_dir: 'dir' }, parse_args(%w[--force --model m dir]))
    assert_equal Agy::DEFAULT_MODEL, parse_args(%w[dir])[:model]
  end

  def test_skips_valid_json_regenerates_broken_and_counts_failures
    Dir.mktmpdir do |dir|
      %w[a.mp3 b.MP3 c.mp3].each { |n| File.write(File.join(dir, n), 'x') }
      File.write(File.join(dir, 'a.meta.json'), JSON.generate(OK))
      File.write(File.join(dir, 'b.meta.json'), '{ broken')
      fake_generate([OK.dup, nil], [nil, 'boom'])

      files = Agy.mp3_files(dir)
      counts = nil
      out = capture_io { counts = run_script(files, force: false) }.join

      assert_equal %w[a.mp3 b.MP3 c.mp3], files.map { |f| File.basename(f) }
      assert_equal({ generated: 1, skipped: 1, failed: 1 }, counts)
      assert_equal %w[b.MP3 c.mp3 c.mp3 c.mp3], @calls # c retried MAX_ATTEMPTS times
      assert_includes out, 'unreadable or empty; regenerating'
      assert_equal 'T', JSON.parse(File.read(File.join(dir, 'b.meta.json')))['title']
      refute File.exist?(File.join(dir, 'c.meta.json'))
      refute File.exist?(File.join(dir, 'b.meta.json.tmp'))
    end
  end

  def test_force_regenerates_existing
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'a.mp3'), 'x')
      File.write(File.join(dir, 'a.meta.json'), JSON.generate(OK))
      fake_generate([OK.merge('title' => 'New'), nil])
      capture_io { run_script(Agy.mp3_files(dir), force: true) }

      assert_equal 'New', JSON.parse(File.read(File.join(dir, 'a.meta.json')))['title']
    end
  end
end
