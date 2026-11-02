# frozen_string_literal: true

require 'json'
require 'open3'
require 'uri'

module PodcastToolkit
  # Helpers for parsing NotebookLM (`nlm` CLI) responses. The response-cleanup
  # functions here encode observed real-world `nlm` output quirks (multiply
  # escaped newlines, illegal JSON escapes like \[ \]); they are covered by
  # unit tests and should not be "simplified" without updating those fixtures.
  module Nlm
    # Title of the note that create_notebooklm_notebooks.rb generates and
    # publish_to_spotify.rb reads back for episode metadata. Single source of
    # truth shared by both scripts.
    PODCAST_NOTE_TITLE = 'Podcast 公開用メタデータ'

    module_function

    # Decoded titles of the audio sources in a notebook (`nlm source list`).
    # Shared by create_notebooklm_notebooks.rb and publish_to_spotify.rb so both
    # derive the "filename -> notebook" mapping the same way. Returns nil when
    # the nlm call fails. `runner` is injectable for tests; it must return
    # [stdout, stderr, status] like Open3.capture3.
    def audio_source_filenames(notebook_id, runner: Open3.method(:capture3))
      stdout, _stderr, status = runner.call('nlm', 'source', 'list', notebook_id, '--json')
      return nil unless status.success?

      parsed = JSON.parse(stdout.dup.force_encoding('UTF-8'))
      return nil unless parsed.is_a?(Array) # unexpected shape: treat as failure

      parsed
        .select { |src| src.is_a?(Hash) && src['type'] == 'audio' }
        .map { |src| URI.decode_www_form_component(src['title']) }
    end

    # nlm query returns {"value":{"answer":"..."}}; the body is value.answer.
    # Falls back to the raw (stripped) stdout when the output is not JSON.
    def extract_answer(stdout)
      parsed = JSON.parse(stdout.force_encoding('UTF-8'))
      answer = parsed.dig('value', 'answer') || parsed['answer']
      (answer || '').strip
    rescue JSON::ParserError
      stdout.force_encoding('UTF-8').strip
    end

    # NotebookLM sometimes returns a "thinking" summary (an English draft that
    # starts with "**...") instead of the final answer; callers retry then.
    def thinking_frame?(answer)
      answer.start_with?('**')
    end

    def unescape_once(text)
      text.gsub(/\\([\[\]\\"nrt])/) do
        case Regexp.last_match(1)
        when 'n' then "\n"
        when 'r' then "\r"
        when 't' then "\t"
        else Regexp.last_match(1)
        end
      end
    end

    # nlm responses can multiply-escape newlines/brackets (e.g. "\\n", \[1\]),
    # which are invalid JSON escapes, so JSON.parse can't be used. Unescape one
    # level at a time until the string stabilizes.
    def normalize_literal_escapes(text)
      return text unless text.is_a?(String)

      5.times do
        next_text = unescape_once(text)
        return text if next_text == text

        text = next_text
      end
      text
    end
  end
end
