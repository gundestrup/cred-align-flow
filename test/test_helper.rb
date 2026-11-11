# frozen_string_literal: true

begin
  require "simplecov"

  SimpleCov.start do
    skip "/test/"
    formatter SimpleCov::Formatter::MultiFormatter.new(
      [SimpleCov::Formatter::HTMLFormatter, SimpleCov::Formatter::JSONFormatter]
    )
  end
rescue LoadError
  # Coverage is a development-only dependency; tests must still run via
  # `ruby -Ilib -Itest` without bundler.
end

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "time"
require "tmpdir"

require "cred_align_flow"

# Fixture machinery shared with the demo screencast tooling; lives in
# test/support/ so scripts/e2e can load it without minitest/simplecov.
require_relative "support/fixtures"
