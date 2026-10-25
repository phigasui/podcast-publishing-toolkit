# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../master_for_podcast'

class TestMasterForPodcast < Minitest::Test
  def test_safe_utf8_with_valid_and_frozen_strings
    assert_equal '', safe_utf8(nil)
    assert_equal '', safe_utf8('')
    assert_equal 'hello', safe_utf8('hello')

    frozen_japanese = '録音：打ち合わせ〜テスト'.freeze
    result = safe_utf8(frozen_japanese)
    assert_equal Encoding::UTF_8, result.encoding
    assert result.valid_encoding?
    assert_equal '録音：打ち合わせ〜テスト', result
  end

  def test_safe_utf8_with_us_ascii_containing_multibyte_characters
    raw_bytes = '録音：打ち合わせ〜2026-10-25.webm'.b
    us_ascii_str = raw_bytes.force_encoding(Encoding::US_ASCII)

    refute us_ascii_str.valid_encoding?
    assert_raises(ArgumentError) { us_ascii_str.scan(/打ち合わせ/) }

    safe_str = safe_utf8(us_ascii_str)
    assert_equal Encoding::UTF_8, safe_str.encoding
    assert safe_str.valid_encoding?
    assert_equal '録音：打ち合わせ〜2026-10-25.webm', safe_str
    assert_equal [['打ち合わせ']], safe_str.scan(/(打ち合わせ)/)
  end

  def test_safe_utf8_with_invalid_byte_sequences
    broken = "\xFF\xFE\xFD".b.force_encoding(Encoding::UTF_8)
    refute broken.valid_encoding?

    cleaned = safe_utf8(broken)
    assert_equal Encoding::UTF_8, cleaned.encoding
    assert cleaned.valid_encoding?
  end

  def test_parse_silence_output_with_multibyte_filename_and_us_ascii_encoding
    ffmpeg_stderr = <<~STDERR
      [matroska,webm @ 0x12345678] Format matroska,webm probed
      Input #0, matroska,webm, from '録音：定例ミーティング〜第1回.webm':
        Duration: 00:00:10.50, start: 0.000000, bitrate: 128 kb/s
      [silencedetect @ 0x87654321] silence_start: 1.5
      [silencedetect @ 0x87654321] silence_end: 3.8 | silence_duration: 2.3
      [silencedetect @ 0x87654321] silence_start: 7.2
      [silencedetect @ 0x87654321] silence_end: 9.0 | silence_duration: 1.8
    STDERR

    # Simulate US-ASCII stream from pipe under LC_ALL=C
    us_ascii_stderr = ffmpeg_stderr.b.force_encoding(Encoding::US_ASCII)
    refute us_ascii_stderr.valid_encoding?

    # Without safe_utf8, scanning us_ascii_stderr would raise ArgumentError / CompatibilityError
    periods = parse_silence_output(us_ascii_stderr)
    assert_equal [[1.5, 3.8], [7.2, 9.0]], periods
  end

  def test_safe_capture3_returns_utf8
    stdout, stderr, status = safe_capture3('printf', '%s', '録音：〜テスト')
    assert status.success?
    assert_equal Encoding::UTF_8, stdout.encoding
    assert stdout.valid_encoding?
    assert_equal '録音：〜テスト', stdout
    assert_equal Encoding::UTF_8, stderr.encoding
  end

  def test_extract_loudnorm_json_with_multibyte_filename_and_us_ascii_encoding
    ffmpeg_stderr = <<~STDERR
      Input #0, mp3, from '録音：テスト〜音源.mp3':
      [Parsed_loudnorm_0 @ 0x123] [loudnorm @ 0x456]
      {
        "input_i" : "-24.50",
        "input_tp" : "-1.20",
        "input_lra" : "5.40",
        "input_thresh" : "-35.10",
        "target_offset" : "+1.50"
      }
    STDERR

    us_ascii_stderr = ffmpeg_stderr.b.force_encoding(Encoding::US_ASCII)
    json_str = extract_loudnorm_json(us_ascii_stderr)
    refute_nil json_str
    parsed = JSON.parse(json_str)
    assert_equal '-24.50', parsed['input_i']
    assert_equal '+1.50', parsed['target_offset']
  end

  def with_stubbed_open3(stdout, stderr, status)
    orig = Open3.method(:capture3)
    Open3.singleton_class.send(:define_method, :capture3) do |*args, **kwargs|
      [stdout, stderr, status]
    end
    yield
  ensure
    Open3.singleton_class.send(:define_method, :capture3, orig)
  end

  def test_detect_silence_periods_with_mocked_us_ascii_stderr
    simulated_stderr = <<~STDERR.b.force_encoding(Encoding::US_ASCII)
      Input #0, matroska,webm, from '録音：テスト〜.webm':
      [silencedetect @ 0x123] silence_start: 0.5
      [silencedetect @ 0x123] silence_end: 2.0 | silence_duration: 1.5
    STDERR

    fake_status = Struct.new(:success?).new(true)
    with_stubbed_open3('', simulated_stderr, fake_status) do
      periods = detect_silence_periods('録音：テスト〜.webm')
      assert_equal [[0.5, 2.0]], periods
    end
  end

  def test_real_ffmpeg_execution_with_multibyte_filename
    system('which ffmpeg > /dev/null 2>&1')
    return unless $CHILD_STATUS&.success? || $?.success?

    tmp_dir = Dir.mktmpdir('podcast_test_')
    begin
      multibyte_file = File.join(tmp_dir, '録音：打ち合わせ〜テスト.mp3')
      # Create a 2.5s silent audio file with a fullwidth tilde and colon in filename
      gen_cmd = [
        'ffmpeg', '-v', 'error',
        '-f', 'lavfi', '-i', 'anullsrc=r=44100:cl=mono',
        '-t', '2.5',
        '-y', multibyte_file
      ]
      system(*gen_cmd)
      assert File.exist?(multibyte_file)

      duration = PodcastToolkit::FFmpeg.audio_duration(multibyte_file)
      refute_nil duration
      assert_in_delta 2.5, duration, 0.2

      # Run detect_silence_periods on the real multibyte file
      periods = detect_silence_periods(multibyte_file)
      refute_nil periods
      # Because whole file is silence (2.5s >= 1.5s threshold), it should detect silence
      assert_equal 1, periods.size
      assert_in_delta 0.0, periods[0][0], 0.1
    ensure
      FileUtils.remove_entry(tmp_dir) if File.exist?(tmp_dir)
    end
  end
end
