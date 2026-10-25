# frozen_string_literal: true

require 'minitest/autorun'
require 'stringio'

# Loadable as a library: the script guards main with __FILE__ == $PROGRAM_NAME.
require_relative '../convert_meet_recordings'

class ConvertMeetRecordingsTest < Minitest::Test
  # Output-path construction now lives in PodcastToolkit::CLI (see
  # podcast_toolkit_cli_test.rb). This file covers convert-specific logic.
  def test_skip_chat_file_true_for_chat
    silence_stdout { assert skip_chat_file?('Meeting Chat.txt') }
  end

  def test_skip_chat_file_false_otherwise
    refute skip_chat_file?('Recording.mp4')
  end

  private

  def silence_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = original
  end
end
