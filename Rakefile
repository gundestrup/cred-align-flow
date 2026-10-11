# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |task|
  task.libs << "lib" << "test"
  task.pattern = "test/*_test.rb"
end

desc "Run env-gated disposable-service tests (test/integration; not part of check)"
Rake::TestTask.new("test:integration") do |task|
  task.libs << "lib" << "test"
  task.pattern = "test/integration/*_test.rb"
end

desc "Run Ruby linting"
task :rubocop do
  sh "bundle exec rubocop"
end

desc "Audit gem dependencies for known CVEs (bundler-audit)"
task :audit do
  # `--update` refreshes the ruby-advisory-db (public git repo) so the
  # task also works on a fresh machine or CI runner without a cached DB.
  sh "bundle exec bundler-audit check --update"
end

desc "Report structural duplication (flay; informational, never fails)"
task :flay do
  sh "bundle exec flay --summary lib test" do |ok, _res|
    puts "flay reported structural duplication (informational only)" unless ok
  end
end

desc "Report per-method complexity (flog; informational, never fails)"
task :flog do
  sh "bundle exec flog -m lib" do |ok, _res|
    puts "flog reported complexity (informational only)" unless ok
  end
end

desc "Run Semgrep security scan (skipped when semgrep is not installed, unless SEMGREP_REQUIRED=1)"
task :semgrep do
  if system("command -v semgrep > /dev/null")
    # CE/OSS only: repo-local rules in .semgrep.yml, no registry packs
    # (p/* bundles Pro rules — not licensed for private repos), no
    # login, no upload, no metrics.
    sh "semgrep scan --config .semgrep.yml --oss-only --metrics off " \
       "--disable-version-check --error --quiet lib/ bin/ Rakefile"
  elsif ENV["SEMGREP_REQUIRED"] == "1"
    abort "semgrep is required (SEMGREP_REQUIRED=1) but not installed"
  else
    puts "semgrep not installed — skipping (brew install semgrep)"
  end
end

desc "Run all checks"
task check: %i[test rubocop audit flay flog semgrep]

task default: :check
