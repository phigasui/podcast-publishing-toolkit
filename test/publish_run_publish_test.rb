# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'stringio'
require_relative '../publish_to_spotify'

# Characterization test for run_publish's orchestration: skip/fail precedence,
# counters, and next_index handling. The external I/O (R2, nlm, ffprobe) is
# stubbed by redefining those top-level methods in this dedicated test process,
# so the loop logic is exercised without network/CLI access. Run in --dry-run so
# no uploads or feed writes happen.

FEED_XML = <<~XML
  <?xml version="1.0" encoding="UTF-8"?>
  <rss version="2.0"><channel>
  <title>T</title><description>D</description><link>https://ex.com</link>
  <item><title>Existing</title><guid isPermaLink="false">ep_existing.mp3</guid></item>
  </channel></rss>
XML

# --- stubs for external effects (override the real top-level methods) ---
def fetch_current_feed(_config, local)
  File.write(local, FEED_XML)
end

def fetch_filename_to_notebook_id_map
  { 'ep_ok.mp3' => 'nb_ok', 'ep_nometa.mp3' => 'nb_nometa' }
end

def fetch_metadata_note_text(notebook_id)
  return "タイトル: 良いタイトル\n\n説明: 良い説明です。" if notebook_id == 'nb_ok'

  'garbage that will not parse'
end

def mp3_duration_seconds(_path)
  3661
end

class PublishRunPublishTest < Minitest::Test
  def test_dry_run_precedence_and_counts
    output = with_fixture_dir do |dir|
      config = {
        'r2' => { 'bucket' => 'b', 'account_id' => 'acc',
                  'public_base_url' => 'https://ex.com', 'key_prefix' => '' }
      }
      options = {
        dry_run: true, start_date: '2026-01-01T09:00:00+09:00', interval_days: 7,
        feed_path: File.join(dir, 'feed.xml')
      }
      capture_streams { run_publish(dir, config, options) }
    end

    # ep_existing.mp3 -> already in feed (skipped)
    # ep_nometa.mp3   -> notebook found but metadata unpardeable (failed)
    # ep_nonb.mp3     -> no notebook (failed)
    # ep_ok.mp3       -> added (dry-run)
    assert_includes output, 'Skipped (already in feed)'
    assert_includes output, 'No notebook found for this MP3'
    assert_includes output, "Could not parse"
    assert_includes output, '[dry-run] would upload MP3 and add item'
    assert_includes output, '良いタイトル'
    assert_includes output, 'Added: 1, Skipped: 1, Failed: 2, Total: 4'
    assert_includes output, '(dry-run: feed.xml not modified)'
  end

  private

  def with_fixture_dir
    Dir.mktmpdir do |dir|
      %w[ep_existing.mp3 ep_nometa.mp3 ep_nonb.mp3 ep_ok.mp3].each do |name|
        File.write(File.join(dir, name), 'x' * 1024)
      end
      # The feed path is passed explicitly via options[:feed_path] (--feed).
      yield dir
    end
  end

  def capture_streams
    orig_out = $stdout
    orig_err = $stderr
    buf = StringIO.new
    $stdout = buf
    $stderr = buf
    yield
    buf.string
  ensure
    $stdout = orig_out
    $stderr = orig_err
  end
end
