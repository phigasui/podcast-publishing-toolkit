# frozen_string_literal: true

require 'fileutils'
require 'open3' # For better command execution and error handling

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
  ffmpeg_cmd = "ffmpeg -i \"#{input_path}\" -vn -ab 192k -y \"#{output_path}\""

  puts "Converting '#{File.basename(input_path)}' to MP3..."
  stdout, stderr, status = Open3.capture3(ffmpeg_cmd)

  if status.success?
    puts "Successfully converted '#{File.basename(input_path)}' to '#{File.basename(output_path)}'."
    true
  else
    log_conversion_error(input_path, stdout, stderr)
    false
  end
end

def parse_arguments
  if ARGV.length != 2
    warn "Usage: ruby #{$PROGRAM_NAME} <SOURCE_DIRECTORY> <DESTINATION_DIRECTORY>"
    warn "Example: ruby #{$PROGRAM_NAME} \"/path/to/source_videos\" \"/path/to/output_mp3s\""
    exit(1)
  end
  [ARGV[0], ARGV[1]]
end

def validate_source_directory(source_dir)
  return if File.directory?(source_dir)

  warn "Error: Source directory not found: #{source_dir}"
  exit(1)
end

def ensure_destination_directory(dest_dir)
  return if File.directory?(dest_dir)

  puts "Destination directory '#{dest_dir}' does not exist. Creating it..."
  begin
    FileUtils.mkdir_p(dest_dir)
    puts "Successfully created destination directory: #{dest_dir}"
  rescue StandardError => e
    warn "Error creating destination directory '#{dest_dir}': #{e.message}"
    exit(1)
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

def skip_existing_output?(input_path, output_path)
  if File.exist?(output_path)
    warn "Skipping '#{File.basename(input_path)}' as '#{File.basename(output_path)}' already exists in destination."
    true
  else
    false
  end
end

def generate_output_path(input_path, dest_dir)
  filename = File.basename(input_path)
  name = File.basename(filename, '.*') # Get filename without any extension
  output_filename = "#{name}.mp3"
  File.join(dest_dir, output_filename)
end

def process_file(input_path, dest_dir, processed_count, skipped_count)
  filename = File.basename(input_path)

  return [processed_count, skipped_count + 1] if skip_chat_file?(filename)

  output_path = generate_output_path(input_path, dest_dir)

  return [processed_count, skipped_count + 1] if skip_existing_output?(input_path, output_path)

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
  source_dir, dest_dir = parse_arguments
  validate_source_directory(source_dir)
  ensure_destination_directory(dest_dir)

  processed_count, skipped_count, total_source_files = process_source_directory(source_dir, dest_dir)

  display_summary(processed_count, skipped_count, total_source_files)
end

main if __FILE__ == $PROGRAM_NAME
