# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'

# Audacity で行っていた Podcast 公開向けのマスタリング処理を ffmpeg で再現する。
#
# - Truncate Silence: silencedetect で無音区間を検出し、atrim + afade + concat で
#   切り貼りすることで、Audacity 同様にカット境界へ短いフェードを入れる
#   （ffmpeg の silenceremove は境界フェードを入れずクリックノイズが出やすいため不採用）
#   しきい値 -35dB / 1秒以上の無音を 0.5秒に短縮
# - Compressor: threshold -10dB, ratio 10, knee 5dB, attack 30ms, release 150ms, makeup 0dB
#   ※ Audacity の Lookahead 1ms は acompressor に対応するパラメータがないため省略
# - Loudness Normalization: -23 LUFS (EBU R128) を 2-pass で精密適用

LOUDNESS_TARGET_LUFS = -23.0
LOUDNESS_TRUE_PEAK_DBFS = -2.0
LOUDNESS_LRA = 7.0

SILENCE_THRESHOLD_DB = -35
SILENCE_DURATION_SEC = 1.5
SILENCE_TRUNCATE_TO_SEC = 1.0
SEGMENT_FADE_SEC = 0.005 # 切り貼り境界のフェード長 (5ms)

COMP_THRESHOLD_DB = -10
COMP_RATIO = 10
COMP_KNEE_DB = 5
COMP_ATTACK_MS = 30
COMP_RELEASE_MS = 150
COMP_MAKEUP_DB = 0

MP3_BITRATE = '192k'

AUDIO_EXTENSIONS = %w[.mp3 .wav .m4a .flac .aac].freeze

def db_to_linear(db)
  10**(db / 20.0)
end

def acompressor_filter
  threshold = format('%.6f', db_to_linear(COMP_THRESHOLD_DB))
  makeup = format('%.6f', db_to_linear(COMP_MAKEUP_DB))
  "acompressor=threshold=#{threshold}:ratio=#{COMP_RATIO}" \
    ":attack=#{COMP_ATTACK_MS}:release=#{COMP_RELEASE_MS}" \
    ":knee=#{COMP_KNEE_DB}:makeup=#{makeup}"
end

def loudnorm_analyze_filter
  "loudnorm=I=#{LOUDNESS_TARGET_LUFS}:TP=#{LOUDNESS_TRUE_PEAK_DBFS}" \
    ":LRA=#{LOUDNESS_LRA}:print_format=json"
end

def loudnorm_apply_filter(measurements)
  "loudnorm=I=#{LOUDNESS_TARGET_LUFS}:TP=#{LOUDNESS_TRUE_PEAK_DBFS}" \
    ":LRA=#{LOUDNESS_LRA}" \
    ":measured_I=#{measurements['input_i']}" \
    ":measured_TP=#{measurements['input_tp']}" \
    ":measured_LRA=#{measurements['input_lra']}" \
    ":measured_thresh=#{measurements['input_thresh']}" \
    ":offset=#{measurements['target_offset']}" \
    ':linear=true:print_format=summary'
end

def parse_arguments
  if ARGV.length != 2
    warn "Usage: ruby #{$PROGRAM_NAME} <SOURCE_DIRECTORY> <DESTINATION_DIRECTORY>"
    warn "Example: ruby #{$PROGRAM_NAME} \"./mp3s\" \"./mastered\""
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

def get_audio_duration(input_path)
  cmd = [
    'ffprobe', '-v', 'error',
    '-show_entries', 'format=duration',
    '-of', 'default=noprint_wrappers=1:nokey=1',
    input_path
  ]
  stdout, _stderr, status = Open3.capture3(*cmd)
  return nil unless status.success?

  stdout.strip.to_f
end

def detect_silence_periods(input_path)
  cmd = [
    'ffmpeg', '-hide_banner', '-nostats',
    '-i', input_path,
    '-af', "silencedetect=noise=#{SILENCE_THRESHOLD_DB}dB:duration=#{SILENCE_DURATION_SEC}",
    '-f', 'null', '-'
  ]
  _stdout, stderr, status = Open3.capture3(*cmd)
  unless status.success?
    warn "silencedetect failed for '#{File.basename(input_path)}':"
    warn stderr
    return nil
  end

  starts = stderr.scan(/silence_start:\s*(-?\d+(?:\.\d+)?)/).flatten.map(&:to_f)
  ends = stderr.scan(/silence_end:\s*(-?\d+(?:\.\d+)?)/).flatten.map(&:to_f)
  starts.zip(ends).reject { |s, e| s.nil? || e.nil? }
end

# 検出された無音区間 [s, e] (e-s >= duration) のうち、
# 中央 truncate_to 秒だけ残し両側を削除する区間を返す
def silence_to_cut_ranges(silence_periods, truncate_to)
  silence_periods.filter_map do |s, e|
    next nil if (e - s) <= truncate_to

    half_keep = truncate_to / 2.0
    [s + half_keep, e - half_keep]
  end
end

# 削除区間を total_duration から取り除いた残り（保持区間）を返す
def keep_ranges_from_cuts(cut_ranges, total_duration)
  ranges = []
  prev_end = 0.0
  cut_ranges.each do |cs, ce|
    ranges << [prev_end, cs] if cs > prev_end
    prev_end = ce
  end
  ranges << [prev_end, total_duration] if prev_end < total_duration
  ranges.select { |s, e| (e - s) > 0.001 }
end

def keep_segment_filter(input_label, output_label, start_t, end_t)
  seg_dur = end_t - start_t
  fade_out_st = [seg_dur - SEGMENT_FADE_SEC, 0].max
  "#{input_label}atrim=start=#{format('%.6f', start_t)}:end=#{format('%.6f', end_t)}," \
    'asetpts=PTS-STARTPTS,' \
    "afade=t=in:st=0:d=#{SEGMENT_FADE_SEC}," \
    "afade=t=out:st=#{format('%.6f', fade_out_st)}:d=#{SEGMENT_FADE_SEC}#{output_label}"
end

# 各保持区間を atrim で切り出し、境界に短いフェードを掛けて concat する
# フィルタグラフを構築する。最終ラベルは [trimmed]
def build_keep_filter_graph(keep_ranges)
  return nil if keep_ranges.empty?

  n = keep_ranges.size
  if n == 1
    s, e = keep_ranges.first
    return keep_segment_filter('[0:a]', '[trimmed]', s, e)
  end

  parts = []
  split_labels = (0...n).map { |i| "[s#{i}]" }.join
  parts << "[0:a]asplit=#{n}#{split_labels}"

  keep_ranges.each_with_index do |(s, e), i|
    parts << keep_segment_filter("[s#{i}]", "[a#{i}]", s, e)
  end

  concat_inputs = (0...n).map { |i| "[a#{i}]" }.join
  parts << "#{concat_inputs}concat=n=#{n}:v=0:a=1[trimmed]"
  parts.join(';')
end

def extract_loudnorm_json(stderr_output)
  start_idx = stderr_output.rindex('{')
  end_idx = stderr_output.rindex('}')
  return nil unless start_idx && end_idx && start_idx < end_idx

  stderr_output[start_idx..end_idx]
end

def filter_complex_for_processing(keep_filter_graph, tail_filter)
  if keep_filter_graph
    "#{keep_filter_graph};[trimmed]#{acompressor_filter},#{tail_filter}[out]"
  else
    "[0:a]#{acompressor_filter},#{tail_filter}[out]"
  end
end

def run_ffmpeg_filter_complex(input_path, filter_complex, *output_args)
  cmd = [
    'ffmpeg', '-hide_banner', '-nostats',
    '-i', input_path,
    '-filter_complex', filter_complex,
    '-map', '[out]',
    *output_args
  ]
  Open3.capture3(*cmd)
end

def analyze_loudness(input_path, keep_filter_graph)
  filter = filter_complex_for_processing(keep_filter_graph, loudnorm_analyze_filter)
  _stdout, stderr, status = run_ffmpeg_filter_complex(input_path, filter, '-f', 'null', '-')
  unless status.success?
    warn "Loudness analysis failed for '#{File.basename(input_path)}':"
    warn stderr
    return nil
  end

  json_str = extract_loudnorm_json(stderr)
  unless json_str
    warn "Could not locate loudnorm JSON in ffmpeg output for '#{File.basename(input_path)}'."
    return nil
  end

  JSON.parse(json_str)
rescue JSON::ParserError => e
  warn "JSON parse error for '#{File.basename(input_path)}': #{e.message}"
  nil
end

def apply_processing(input_path, output_path, keep_filter_graph, measurements)
  filter = filter_complex_for_processing(keep_filter_graph, loudnorm_apply_filter(measurements))
  _stdout, stderr, status = run_ffmpeg_filter_complex(
    input_path, filter,
    '-ab', MP3_BITRATE,
    '-y', output_path
  )
  unless status.success?
    warn "Processing failed for '#{File.basename(input_path)}':"
    warn stderr
    return false
  end
  true
end

def skip_existing_output?(input_path, output_path)
  return false unless File.exist?(output_path)

  warn "Skipping '#{File.basename(input_path)}' as '#{File.basename(output_path)}' already exists in destination."
  true
end

def output_path_for(input_path, dest_dir)
  name = File.basename(input_path, '.*')
  File.join(dest_dir, "#{name}.mp3")
end

def compute_keep_filter_graph(input_path)
  duration = get_audio_duration(input_path)
  return nil unless duration

  silence_periods = detect_silence_periods(input_path)
  return nil unless silence_periods

  cut_ranges = silence_to_cut_ranges(silence_periods, SILENCE_TRUNCATE_TO_SEC)
  keep_ranges = keep_ranges_from_cuts(cut_ranges, duration)
  total_kept = keep_ranges.sum { |s, e| e - s }

  puts "      detected #{silence_periods.size} silence periods, " \
       "cutting #{cut_ranges.size}, " \
       "keeping #{format('%.1f', total_kept)}s of #{format('%.1f', duration)}s"

  build_keep_filter_graph(keep_ranges)
end

def process_file(input_path, dest_dir)
  filename = File.basename(input_path)
  output_path = output_path_for(input_path, dest_dir)

  return :skipped if skip_existing_output?(input_path, output_path)

  puts "[1/3] Detecting silence: '#{filename}'..."
  keep_filter_graph = compute_keep_filter_graph(input_path)

  puts "[2/3] Analyzing loudness: '#{filename}'..."
  measurements = analyze_loudness(input_path, keep_filter_graph)
  return :failed unless measurements

  puts "      input_i=#{measurements['input_i']} LUFS, " \
       "input_tp=#{measurements['input_tp']} dBTP, " \
       "target_offset=#{measurements['target_offset']} dB"
  puts "[3/3] Applying filters: '#{filename}' -> '#{File.basename(output_path)}'..."
  return :failed unless apply_processing(input_path, output_path, keep_filter_graph, measurements)

  puts "Done: '#{File.basename(output_path)}'"
  :processed
end

def audio_file?(path)
  File.file?(path) && AUDIO_EXTENSIONS.include?(File.extname(path).downcase)
end

def process_source_directory(source_dir, dest_dir)
  counts = { processed: 0, skipped: 0, failed: 0, total: 0 }
  Dir.glob(File.join(source_dir, '*')).sort.each do |path|
    next unless audio_file?(path)

    counts[:total] += 1
    result = process_file(path, dest_dir)
    counts[result] += 1
  end
  counts
end

def display_summary(counts)
  puts "\n--- Mastering Summary ---"
  puts "Processed: #{counts[:processed]} files"
  puts "Skipped (already exists): #{counts[:skipped]} files"
  puts "Failed:    #{counts[:failed]} files"
  puts "Total audio files found:  #{counts[:total]}"
  puts 'Completed.'
end

def main
  source_dir, dest_dir = parse_arguments
  validate_source_directory(source_dir)
  ensure_destination_directory(dest_dir)

  counts = process_source_directory(source_dir, dest_dir)
  display_summary(counts)
end

main if __FILE__ == $PROGRAM_NAME
