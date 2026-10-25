# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/podcast_toolkit/cli'

class PodcastToolkitCLITest < Minitest::Test
  def test_output_path_for_swaps_extension
    assert_equal '/out/video.mp3',
                 PodcastToolkit::CLI.output_path_for('/in/video.mp4', '/out')
  end

  def test_output_path_for_keeps_tricky_basename
    assert_equal '/out/He said hi 12:30.mp3',
                 PodcastToolkit::CLI.output_path_for('/in/He said hi 12:30.mkv', '/out')
  end

  def test_output_path_for_strips_only_last_extension
    assert_equal '/out/2026.01.02.mp3',
                 PodcastToolkit::CLI.output_path_for('/in/2026.01.02.mp4', '/out')
  end

  def test_output_path_for_custom_extension
    assert_equal '/out/clip.wav',
                 PodcastToolkit::CLI.output_path_for('/in/clip.mp4', '/out', ext: '.wav')
  end
end
