# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/podcast_toolkit/nlm'

class PodcastToolkitNlmTest < Minitest::Test
  Nlm = PodcastToolkit::Nlm

  def test_podcast_note_title_constant
    assert_equal 'Podcast 公開用メタデータ', Nlm::PODCAST_NOTE_TITLE
  end

  # ---- answer extraction ----

  def test_extract_answer_from_value_answer
    assert_equal 'the body', Nlm.extract_answer(+'{"value":{"answer":"the body"}}')
  end

  def test_extract_answer_from_flat_answer
    assert_equal 'flat body', Nlm.extract_answer(+'{"answer":"flat body"}')
  end

  def test_extract_answer_strips_surrounding_whitespace
    assert_equal 'padded', Nlm.extract_answer(+'{"value":{"answer":"  padded  "}}')
  end

  def test_extract_answer_invalid_json_falls_back_to_raw
    assert_equal 'not json at all', Nlm.extract_answer(+'  not json at all  ')
  end

  def test_extract_answer_missing_answer_returns_empty
    assert_equal '', Nlm.extract_answer(+'{"value":{"other":1}}')
  end

  # ---- thinking frame detection ----

  def test_thinking_frame_true_for_bold_prefix
    assert Nlm.thinking_frame?('**Title** some draft')
  end

  def test_thinking_frame_false_for_plain_text
    refute Nlm.thinking_frame?('タイトル: 本編')
  end

  # ---- escape normalization (the fragile parsing contract) ----

  def test_unescape_once_handles_newline_and_brackets
    assert_equal "a\nb", Nlm.unescape_once('a\\nb')
    assert_equal 'x[1]y', Nlm.unescape_once('x\\[1\\]y')
  end

  def test_unescape_once_handles_tab_return_quote_backslash
    assert_equal "\t\r\"\\", Nlm.unescape_once('\\t\\r\\"\\\\')
  end

  def test_normalize_literal_escapes_single_level
    assert_equal "line1\nline2", Nlm.normalize_literal_escapes('line1\\nline2')
  end

  def test_normalize_literal_escapes_illegal_json_brackets
    # nlm returns "sources_used": \[1\] which JSON.parse can't handle.
    assert_equal 'brackets [1]', Nlm.normalize_literal_escapes('brackets \\[1\\]')
  end

  def test_normalize_literal_escapes_multi_level
    # Double-escaped newline should collapse to a real newline within 5 passes.
    assert_equal "a\nb", Nlm.normalize_literal_escapes('a\\\\nb')
  end

  def test_normalize_literal_escapes_is_idempotent_on_clean_text
    clean = "already clean\nno escapes"
    assert_equal clean, Nlm.normalize_literal_escapes(clean)
  end

  def test_normalize_literal_escapes_passes_through_non_string
    assert_nil Nlm.normalize_literal_escapes(nil)
    assert_equal 42, Nlm.normalize_literal_escapes(42)
  end
end
