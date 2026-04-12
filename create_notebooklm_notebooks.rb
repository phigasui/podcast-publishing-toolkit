# frozen_string_literal: true

require 'open3'
require 'json'
require 'uri'

WAIT_TIMEOUT = 1200
SLEEP_BETWEEN = 2
SLEEP_AFTER_FAILURE = 30
QUERY_TIMEOUT = 180
PODCAST_NOTE_TITLE = "Podcast 公開用メタデータ"
PODCAST_METADATA_PROMPT = <<~PROMPT.freeze
  この録音を Podcast のエピソードとして公開します。日本語で、以下のフォーマットに厳密に従ってエピソードタイトルとエピソード説明を生成してください。前置きや補足は書かないでください。

  タイトル: <60文字以内。内容が一目で分かり、リスナーが聞きたくなる具体的な表現にする>

  説明:
  <200〜400文字程度。何について話しているか、主要なトピック、聞きどころが分かるようにまとめる。改行は自由>
PROMPT

def fetch_notebooks_state
  puts "Fetching existing notebooks..."
  stdout, _stderr, status = Open3.capture3("nlm", "notebook", "list", "--json")
  return { source_filenames: Set.new, empty_by_title: {}, notebook_by_filename: {} } unless status.success?

  notebooks = JSON.parse(stdout)
  source_filenames = Set.new
  empty_by_title = {}
  notebook_by_filename = {}

  notebooks.each do |nb|
    if nb["source_count"].to_i == 0
      empty_by_title[nb["title"]] = nb["id"]
      next
    end

    src_stdout, _src_stderr, src_status = Open3.capture3("nlm", "source", "list", nb["id"], "--json")
    next unless src_status.success?

    sources = JSON.parse(src_stdout)
    sources.each do |src|
      next unless src["type"] == "audio"

      decoded_title = URI.decode_www_form_component(src["title"])
      source_filenames.add(decoded_title)
      notebook_by_filename[decoded_title] ||= nb["id"]
    end
  end

  puts "Found #{source_filenames.size} existing audio sources"
  puts "Found #{empty_by_title.size} empty notebooks to repair"
  { source_filenames: source_filenames, empty_by_title: empty_by_title, notebook_by_filename: notebook_by_filename }
end

def notebook_has_metadata_note?(notebook_id)
  stdout, _stderr, status = Open3.capture3("nlm", "note", "list", notebook_id, "--json")
  return false unless status.success?

  parsed = JSON.parse(stdout)
  notes = parsed.is_a?(Hash) ? (parsed["notes"] || []) : parsed
  notes.any? { |n| n.is_a?(Hash) && n["title"] == PODCAST_NOTE_TITLE }
rescue JSON::ParserError
  false
end

def extract_notebook_id(output)
  output[/ID:\s*(\S+)/, 1]
end

def create_notebook(title)
  stdout, stderr, status = Open3.capture3("nlm", "notebook", "create", title)
  output = stdout + stderr

  unless status.success?
    warn "  ERROR: Failed to create notebook: #{output}"
    return nil
  end

  notebook_id = extract_notebook_id(output)
  unless notebook_id
    warn "  ERROR: Could not extract notebook ID from: #{output}"
    return nil
  end

  puts "  Created notebook: #{notebook_id}"
  notebook_id
end

def generate_podcast_metadata(notebook_id)
  puts "  Generating podcast title & description..."
  stdout, stderr, status = Open3.capture3(
    "nlm", "query", "notebook", notebook_id, PODCAST_METADATA_PROMPT,
    "--timeout", QUERY_TIMEOUT.to_s
  )

  unless status.success?
    warn "  WARN: Failed to generate podcast metadata: #{stderr.strip}"
    return nil
  end

  content = stdout.strip
  if content.empty?
    warn "  WARN: Empty response from query"
    return nil
  end

  content
end

def save_podcast_metadata_note(notebook_id, content)
  _stdout, stderr, status = Open3.capture3(
    "nlm", "note", "create", notebook_id,
    "--title", PODCAST_NOTE_TITLE,
    "--content", content
  )

  unless status.success?
    warn "  WARN: Failed to save metadata note: #{stderr.strip}"
    return false
  end

  true
end

def create_podcast_metadata(notebook_id)
  content = generate_podcast_metadata(notebook_id)
  return unless content

  puts "  --- Podcast metadata ---"
  content.each_line { |line| puts "  #{line.chomp}" }
  puts "  ------------------------"

  save_podcast_metadata_note(notebook_id, content)
end

def add_source(notebook_id, mp3_path)
  puts "  Adding source (this may take a while for large files)..."
  stdout, stderr, status = Open3.capture3(
    "nlm", "source", "add", notebook_id,
    "--file", mp3_path,
    "--wait", "--wait-timeout", WAIT_TIMEOUT.to_s
  )
  output = stdout + stderr

  if status.success?
    puts "  Source added successfully"
    true
  else
    warn "  ERROR: Failed to add source: #{output}"
    false
  end
end

def run_import(mp3_files)
  state = fetch_notebooks_state
  existing_filenames = state[:source_filenames]
  empty_notebooks = state[:empty_by_title]
  puts

  success = 0
  repaired = 0
  failed = 0
  skipped = 0

  mp3_files.each_with_index do |mp3, i|
    title = File.basename(mp3, ".mp3")
    filename = File.basename(mp3)
    puts "[#{i + 1}/#{mp3_files.size}] #{title}"

    if existing_filenames.include?(filename)
      puts "  Skipped (already exists)"
      skipped += 1
      puts
      next
    end

    if empty_notebooks.key?(title)
      notebook_id = empty_notebooks[title]
      puts "  Reusing existing empty notebook: #{notebook_id}"
      is_repair = true
    else
      notebook_id = create_notebook(title)
      unless notebook_id
        failed += 1
        puts
        next
      end
      is_repair = false
    end

    if add_source(notebook_id, mp3)
      create_podcast_metadata(notebook_id)
      if is_repair
        repaired += 1
      else
        success += 1
      end
      sleep SLEEP_BETWEEN
    else
      failed += 1
      puts "  Waiting #{SLEEP_AFTER_FAILURE}s before next attempt..."
      sleep SLEEP_AFTER_FAILURE
    end

    puts
  end

  puts "=== Done - #{Time.now} ==="
  puts "Success: #{success}, Repaired: #{repaired}, Skipped: #{skipped}, Failed: #{failed}, Total: #{mp3_files.size}"
end

def run_backfill(mp3_files)
  state = fetch_notebooks_state
  notebook_by_filename = state[:notebook_by_filename]
  puts

  generated = 0
  already_has = 0
  not_imported = 0
  failed = 0

  mp3_files.each_with_index do |mp3, i|
    title = File.basename(mp3, ".mp3")
    filename = File.basename(mp3)
    puts "[#{i + 1}/#{mp3_files.size}] #{title}"

    notebook_id = notebook_by_filename[filename]
    unless notebook_id
      puts "  Skipped (not yet imported)"
      not_imported += 1
      puts
      next
    end

    if notebook_has_metadata_note?(notebook_id)
      puts "  Skipped (metadata note already exists)"
      already_has += 1
      puts
      next
    end

    if create_podcast_metadata(notebook_id)
      generated += 1
      sleep SLEEP_BETWEEN
    else
      failed += 1
    end

    puts
  end

  puts "=== Done - #{Time.now} ==="
  puts "Generated: #{generated}, Already has note: #{already_has}, Not imported: #{not_imported}, Failed: #{failed}, Total: #{mp3_files.size}"
end

def main
  args = ARGV.dup
  backfill = !args.delete("--backfill").nil?

  if args.empty?
    warn "Usage: ruby #{$PROGRAM_NAME} [--backfill] <MP3_DIRECTORY>"
    exit 1
  end

  mp3_dir = args[0]
  unless File.directory?(mp3_dir)
    warn "Error: Directory not found: #{mp3_dir}"
    exit 1
  end

  mp3_files = Dir.glob(File.join(mp3_dir, "*.mp3")).sort

  if mp3_files.empty?
    puts "No MP3 files found in #{mp3_dir}"
    exit 1
  end

  mode = backfill ? "Podcast Metadata Backfill" : "Notebook Creation"
  puts "=== NotebookLM #{mode} - #{Time.now} ==="
  puts "Found #{mp3_files.size} MP3 files"
  puts

  if backfill
    run_backfill(mp3_files)
  else
    run_import(mp3_files)
  end
end

main if __FILE__ == $PROGRAM_NAME
