# frozen_string_literal: true

require 'rbconfig'

# Run each test file in its own Ruby process.
#
# This is load-bearing, not stylistic: publish_to_spotify.rb and
# create_notebooklm_notebooks.rb both define PODCAST_NOTE_TITLE and SLEEP_BETWEEN
# (with different values). Loading both scripts into a single Minitest process
# would raise "already initialized constant" warnings and make behaviour depend
# on load order. One process per test file sidesteps that until the shared lib
# (Phase 3) makes the constants single-source.
task :test do
  files = Dir['test/*_test.rb'].sort
  if files.empty?
    puts 'No test files found under test/.'
    next
  end
  failures = files.reject { |f| system(RbConfig.ruby, f) }
  abort("\nFailing test files:\n#{failures.map { |f| "  #{f}" }.join("\n")}") unless failures.empty?
end

task default: :test
