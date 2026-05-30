# frozen_string_literal: true

require 'erb'
require 'fileutils'
require 'json'
require 'open3'
require 'rexml/document'
require 'set'
require 'time'
require 'uri'
require 'yaml'

# Cloudflare R2 にマスタリング済み MP3 と RSS フィード (feed.xml) をアップロードし、
# Spotify for Creators など RSS ベースの Podcast プラットフォームに配信するためのスクリプト。
#
# 設定:
#   - podcast.yml … チャンネル設定 (R2, 公開 URL, 既存 RSS URL, スケジュール)
#   - .env        … R2 認証情報 (R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY)
#
# 依存: aws CLI, curl, ffprobe, nlm CLI
#
# モード:
#   --bootstrap : 既存 RSS を取得してそのまま feed.xml として R2 へアップロード
#                 (Spotify 側で RSS フィード URL を新 URL に差し替える初期セットアップ)
#   <MP3_DIR>   : マスタリング済み MP3 と NotebookLM のメタデータからエピソードを追加

PODCAST_NOTE_TITLE = 'Podcast 公開用メタデータ'
DEFAULT_CONFIG_PATH = 'podcast.yml'
DEFAULT_ENV_PATH = '.env'
DEFAULT_LOCAL_FEED_PATH = 'feed.xml'
FEED_KEY_NAME = 'feed.xml'

R2_ENDPOINT_TEMPLATE = 'https://%s.r2.cloudflarestorage.com'
ITUNES_NS = 'http://www.itunes.com/dtds/podcast-1.0.dtd'

SLEEP_BETWEEN = 1

# ---------- env / config ----------

def load_env_file(path)
  return unless File.file?(path)

  File.foreach(path) do |line|
    line = line.strip
    next if line.empty? || line.start_with?('#')

    key, value = line.split('=', 2)
    next unless key && value

    ENV[key] ||= value.gsub(/\A["']|["']\z/, '')
  end
end

def load_config(path)
  unless File.file?(path)
    warn "Error: Config file not found: #{path}"
    warn 'Copy podcast.yml.example to podcast.yml and fill in values.'
    exit 1
  end

  config = YAML.safe_load_file(path) || {}
  validate_config(config, path)
  config
end

def validate_config(config, path)
  required = [
    %w[r2 account_id],
    %w[r2 bucket],
    %w[r2 public_base_url],
    ['existing_rss_url']
  ]
  missing = required.reject { |keys| config.dig(*keys).is_a?(String) && !config.dig(*keys).empty? }
  return if missing.empty?

  warn "Error: Missing keys in #{path}:"
  missing.each { |keys| warn "  - #{keys.join('.')}" }
  exit 1
end

def require_env!(*names)
  missing = names.reject { |n| ENV[n] && !ENV[n].empty? }
  return if missing.empty?

  warn "Error: Missing environment variables: #{missing.join(', ')}"
  warn 'Set them in .env (see .env.example) or in the shell environment.'
  exit 1
end

# ---------- R2 (aws CLI) ----------

def aws_env
  {
    'AWS_ACCESS_KEY_ID' => ENV['R2_ACCESS_KEY_ID'].to_s,
    'AWS_SECRET_ACCESS_KEY' => ENV['R2_SECRET_ACCESS_KEY'].to_s,
    'AWS_DEFAULT_REGION' => 'auto'
  }
end

def r2_endpoint(account_id)
  format(R2_ENDPOINT_TEMPLATE, account_id)
end

def r2_key(config, name)
  prefix = config.dig('r2', 'key_prefix').to_s
  prefix.empty? ? name : "#{prefix.sub(%r{/+\z}, '')}/#{name}"
end

def r2_public_url(config, name)
  base = config.dig('r2', 'public_base_url').sub(%r{/+\z}, '')
  prefix = config.dig('r2', 'key_prefix').to_s.sub(%r{/+\z}, '')
  encoded = ERB::Util.url_encode(name)
  prefix.empty? ? "#{base}/#{encoded}" : "#{base}/#{prefix}/#{encoded}"
end

def r2_upload(local_path, key, config, content_type:)
  bucket = config.dig('r2', 'bucket')
  account_id = config.dig('r2', 'account_id')
  cmd = [
    'aws', 's3', 'cp', local_path, "s3://#{bucket}/#{key}",
    '--endpoint-url', r2_endpoint(account_id),
    '--content-type', content_type
  ]
  _stdout, stderr, status = Open3.capture3(aws_env, *cmd)
  unless status.success?
    warn "  ERROR: aws s3 cp failed for #{key}: #{stderr.strip}"
    return false
  end
  true
end

def r2_object_exists?(key, config)
  bucket = config.dig('r2', 'bucket')
  account_id = config.dig('r2', 'account_id')
  cmd = [
    'aws', 's3api', 'head-object',
    '--bucket', bucket, '--key', key,
    '--endpoint-url', r2_endpoint(account_id)
  ]
  _stdout, _stderr, status = Open3.capture3(aws_env, *cmd)
  status.success?
end

# ---------- HTTP download ----------

def download_url(url, local_path)
  cmd = ['curl', '-fsSL', url, '-o', local_path]
  _stdout, stderr, status = Open3.capture3(*cmd)
  return true if status.success?

  warn "  ERROR: curl failed for #{url}: #{stderr.strip}"
  false
end

# ---------- ffprobe ----------

def mp3_duration_seconds(path)
  cmd = ['ffprobe', '-v', 'error', '-show_entries', 'format=duration',
         '-of', 'default=noprint_wrappers=1:nokey=1', path]
  stdout, _stderr, status = Open3.capture3(*cmd)
  return nil unless status.success?

  stdout.strip.to_f
end

def format_duration(seconds)
  total = seconds.to_i
  h = total / 3600
  m = (total % 3600) / 60
  s = total % 60
  format('%02d:%02d:%02d', h, m, s)
end

# ---------- NotebookLM ----------

def fetch_filename_to_notebook_id_map
  puts 'Fetching NotebookLM notebooks...'
  stdout, _stderr, status = Open3.capture3('nlm', 'notebook', 'list', '--json')
  return {} unless status.success?

  notebooks = JSON.parse(stdout)
  result = {}
  notebooks.each do |nb|
    next if nb['source_count'].to_i.zero?

    src_stdout, _err, src_status = Open3.capture3('nlm', 'source', 'list', nb['id'], '--json')
    next unless src_status.success?

    sources = JSON.parse(src_stdout)
    sources.each do |src|
      next unless src['type'] == 'audio'

      decoded = URI.decode_www_form_component(src['title'])
      result[decoded] ||= nb['id']
    end
  end
  puts "  Found #{result.size} audio sources mapped to notebooks"
  result
rescue JSON::ParserError
  {}
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

# nlm のレスポンスは "\\n" のように改行や角括弧が多重エスケープされて
# 返ってくるケースがある (sources_used が空の場合など)。安定するまで
# 一段ずつエスケープを解除する。
def normalize_literal_escapes(text)
  return text unless text.is_a?(String)

  5.times do
    next_text = unescape_once(text)
    return text if next_text == text

    text = next_text
  end
  text
end

def fetch_metadata_note_text(notebook_id)
  stdout, _stderr, status = Open3.capture3('nlm', 'note', 'list', notebook_id, '--json')
  return nil unless status.success?

  parsed = JSON.parse(stdout)
  notes = parsed.is_a?(Hash) ? (parsed['notes'] || []) : parsed
  note = notes.find { |n| n.is_a?(Hash) && n['title'] == PODCAST_NOTE_TITLE }
  return nil unless note

  raw = note['content'].to_s
  return raw unless raw.lstrip.start_with?('{')

  answer = nil

  begin
    inner = JSON.parse(raw)
    answer = inner.dig('value', 'answer') || inner['answer']
  rescue JSON::ParserError
    # fall through to regex fallback
  end

  unless answer.is_a?(String)
    # nlm が "sources_used": \[\] や \[1\] のような不正エスケープを返すケースのフォールバック。
    # 取得した生文字列を JSON.parse せず、normalize_literal_escapes に任せる
    # (\[ などは JSON 文字列として無効なエスケープなので JSON.parse は使えない)。
    match = raw.match(/"answer"\s*:\s*"((?:[^"\\]|\\.)*)"/m)
    return nil unless match

    answer = match[1]
  end

  # nlm の一部レスポンスでは改行などが二重エスケープされ \n がリテラル文字として
  # 残るため、改行・タブ・クォートを実体に戻す。
  normalize_literal_escapes(answer)
rescue JSON::ParserError
  nil
end

def strip_citations(text)
  text.gsub(/\s*\[\d+(?:\s*[-,\s]\s*\d+)*\]/, '')
end

def parse_metadata(answer)
  return nil unless answer

  cleaned = strip_citations(answer).strip
  match = cleaned.match(/\Aタイトル[:：]\s*(?<title>.+?)\s*\n\s*\n+説明[:：]\s*(?<desc>.+)\z/m)
  return nil unless match

  { title: match[:title].strip, description: match[:desc].strip }
end

# ---------- RSS / feed.xml ----------

def load_feed(path)
  doc = REXML::Document.new(File.read(path))
  channel = doc.root&.elements&.[]('channel')
  raise "No <channel> element in #{path}" unless channel

  doc
end

def existing_guids(doc)
  guids = Set.new
  doc.root.elements.each('channel/item/guid') do |g|
    text = g.text.to_s.strip
    guids.add(text) unless text.empty?
  end
  guids
end

def ensure_itunes_namespace(doc)
  rss = doc.root
  rss.add_namespace('itunes', ITUNES_NS) unless rss.namespaces['itunes']
end

def append_item(doc, title:, description:, pub_date:, guid:, mp3_url:, mp3_size:, duration_sec:)
  channel = doc.root.elements['channel']
  item = REXML::Element.new('item')

  title_el = item.add_element('title')
  title_el.add(REXML::CData.new(title))

  desc_el = item.add_element('description')
  desc_el.add(REXML::CData.new(description))

  item.add_element('pubDate').text = pub_date.rfc2822

  guid_el = item.add_element('guid', 'isPermaLink' => 'false')
  guid_el.text = guid

  item.add_element('enclosure',
                   'url' => mp3_url,
                   'length' => mp3_size.to_s,
                   'type' => 'audio/mpeg')

  item.add_element('itunes:duration').text = format_duration(duration_sec)
  summary_el = item.add_element('itunes:summary')
  summary_el.add(REXML::CData.new(description))
  item.add_element('itunes:explicit').text = 'false'

  first_item = channel.elements['item']
  if first_item
    channel.insert_before(first_item, item)
  else
    channel.add_element(item)
  end
end

def write_feed(doc, path)
  formatter = REXML::Formatters::Default.new
  File.open(path, 'w') do |f|
    f.write(%(<?xml version="1.0" encoding="UTF-8"?>\n))
    formatter.write(doc.root, f)
    f.write("\n")
  end
end

# ---------- modes ----------

def run_bootstrap(config)
  url = config['existing_rss_url']
  local = DEFAULT_LOCAL_FEED_PATH
  puts "Downloading existing RSS from #{url} ..."
  unless download_url(url, local)
    warn 'Bootstrap failed: could not download existing RSS.'
    exit 1
  end

  feed_key = r2_key(config, FEED_KEY_NAME)
  puts "Uploading feed.xml to s3://#{config.dig('r2', 'bucket')}/#{feed_key} ..."
  unless r2_upload(local, feed_key, config, content_type: 'application/rss+xml; charset=utf-8')
    warn 'Bootstrap failed: could not upload feed.xml to R2.'
    exit 1
  end

  feed_url = r2_public_url(config, FEED_KEY_NAME)
  puts
  puts '=== Bootstrap done ==='
  puts "Feed URL (Spotify for Creators の RSS 差し替え URL): #{feed_url}"
  puts "Local copy: #{File.expand_path(local)}"
end

def run_publish_feed(config)
  local = DEFAULT_LOCAL_FEED_PATH
  unless File.file?(local)
    warn "Error: #{local} not found."
    warn 'Run a publish step (with --no-publish to stage) before --publish-feed.'
    exit 1
  end

  feed_key = r2_key(config, FEED_KEY_NAME)
  puts "Uploading #{local} to s3://#{config.dig('r2', 'bucket')}/#{feed_key} ..."
  unless r2_upload(local, feed_key, config, content_type: 'application/rss+xml; charset=utf-8')
    warn 'Failed to upload feed.xml.'
    exit 1
  end

  puts "Feed URL: #{r2_public_url(config, FEED_KEY_NAME)}"
end

def fetch_current_feed(config, local)
  feed_key = r2_key(config, FEED_KEY_NAME)
  unless r2_object_exists?(feed_key, config)
    warn 'Error: feed.xml does not exist on R2 yet.'
    warn 'Run with --bootstrap first to seed it from the existing RSS.'
    exit 1
  end

  feed_url = r2_public_url(config, FEED_KEY_NAME)
  puts "Downloading current feed.xml from #{feed_url} ..."
  unless download_url(feed_url, local)
    warn 'Failed to fetch current feed.xml.'
    exit 1
  end
end

def compute_pub_date(start_date_str, interval_days, index)
  start_date = Time.parse(start_date_str)
  start_date + (interval_days * index * 86_400)
end

def upload_episode(mp3_path, mp3_key, config)
  r2_upload(mp3_path, mp3_key, config, content_type: 'audio/mpeg')
end

def run_publish(mp3_dir, config, options)
  start_date_str = options[:start_date] || config.dig('schedule', 'start_date')
  interval_days = options[:interval_days] || config.dig('schedule', 'interval_days') || 7
  unless start_date_str
    warn 'Error: start_date is required (config.schedule.start_date or --start-date).'
    exit 1
  end

  mp3_files = Dir.glob(File.join(mp3_dir, '*.mp3')).sort
  if mp3_files.empty?
    warn "No MP3 files found in #{mp3_dir}"
    exit 1
  end

  local_feed = DEFAULT_LOCAL_FEED_PATH
  fetch_current_feed(config, local_feed)
  doc = load_feed(local_feed)
  ensure_itunes_namespace(doc)
  guids = existing_guids(doc)
  filename_to_notebook = fetch_filename_to_notebook_id_map
  puts

  added = 0
  skipped = 0
  failed = 0
  next_index = 0

  mp3_files.each_with_index do |mp3, i|
    filename = File.basename(mp3)
    title_base = File.basename(mp3, '.mp3')
    puts "[#{i + 1}/#{mp3_files.size}] #{title_base}"

    if guids.include?(filename)
      puts '  Skipped (already in feed)'
      skipped += 1
      puts
      next
    end

    notebook_id = filename_to_notebook[filename]
    unless notebook_id
      warn '  WARN: No notebook found for this MP3; skipping'
      failed += 1
      puts
      next
    end

    metadata_text = fetch_metadata_note_text(notebook_id)
    metadata = parse_metadata(metadata_text)
    unless metadata
      warn "  WARN: Could not parse '#{PODCAST_NOTE_TITLE}' note; skipping"
      failed += 1
      puts
      next
    end

    duration_sec = mp3_duration_seconds(mp3)
    unless duration_sec
      warn '  WARN: ffprobe failed; skipping'
      failed += 1
      puts
      next
    end

    mp3_size = File.size(mp3)
    pub_date = compute_pub_date(start_date_str, interval_days, next_index)
    mp3_key = r2_key(config, filename)
    mp3_url = r2_public_url(config, filename)

    if options[:dry_run]
      puts '  [dry-run] would upload MP3 and add item:'
      puts "    title:    #{metadata[:title]}"
      puts "    pubDate:  #{pub_date.rfc2822}"
      puts "    duration: #{format_duration(duration_sec)} (#{duration_sec.to_i}s)"
      puts "    url:      #{mp3_url}"
      added += 1
      next_index += 1
      puts
      next
    end

    puts "  Uploading MP3 to #{mp3_key} ..."
    unless upload_episode(mp3, mp3_key, config)
      failed += 1
      puts
      next
    end

    append_item(
      doc,
      title: metadata[:title],
      description: metadata[:description],
      pub_date: pub_date,
      guid: filename,
      mp3_url: mp3_url,
      mp3_size: mp3_size,
      duration_sec: duration_sec
    )
    guids.add(filename)
    added += 1
    next_index += 1

    puts "  Added: '#{metadata[:title]}' (pubDate: #{pub_date.rfc2822})"
    puts
    sleep SLEEP_BETWEEN
  end

  if added.positive? && !options[:dry_run]
    write_feed(doc, local_feed)
    if options[:no_publish]
      puts "Staged #{added} item(s) in #{File.expand_path(local_feed)} (feed.xml NOT uploaded)."
      puts 'Review/edit titles and descriptions, then publish with:'
      puts "  ruby #{$PROGRAM_NAME} --publish-feed"
    else
      feed_key = r2_key(config, FEED_KEY_NAME)
      puts "Uploading updated feed.xml to #{feed_key} ..."
      unless r2_upload(local_feed, feed_key, config, content_type: 'application/rss+xml; charset=utf-8')
        warn 'Failed to upload feed.xml. Local copy retained.'
        exit 1
      end
      puts "Feed URL: #{r2_public_url(config, FEED_KEY_NAME)}"
    end
  elsif options[:dry_run]
    puts '(dry-run: feed.xml not modified)'
  end

  puts
  puts "=== Done - #{Time.now} ==="
  puts "Added: #{added}, Skipped: #{skipped}, Failed: #{failed}, Total: #{mp3_files.size}"
end

# ---------- CLI ----------

def parse_cli_args
  args = ARGV.dup
  opts = { bootstrap: false, dry_run: false, no_publish: false, publish_feed: false }

  while (arg = args.shift)
    case arg
    when '--bootstrap'
      opts[:bootstrap] = true
    when '--publish-feed'
      opts[:publish_feed] = true
    when '--no-publish'
      opts[:no_publish] = true
    when '--dry-run'
      opts[:dry_run] = true
    when '--start-date'
      opts[:start_date] = args.shift
    when '--interval-days'
      opts[:interval_days] = args.shift.to_i
    when '--config'
      opts[:config_path] = args.shift
    when '--env'
      opts[:env_path] = args.shift
    when '-h', '--help'
      print_usage
      exit 0
    else
      opts[:mp3_dir] ||= arg
    end
  end

  opts
end

def print_usage
  puts <<~USAGE
    Usage:
      ruby #{$PROGRAM_NAME} --bootstrap [--config podcast.yml] [--env .env]
      ruby #{$PROGRAM_NAME} <MP3_DIR> [--start-date <ISO8601>] [--interval-days <N>] [--dry-run] [--no-publish]
      ruby #{$PROGRAM_NAME} --publish-feed

    Bootstrap mode:
      既存 RSS を取得してそのまま feed.xml として R2 にアップロードします。

    Publish mode:
      MP3_DIR 配下のマスタリング済み MP3 ごとに、NotebookLM の
      「#{PODCAST_NOTE_TITLE}」ノートからタイトル・説明を抽出し、
      MP3 を R2 にアップロードして feed.xml に <item> を追加します。

      --start-date    最初のエピソードの公開日時 (ISO8601)。省略時は podcast.yml の値。
      --interval-days 連続投入時のエピソード間隔日数。省略時は podcast.yml の値か 7。
      --dry-run       アップロードや feed.xml 更新を行わず内容を表示するのみ。
      --no-publish    MP3 アップロードとローカル feed.xml への追記まで行い、
                      feed.xml の R2 アップロードはスキップします (公開前レビュー用)。
                      レビュー・修正後に --publish-feed で公開してください。

    Publish-feed mode:
      ローカルの feed.xml をそのまま R2 にアップロードして公開します。
      --no-publish でステージしたフィードのタイトル・説明を手で修正したあと、
      この モードで公開する 2 段階フローを想定しています。
  USAGE
end

def main
  opts = parse_cli_args

  load_env_file(opts[:env_path] || DEFAULT_ENV_PATH)
  require_env!('R2_ACCESS_KEY_ID', 'R2_SECRET_ACCESS_KEY')
  config = load_config(opts[:config_path] || DEFAULT_CONFIG_PATH)

  if opts[:bootstrap]
    run_bootstrap(config)
    return
  end

  if opts[:publish_feed]
    run_publish_feed(config)
    return
  end

  unless opts[:mp3_dir]
    print_usage
    exit 1
  end

  unless File.directory?(opts[:mp3_dir])
    warn "Error: Directory not found: #{opts[:mp3_dir]}"
    exit 1
  end

  run_publish(opts[:mp3_dir], config, opts)
end

main if __FILE__ == $PROGRAM_NAME
