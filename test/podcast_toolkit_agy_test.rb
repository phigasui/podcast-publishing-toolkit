# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/podcast_toolkit/agy'

class PodcastToolkitAgyTest < Minitest::Test
  Agy = PodcastToolkit::Agy

  def agy_output(structured, status: 'SUCCESS', denied: nil)
    h = { 'status' => status, 'response' => '' }
    h['structured_output'] = structured if structured
    h['denied_actions'] = denied if denied
    JSON.generate(h)
  end

  # minitest 6 no longer bundles minitest/mock, so swap Open3.capture3 by hand.
  def with_capture3(fake)
    original = Open3.method(:capture3)
    Open3.define_singleton_method(:capture3) { |*args, **kw| fake.call(*args, **kw) }
    yield
  ensure
    Open3.define_singleton_method(:capture3, original)
  end

  def test_metadata_path_replaces_extension
    assert_equal '/a/ep 01.meta.json', Agy.metadata_path('/a/ep 01.mp3')
    assert_equal '/a/EP.meta.json', Agy.metadata_path('/a/EP.MP3')
  end

  def test_parse_result_success_normalizes_fields
    out = agy_output({ 'title' => ' タイトル ', 'description' => "説明\n2 行目",
                       'cut_requests' => [{ 'timestamp' => '00:07', 'quote' => 'カットして' }, 'junk'] })
    metadata, error = Agy.parse_result(out)

    assert_nil error
    assert_equal 'タイトル', metadata['title']
    assert_equal "説明\n2 行目", metadata['description']
    assert_equal [{ 'timestamp' => '00:07', 'quote' => 'カットして' }], metadata['cut_requests']
  end

  def test_parse_result_rejects_empty_title
    _, error = Agy.parse_result(agy_output({ 'title' => '', 'description' => 'x', 'cut_requests' => [] }))
    assert_match(/empty title/, error)
  end

  def test_parse_result_reports_denied_actions
    _, error = Agy.parse_result(agy_output(nil, denied: [{ 'action' => 'command', 'display_name' => 'RunCommand' }]))
    assert_equal 'no structured_output (denied: RunCommand)', error
  end

  def test_parse_result_non_success_and_garbage
    assert_equal 'agy status ERROR', Agy.parse_result(agy_output(nil, status: 'ERROR')).last
    assert_match(/could not parse/, Agy.parse_result('not json').last)
    assert_match(/unexpected agy output/, Agy.parse_result('null').last)
    assert_match(/unexpected agy output/, Agy.parse_result('[]').last)
    assert_equal 'no structured_output (denied: x)', Agy.parse_result(agy_output(nil, denied: ['x'])).last
  end

  def test_write_then_load_round_trip
    Dir.mktmpdir do |dir|
      mp3 = File.join(dir, 'ep.mp3')
      Agy.write_metadata(mp3, { 'title' => 'T', 'description' => 'D', 'cut_requests' => [] }, model: 'm')
      saved = JSON.parse(File.read(File.join(dir, 'ep.meta.json')))

      assert_equal 'ep.mp3', saved['source']
      assert_equal 'm', saved['model']
      assert_equal({ title: 'T', description: 'D' }, Agy.load_metadata(mp3))
    end
  end

  def test_load_metadata_nil_for_missing_broken_or_empty
    Dir.mktmpdir do |dir|
      mp3 = File.join(dir, 'ep.mp3')
      assert_nil Agy.load_metadata(mp3)
      File.write(Agy.metadata_path(mp3), '{ broken')
      assert_nil Agy.load_metadata(mp3)
      File.write(Agy.metadata_path(mp3), JSON.generate('title' => 'T', 'description' => ' '))
      assert_nil Agy.load_metadata(mp3)
    end
  end

  OK = Struct.new(:success?, :exitstatus).new(true, 0)
  NG = Struct.new(:success?, :exitstatus).new(false, 2)

  # Downsamples with ffmpeg into a temp dir, then runs agy there on the copy.
  def test_generate_downsamples_then_runs_agy_on_the_copy
    calls = []
    fake = lambda do |*cmd, **opts|
      if cmd.first == 'ffmpeg'
        calls << [cmd, opts]
        File.write(cmd.last, 'mp3')
        next ['', '', OK]
      end
      dir = opts[:chdir]
      calls << [cmd, opts, JSON.parse(File.read(cmd[cmd.index('--json-schema') + 1])),
                File.exist?(File.join(dir, 'ep 1.mp3'))]
      [agy_output({ 'title' => 'T', 'description' => 'D', 'cut_requests' => [] }), '', OK]
    end

    metadata = with_capture3(fake) { Agy.generate('/tmp/x/ep 1.mp3', model: 'mdl', timeout: 60) }.first
    (ffmpeg, _), (cmd, opts, schema, copied) = calls

    assert_equal 'T', metadata['title']
    assert_equal '/tmp/x/ep 1.mp3', ffmpeg[ffmpeg.index('-i') + 1]
    assert_equal File.join(opts[:chdir], 'ep 1.mp3'), ffmpeg.last
    assert copied, 'agy runs where the downsampled copy is'
    refute Dir.exist?(opts[:chdir]), 'temp dir is removed afterwards'
    assert_equal %w[agy -p], cmd.first(2)
    assert_includes cmd[2], 'ep 1.mp3'
    assert_equal 'mdl', cmd[cmd.index('--model') + 1]
    assert_equal '60s', cmd[cmd.index('--print-timeout') + 1]
    assert_equal %w[title description cut_requests], schema['required']
  end

  def test_generate_reports_ffmpeg_failure_without_running_agy
    cmds = []
    fake = lambda { |*cmd, **|
      cmds << cmd
      ['', 'bad input', NG]
    }
    error = with_capture3(fake) { Agy.generate('/tmp/ep.mp3') }.last
    assert_equal 'ffmpeg exited 2: bad input', error
    assert_equal ['ffmpeg'], cmds.map(&:first)
    refute Dir.exist?(File.dirname(cmds.first.last)), 'temp dir is removed after an early return'
  end

  def test_generate_reports_nonzero_agy_exit
    fake = ->(*cmd, **) { cmd.first == 'ffmpeg' ? ['', '', OK] : ['', 'boom', NG] }
    error = with_capture3(fake) { Agy.generate('/tmp/ep.mp3') }.last
    assert_equal 'agy exited 2: boom', error
  end

  def test_generate_reports_missing_commands
    missing_ffmpeg = ->(*, **) { raise Errno::ENOENT, 'ffmpeg' }
    assert_match(/could not run command: .*ffmpeg/, with_capture3(missing_ffmpeg) { Agy.generate('/tmp/ep.mp3') }.last)

    missing_agy = ->(*cmd, **) { cmd.first == 'ffmpeg' ? ['', '', OK] : raise(Errno::ENOENT, 'agy') }
    assert_match(/could not run command: .*agy/, with_capture3(missing_agy) { Agy.generate('/tmp/ep.mp3') }.last)
  end
end
