# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../master_for_podcast'

# Locks the audio-processing contract: the exact ffmpeg filtergraph strings and
# the silence/keep range math. If a refactor changes any of these, the produced
# audio changes — so these are intentionally strict string/array comparisons.
class MasterForPodcastTest < Minitest::Test
  FIXTURES = File.join(__dir__, 'fixtures')

  # ---- pure numeric helpers ----

  def test_db_to_linear
    assert_in_delta 0.316228, db_to_linear(-10), 1e-6
    assert_in_delta 1.0, db_to_linear(0), 1e-9
  end

  def test_acompressor_filter_string
    assert_equal(
      'acompressor=threshold=0.316228:ratio=10:attack=30:release=150:knee=5:makeup=1.000000',
      acompressor_filter
    )
  end

  # ---- silence / keep range math ----

  def test_silence_to_cut_ranges_drops_short_and_halves_kept
    periods = [[1.0, 3.0], [5.0, 5.4], [10.0, 12.0]]
    # 5.0..5.4 is <= truncate_to (1.0) so dropped; others keep 0.5s each side.
    assert_equal [[1.5, 2.5], [10.5, 11.5]], silence_to_cut_ranges(periods, 1.0)
  end

  def test_silence_to_cut_ranges_boundary_equal_is_dropped
    assert_equal [], silence_to_cut_ranges([[2.0, 3.0]], 1.0)
  end

  def test_keep_ranges_from_cuts_between_cuts
    assert_equal [[0.0, 1.5], [2.5, 10.5], [11.5, 20.0]],
                 keep_ranges_from_cuts([[1.5, 2.5], [10.5, 11.5]], 20.0)
  end

  def test_keep_ranges_from_cuts_cut_at_start
    assert_equal [[2.0, 10.0]], keep_ranges_from_cuts([[0.0, 2.0]], 10.0)
  end

  def test_keep_ranges_from_cuts_no_cuts
    assert_equal [[0.0, 10.0]], keep_ranges_from_cuts([], 10.0)
  end

  def test_keep_ranges_from_cuts_filters_sub_millisecond
    # The gap between the two cuts (1.0..1.0005) is < 0.001s, so it is discarded
    # and no keep range survives.
    assert_equal [], keep_ranges_from_cuts([[0.0, 1.0], [1.0005, 5.0]], 5.0)
  end

  # ---- filtergraph strings ----

  def test_keep_segment_filter_string
    assert_equal(
      '[0:a]atrim=start=0.000000:end=10.000000,asetpts=PTS-STARTPTS,' \
      'afade=t=in:st=0:d=0.005,afade=t=out:st=9.995000:d=0.005[trimmed]',
      keep_segment_filter('[0:a]', '[trimmed]', 0.0, 10.0)
    )
  end

  def test_build_keep_filter_graph_single_range
    assert_equal(
      '[0:a]atrim=start=0.000000:end=10.000000,asetpts=PTS-STARTPTS,' \
      'afade=t=in:st=0:d=0.005,afade=t=out:st=9.995000:d=0.005[trimmed]',
      build_keep_filter_graph([[0.0, 10.0]])
    )
  end

  def test_build_keep_filter_graph_three_ranges
    expected =
      '[0:a]asplit=3[s0][s1][s2];' \
      '[s0]atrim=start=0.000000:end=5.000000,asetpts=PTS-STARTPTS,' \
      'afade=t=in:st=0:d=0.005,afade=t=out:st=4.995000:d=0.005[a0];' \
      '[s1]atrim=start=6.000000:end=10.000000,asetpts=PTS-STARTPTS,' \
      'afade=t=in:st=0:d=0.005,afade=t=out:st=3.995000:d=0.005[a1];' \
      '[s2]atrim=start=11.000000:end=15.000000,asetpts=PTS-STARTPTS,' \
      'afade=t=in:st=0:d=0.005,afade=t=out:st=3.995000:d=0.005[a2];' \
      '[a0][a1][a2]concat=n=3:v=0:a=1[trimmed]'
    assert_equal expected, build_keep_filter_graph([[0.0, 5.0], [6.0, 10.0], [11.0, 15.0]])
  end

  def test_build_keep_filter_graph_empty_is_nil
    assert_nil build_keep_filter_graph([])
  end

  def test_filter_complex_without_keep_graph
    assert_equal(
      '[0:a]acompressor=threshold=0.316228:ratio=10:attack=30:release=150:knee=5:makeup=1.000000,LOUD[out]',
      filter_complex_for_processing(nil, 'LOUD')
    )
  end

  def test_filter_complex_with_keep_graph
    assert_equal(
      'KEEP;[trimmed]acompressor=threshold=0.316228:ratio=10:attack=30:release=150:knee=5:makeup=1.000000,LOUD[out]',
      filter_complex_for_processing('KEEP', 'LOUD')
    )
  end

  # ---- loudnorm JSON extraction ----

  def test_extract_loudnorm_json_from_noisy_stderr
    stderr = File.read(File.join(FIXTURES, 'loudnorm_stderr.txt'))
    json_str = extract_loudnorm_json(stderr)
    parsed = JSON.parse(json_str)
    assert_equal '-27.34', parsed['input_i']
    assert_equal '0.01', parsed['target_offset']
  end

  def test_extract_loudnorm_json_nil_when_no_json
    assert_nil extract_loudnorm_json('no json here')
  end

end
