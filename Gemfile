# frozen_string_literal: true

source 'https://rubygems.org'

# Runtime deps are otherwise Ruby stdlib (open3, json, uri, yaml, fileutils,
# set, erb, time) plus external CLIs (ffmpeg, ffprobe, nlm, aws). rexml is the
# one exception: as of Ruby 3.4 it is a bundled gem rather than a default gem,
# so publish_to_spotify.rb's `require 'rexml/document'` must be declared here to
# work under `bundle exec`.
gem 'rexml', '~> 3.2'

group :development, :test do
  gem 'minitest', '~> 5.0'
  gem 'rake', '~> 13.0'
end
