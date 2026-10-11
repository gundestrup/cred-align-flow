# frozen_string_literal: true

source "https://rubygems.org"

ruby ">= 3.4.10"

group :development, :test do
  gem "bundler-audit", require: false # gem CVE audit: bundle exec bundler-audit check --update
  gem "flay", require: false # structural duplication report: bundle exec rake flay
  gem "flog", require: false # per-method complexity report: bundle exec rake flog
  gem "minitest", "~> 6.0"
  gem "rake", "~> 13.2"
  gem "rubocop", "~> 1.89", require: false
  gem "rubocop-minitest", require: false
  gem "rubocop-rake", require: false
  gem "ruby-lsp", require: false
  gem "simplecov", require: false # coverage report for SonarCloud import (coverage/coverage.json)
end

gem "itsi", "~> 0.2.27", group: :development
