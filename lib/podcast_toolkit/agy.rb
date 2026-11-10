# frozen_string_literal: true

require 'json'
require 'open3'
require 'tmpdir'
require 'time'

module PodcastToolkit
  # Episode metadata generation via the Antigravity CLI (`agy -p`), and the
  # `<name>.meta.json` files it is stored in next to each MP3.
  #
  # agy reads the MP3 directly (Gemini multimodal) and --json-schema makes it
  # return structured output, so none of the NotebookLM response cleanup in
  # PodcastToolkit::Nlm (thinking frames, [1] citations, double escapes) is
  # needed here.
  module Agy
    module_function

    DEFAULT_MODEL = 'gemini-3.8-flash-low'
    DEFAULT_TIMEOUT = 900

    SCHEMA = {
      'type' => 'object',
      'properties' => {
        'title' => { 'type' => 'string' },
        'description' => { 'type' => 'string' },
        'cut_requests' => {
          'type' => 'array',
          'items' => {
            'type' => 'object',
            'properties' => {
              'timestamp' => { 'type' => 'string' },
              'quote' => { 'type' => 'string' }
            },
            'required' => %w[timestamp quote]
          }
        }
      },
      'required' => %w[title description cut_requests]
    }.freeze

    # In headless print mode agy auto-denies shell commands, and an agent that
    # tries one (e.g. ffprobe) returns an empty response, so the prompt tells
    # it to read the file directly.
    def prompt(filename)
      <<~PROMPT
        #{filename} は Podcast エピソードの録音です。コマンドは実行せず、ファイル閲覧ツールでこの音声ファイルを直接読み込み、最後まで聞いてください。

        - title: 日本語のエピソードタイトル。60 文字以内。内容が一目で分かり、リスナーが聞きたくなる具体的な表現にする
        - description: 日本語のエピソード説明。200〜400 文字程度。何について話しているか、主要なトピック、聞きどころが分かるようにまとめる。改行は自由
        - cut_requests: 話者が「カットして」「今のはなしで」「編集で切って」などと編集での削除を依頼した発言すべて。timestamp はおおよその位置（mm:ss または hh:mm:ss）、quote は発言の引用。無ければ空配列

        音声に無い内容を書き足さないこと。音声を聞けなかった場合は推測せず、title を空文字にすること。
      PROMPT
    end

    def metadata_path(mp3_path)
      mp3_path.sub(/\.mp3\z/i, '.meta.json')
    end

    # Returns { title:, description: } from the MP3's metadata JSON, or nil when
    # the file is missing, unparseable, or has an empty title/description.
    def load_metadata(mp3_path)
      path = metadata_path(mp3_path)
      return nil unless File.exist?(path)

      data = JSON.parse(File.read(path, encoding: 'UTF-8'))
      title = data['title'].to_s.strip
      description = data['description'].to_s.strip
      return nil if title.empty? || description.empty?

      { title: title, description: description }
    rescue JSON::ParserError
      nil
    end

    # Mastered MP3s (~64MB for 45 min) make agy's read_file return an empty
    # model response, so agy gets a mono 16kHz 32kbps copy instead (~17MB for
    # 72 min, which works).
    def downsample_cmd(src, dest)
      ['ffmpeg', '-v', 'error', '-y', '-i', src, '-vn', '-ac', '1', '-ar', '16000', '-b:a', '32k', dest]
    end

    # Run agy on one MP3. Returns [metadata_hash, nil] on success or
    # [nil, error_message] on failure.
    def generate(mp3_path, model: DEFAULT_MODEL, timeout: DEFAULT_TIMEOUT)
      Dir.mktmpdir('agy-audio') do |dir|
        audio = File.join(dir, File.basename(mp3_path))
        _, stderr, status = Open3.capture3(*downsample_cmd(File.expand_path(mp3_path), audio))
        return [nil, "ffmpeg exited #{status.exitstatus}: #{stderr.strip}"] unless status.success?

        schema = File.join(dir, 'schema.json')
        File.write(schema, JSON.generate(SCHEMA))
        cmd = [
          'agy', '-p', prompt(File.basename(mp3_path)),
          '--model', model,
          '--output-format', 'json',
          '--json-schema', schema,
          '--print-timeout', "#{timeout}s"
        ]
        stdout, stderr, status = Open3.capture3(*cmd, chdir: dir)
        return [nil, "agy exited #{status.exitstatus}: #{stderr.strip}"] unless status.success?

        parse_result(stdout)
      end
    rescue SystemCallError => e # agy / ffmpeg 未インストールなど
      [nil, "could not run command: #{e.message}"]
    end

    # Parse `agy --output-format json` output into a metadata hash.
    def parse_result(stdout)
      result = JSON.parse(stdout.to_s.dup.force_encoding('UTF-8'))
      return [nil, "unexpected agy output: #{stdout.to_s[0, 80]}"] unless result.is_a?(Hash)
      return [nil, "agy status #{result['status']}"] unless result['status'] == 'SUCCESS'

      denied = Array(result['denied_actions']).map { |a| a.is_a?(Hash) ? (a['display_name'] || a['action']) : a.to_s }
      out = result['structured_output']
      unless out.is_a?(Hash)
        reason = denied.empty? ? 'no structured_output' : "no structured_output (denied: #{denied.join(', ')})"
        return [nil, reason]
      end

      title = out['title'].to_s.strip
      description = out['description'].to_s.strip
      return [nil, 'empty title (agy could not hear the audio?)'] if title.empty?
      return [nil, 'empty description'] if description.empty?

      cuts = Array(out['cut_requests']).select { |c| c.is_a?(Hash) }.map do |c|
        { 'timestamp' => c['timestamp'].to_s.strip, 'quote' => c['quote'].to_s.strip }
      end
      [{ 'title' => title, 'description' => description, 'cut_requests' => cuts }, nil]
    rescue JSON::ParserError => e
      [nil, "could not parse agy output: #{e.message}"]
    end

    def write_metadata(mp3_path, metadata, model:)
      record = metadata.merge(
        'source' => File.basename(mp3_path),
        'model' => model,
        'generated_at' => Time.now.iso8601
      )
      # 途中で切れた .meta.json が残ると公開側が NotebookLM に戻らず失敗するので、rename で置き換える
      path = metadata_path(mp3_path)
      tmp = "#{path}.tmp"
      File.write(tmp, "#{JSON.pretty_generate(record)}\n")
      File.rename(tmp, path)
    end

    # MP3 files in dir, matching .mp3 case-insensitively (EP01.MP3 too).
    def mp3_files(dir)
      Dir.children(dir).select { |name| name.match?(/\.mp3\z/i) }.sort.map { |name| File.join(dir, name) }
    end
  end
end
