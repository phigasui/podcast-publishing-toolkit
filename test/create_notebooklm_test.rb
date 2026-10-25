# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../create_notebooklm_notebooks'

class CreateNotebooklmTest < Minitest::Test
  # extract_answer / thinking_frame? now live in PodcastToolkit::Nlm; see
  # podcast_toolkit_nlm_test.rb. This file covers create-specific parsing.
  def test_extract_notebook_id_parses_id_token
    assert_equal 'abc123', extract_notebook_id("Created notebook\nID: abc123\n")
  end

  def test_extract_notebook_id_nil_when_absent
    assert_nil extract_notebook_id('no id here')
  end
end
