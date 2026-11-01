# frozen_string_literal: true

require_relative 'lib/podcast_toolkit/agy'

MAX_ATTEMPTS = 3
SLEEP_BETWEEN_RETRIES = 10

def print_metadata(metadata)
  puts "  タイトル: #{metadata['title']}"
  puts '  説明:'
  metadata['description'].each_line { |line| puts "    #{line.chomp}" }
  cuts = metadata['cut_requests']
  if cuts.empty?
    puts '  カット依頼: なし'
  else
    puts "  カット依頼: #{cuts.size} 件"
    cuts.each { |c| puts "    [#{c['timestamp']}] #{c['quote']}" }
  end
end

def generate_with_retries(mp3, model)
  error = nil
  MAX_ATTEMPTS.times do |attempt|
    metadata, error = PodcastToolkit::Agy.generate(mp3, model: model)
    return [metadata, nil] if metadata

    warn "  WARN: #{error} (#{attempt + 1}/#{MAX_ATTEMPTS})"
    sleep SLEEP_BETWEEN_RETRIES if attempt + 1 < MAX_ATTEMPTS
  end
  [nil, error]
end

def run(mp3_files, model:, force:)
  counts = { generated: 0, skipped: 0, failed: 0 }

  mp3_files.each_with_index do |mp3, i|
    puts "[#{i + 1}/#{mp3_files.size}] #{File.basename(mp3, '.mp3')}"
    meta_path = PodcastToolkit::Agy.metadata_path(mp3)

    if !force && PodcastToolkit::Agy.load_metadata(mp3)
      puts "  Skipped (#{File.basename(meta_path)} already exists)"
      counts[:skipped] += 1
    else
      puts "  #{File.basename(meta_path)} is unreadable or empty; regenerating" if File.exist?(meta_path) && !force
      puts "  Generating metadata with agy (#{model})..."
      metadata, error = generate_with_retries(mp3, model)
      if metadata
        PodcastToolkit::Agy.write_metadata(mp3, metadata, model: model)
        print_metadata(metadata)
        puts "  Saved #{File.basename(meta_path)}"
        counts[:generated] += 1
      else
        warn "  ERROR: #{error}"
        counts[:failed] += 1
      end
    end
    puts
  end

  counts
end

def parse_args(argv)
  args = argv.dup
  opts = { force: false, model: PodcastToolkit::Agy::DEFAULT_MODEL }
  while (arg = args.shift)
    case arg
    when '--force' then opts[:force] = true
    when '--model' then opts[:model] = args.shift
    else opts[:mp3_dir] ||= arg
    end
  end
  opts
end

def main
  opts = parse_args(ARGV)
  unless opts[:mp3_dir] && opts[:model]
    warn "Usage: ruby #{$PROGRAM_NAME} [--force] [--model MODEL] <MP3_DIRECTORY>"
    exit 1
  end
  unless File.directory?(opts[:mp3_dir])
    warn "Error: Directory not found: #{opts[:mp3_dir]}"
    exit 1
  end

  mp3_files = PodcastToolkit::Agy.mp3_files(opts[:mp3_dir])
  if mp3_files.empty?
    puts "No MP3 files found in #{opts[:mp3_dir]}"
    exit 1
  end

  puts "=== Episode metadata (agy) - #{Time.now} ==="
  puts "Found #{mp3_files.size} MP3 files"
  puts

  counts = run(mp3_files, model: opts[:model], force: opts[:force])

  puts "=== Done - #{Time.now} ==="
  puts "Generated: #{counts[:generated]}, Skipped: #{counts[:skipped]}, Failed: #{counts[:failed]}, Total: #{mp3_files.size}"
  exit 1 if counts[:failed].positive?
end

main if __FILE__ == $PROGRAM_NAME
