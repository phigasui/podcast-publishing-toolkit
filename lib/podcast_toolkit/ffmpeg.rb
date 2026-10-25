# frozen_string_literal: true

require 'open3'

module PodcastToolkit
  # Thin wrappers around the ffmpeg/ffprobe CLIs.
  module FFmpeg
    module_function

    # Return the duration of an audio/video file in seconds via ffprobe, or nil
    # if ffprobe fails.
    def audio_duration(path)
      cmd = [
        'ffprobe', '-v', 'error',
        '-show_entries', 'format=duration',
        '-of', 'default=noprint_wrappers=1:nokey=1',
        path
      ]
      stdout, _stderr, status = Open3.capture3(*cmd)
      return nil unless status.success?

      stdout.strip.to_f
    end
  end
end
