# frozen_string_literal: true

require 'open3' # For better command execution and error handling
require_relative 'lib/podcast_toolkit/cli'

# --- Configuration ---
# SOURCE_DIR and DEST_DIR are now passed as command-line arguments.
# --------------------

def log_conversion_error(input_path, stdout, stderr)
  warn "Error converting '#{File.basename(input_path)}':"
  warn "STDOUT: #{stdout}" unless stdout.empty?
  warn "STDERR: #{stderr}" unless stderr.empty?
end

def convert_video_to_mp3(input_path, output_path)
  # -i: Input file
  # -vn: No video recording
  # -ab 192k: Audio bitrate of 192kbps
  # -y: Overwrite output files without asking
  # Pass argv as an array so filenames containing spaces, ':' or '"' are safe.
  ffmpeg_cmd = ['ffmpeg', '-i', input_path, '-vn', '-ab', '192k', '-y', output_path]

  puts "Converting '#{File.basename(input_path)}' to MP3..."
  stdout, stderr, status = Open3.capture3(*ffmpeg_cmd)

  if status.success?
    puts "Successfully converted '#{File.basename(input_path)}' to '#{File.basename(output_path)}'."
    true
  else
    log_conversion_error(input_path, stdout, stderr)
    false
  end
end

def skip_chat_file?(filename)
  if filename.include?('Chat')
    puts "Skipping '#{filename}' as it contains 'Chat' in its name."
    true
  else
    false
  end
end

def process_file(input_path, dest_dir, processed_count, skipped_count)
  filename = File.basename(input_path)

  return [processed_count, skipped_count + 1] if skip_chat_file?(filename)

  output_path = PodcastToolkit::CLI.output_path_for(input_path, dest_dir)

  return [processed_count, skipped_count + 1] if PodcastToolkit::CLI.skip_existing_output?(input_path, output_path)

  if convert_video_to_mp3(input_path, output_path)
    processed_count += 1
  else
    warn "Failed to convert '#{filename}'. See error messages above."
  end
  [processed_count, skipped_count]
end

def display_summary(processed_count, skipped_count, total_source_files)
  puts "
--- Conversion Summary ---"
  puts "Processed: #{processed_count} files"
  puts "Skipped (already exists or 'Chat' in name): #{skipped_count} files"
  puts "Total video files found in source directory: #{total_source_files}"
  puts 'Completed.'
end

def process_source_directory(source_dir, dest_dir)
  processed_count = 0
  skipped_count = 0
  total_source_files = 0

  Dir.glob(File.join(source_dir, '*')).each do |input_path|
    next unless File.file?(input_path)

    total_source_files += 1
    processed_count, skipped_count = process_file(input_path, dest_dir, processed_count, skipped_count)
  end
  [processed_count, skipped_count, total_source_files]
end

def main
  source_dir, dest_dir = PodcastToolkit::CLI.parse_source_dest_args(
    example: '"/path/to/source_videos" "/path/to/output_mp3s"'
  )
  PodcastToolkit::CLI.validate_source_directory(source_dir)
  PodcastToolkit::CLI.ensure_destination_directory(dest_dir)

  processed_count, skipped_count, total_source_files = process_source_directory(source_dir, dest_dir)

  display_summary(processed_count, skipped_count, total_source_files)
end

main if __FILE__ == $PROGRAM_NAME
