# frozen_string_literal: true

require 'fileutils'

module PodcastToolkit
  # Command-line and directory helpers shared by the source→dest batch scripts
  # (convert_meet_recordings.rb, master_for_podcast.rb).
  module CLI
    module_function

    # Parse the common "<SOURCE_DIR> <DEST_DIR>" argument pair, printing usage
    # and exiting when the arguments are wrong. `example` is the argument
    # portion shown on the Example line (e.g. '"./mp3s" "./mastered"').
    def parse_source_dest_args(example:)
      if ARGV.length != 2
        warn "Usage: ruby #{$PROGRAM_NAME} <SOURCE_DIRECTORY> <DESTINATION_DIRECTORY>"
        warn "Example: ruby #{$PROGRAM_NAME} #{example}"
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
      FileUtils.mkdir_p(dest_dir)
      puts "Successfully created destination directory: #{dest_dir}"
    rescue StandardError => e
      warn "Error creating destination directory '#{dest_dir}': #{e.message}"
      exit(1)
    end

    def skip_existing_output?(input_path, output_path)
      return false unless File.exist?(output_path)

      warn "Skipping '#{File.basename(input_path)}' as " \
           "'#{File.basename(output_path)}' already exists in destination."
      true
    end

    # Build the destination path for an input file, replacing its extension.
    def output_path_for(input_path, dest_dir, ext: '.mp3')
      name = File.basename(input_path, '.*')
      File.join(dest_dir, "#{name}#{ext}")
    end
  end
end
