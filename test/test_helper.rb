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

# Deterministic fingerprint key for in-process tests so digests are
# reproducible; CLI subprocess fixtures pass an isolated key through ENV.
CredAlignFlow::Fingerprint.key = "test-only fingerprint key"

# In-process tests must not see ambient credential variables — a CI
# SONAR_TOKEN or a developer's GH_TOKEN would otherwise resolve through
# the env fallbacks and corrupt fixtures. Subprocess fixtures pass their
# own isolated ENV, so this only affects the test process itself.
CredAlignFlow.environment = {}

module TestSupport
  def self.run_cli(fake_gh, *, environment_overrides: {})
    environment = fake_gh.environment.merge(environment_overrides)
    if defined?(SimpleCov)
      # Subprocess coverage: bin/cred-align-flow starts SimpleCov when this is
      # set; distinct command names let the parent's resultset merge it in.
      environment["CRED_ALIGN_FLOW_SIMPLECOV"] = "1"
      # The stripped environment must still resolve simplecov: CI installs the
      # bundle outside the default gem path (bundler-cache), so pass the
      # bundler/gem lookup variables through or the subprocess silently runs
      # uninstrumented.
      ENV.each { |key, value| environment[key] = value if key.start_with?("BUNDLE_", "GEM_") }
      %w[RUBYLIB RUBYOPT].each { |key| environment[key] = ENV[key] if ENV.key?(key) }
    end
    executable = File.expand_path("../bin/cred-align-flow", __dir__)
    Open3.capture3(
      environment,
      RbConfig.ruby,
      "-r",
      fake_gh.network_guard_path,
      executable,
      *,
      unsetenv_others: true
    )
  end

  # Shared repository-metadata fixture in the providers' normalized shape;
  # merge overrides for variants such as private or explicitly included repos.
  REPOSITORY_METADATA = {
    "id" => "4242",
    "databaseId" => 4242,
    "name" => "repo",
    "nameWithOwner" => "example/repo",
    "visibility" => "PUBLIC",
    "isPrivate" => false,
    "isArchived" => false,
    "isFork" => false,
    "viewerCanAdminister" => true
  }.freeze

  def self.repository_metadata(overrides = {})
    REPOSITORY_METADATA.merge(overrides)
  end

  # Commits a source snapshot through the same apply_refresh entry point the
  # inventory uses; entries keep provider metadata plus the flags the
  # planner and UI read.
  def self.seed_source(state, source_id, repositories: [REPOSITORY_METADATA],
                       contexts: nil, selection: nil, remote_secrets: {})
    entries = repositories.each_with_object({}) do |repo, map|
      name = repo["nameWithOwner"] || repo["name_with_owner"]
      map[name] = repo.merge(
        "name_with_owner" => name,
        "selected" => repo.fetch("selected", true),
        "explicit" => repo.fetch("explicit", false),
        "admin" => repo.fetch("viewerCanAdminister", true) == true,
        "remote_secrets" => remote_secrets.fetch(name, {})
      )
    end
    state.apply_refresh(
      source_id,
      repositories: entries,
      contexts: contexts,
      selection: selection || { "identity" => "test|identity" },
      discovered_at: Time.now.utc.iso8601
    )
  end

  class FakeGh
    DEFAULT_REPOSITORIES = [REPOSITORY_METADATA].freeze

    attr_reader :bin_dir, :network_guard_path, :state_path
    attr_accessor :expected_github_token, :expected_enterprise_token

    def initialize(directory, repositories: DEFAULT_REPOSITORIES, secrets: {}, expected_secret: "", expected_token: "",
                   expected_github_token: nil, expected_enterprise_token: nil)
      @bin_dir = File.join(directory, "bin")
      @network_guard_path = File.join(directory, "network_guard.rb")
      @state_path = File.join(directory, "fake-gh-state.json")
      @home_dir = File.join(directory, "home")
      @expected_secret = expected_secret
      @expected_github_token = expected_github_token.nil? ? expected_token : expected_github_token
      @expected_enterprise_token = expected_enterprise_token.nil? ? expected_token : expected_enterprise_token
      FileUtils.mkdir_p(@bin_dir)
      FileUtils.mkdir_p(@home_dir)
      File.write(@state_path, JSON.generate(
                                "repositories" => repositories,
                                "secrets" => secrets,
                                "calls" => []
                              ))
      create_network_guard
      create_executable
    end

    def environment
      {
        "PATH" => @bin_dir,
        "HOME" => @home_dir,
        "XDG_CONFIG_HOME" => File.join(@home_dir, ".config"),
        "GH_CONFIG_DIR" => File.join(@home_dir, ".config", "gh"),
        "GH_PROMPT_DISABLED" => "1",
        "FAKE_GH_STATE" => @state_path,
        "FAKE_GH_EXPECTED_SECRET" => @expected_secret,
        "FAKE_GH_EXPECTED_GITHUB_TOKEN" => @expected_github_token,
        "FAKE_GH_EXPECTED_ENTERPRISE_TOKEN" => @expected_enterprise_token
      }
    end

    def calls
      state.fetch("calls")
    end

    def state
      JSON.parse(File.read(@state_path))
    end

    private

    def create_network_guard
      File.write(@network_guard_path, <<~RUBY)
        # frozen_string_literal: true

        require "socket"

        module CredAlignFlowOfflineTestNetworkBlock
          def connect(*)
            raise IOError, "network disabled by offline test harness"
          end

          def connect_nonblock(*)
            raise IOError, "network disabled by offline test harness"
          end
        end

        BasicSocket.prepend(CredAlignFlowOfflineTestNetworkBlock)

        module CredAlignFlowOfflineTestSocketConstructionBlock
          def initialize(*)
            raise IOError, "network disabled by offline test harness"
          end
        end

        TCPSocket.prepend(CredAlignFlowOfflineTestSocketConstructionBlock)
        UDPSocket.prepend(CredAlignFlowOfflineTestSocketConstructionBlock)

        class << Socket
          def tcp(*)
            raise IOError, "network disabled by offline test harness"
          end
        end
      RUBY
    end

    def create_executable
      script = <<~'RUBY'
        # frozen_string_literal: true

        require "json"

        state_path = ENV.fetch("FAKE_GH_STATE")
        state = JSON.parse(File.read(state_path))
        arguments = ARGV
        result = nil
        json_output = true
        exit_status = 0
        stdin_matches_expected = nil
        option_value = lambda do |name|
          index = arguments.index(name)
          index && arguments[index + 1]
        end

        case arguments
        when ["--version"]
          result = ENV.fetch("FAKE_GH_VERSION_OUTPUT", "gh version 2.99.0 (test-only)\n")
          json_output = false
        else
          case arguments.first(2)
          when ["auth", "status"]
            json_output = false
            if ENV["FAKE_GH_AUTH_FAIL"] == "1"
              result = "synthetic authentication failure\n"
              exit_status = 1
            else
              result = "authenticated\n"
            end
          when ["repo", "list"]
            owner = arguments.fetch(2)
            result = state.fetch("repositories").select do |repo|
              repo.fetch("nameWithOwner").split("/", 2).first.casecmp?(owner)
            end
          when ["repo", "view"]
            name = arguments.fetch(2)
            result = state.fetch("repositories").find do |repo|
              repo.fetch("nameWithOwner").casecmp?(name)
            end
            raise "fake gh has no metadata for requested repository" unless result
          when ["secret", "list"]
            key = [option_value.call("--repo"), option_value.call("--app")].join("|")
            result = state.fetch("secrets").fetch(key, [])
          when ["secret", "set"]
            repository = option_value.call("--repo")
            context = option_value.call("--app")
            name = arguments.fetch(2)
            stdin_value = STDIN.read
            if ENV["FAKE_GH_FAIL_WRITE"] == "1"
              STDERR.write("#{ENV['GH_TOKEN']}#{stdin_value}")
              exit_status = 1
            else
              stdin_matches_expected = stdin_value == ENV.fetch("FAKE_GH_EXPECTED_SECRET", "")
              raise "fake gh received unexpected standard input" unless stdin_matches_expected

              key = [repository, context].join("|")
              entries = state.fetch("secrets")[key] ||= []
              entries.reject! { |entry| entry.fetch("name") == name }
              entries << { "name" => name, "updatedAt" => "2026-01-02T00:00:00Z" }
            end
          when ["secret", "delete"]
            if ENV["FAKE_GH_FAIL_DELETE"] == "1"
              result = "synthetic delete failure\n"
              json_output = false
              exit_status = 1
            else
              key = [option_value.call("--repo"), option_value.call("--app")].join("|")
              entries = state.fetch("secrets").fetch(key, [])
              entries.reject! { |entry| entry.fetch("name") == arguments.fetch(2) }
              result = ""
              json_output = false
            end
          else
            raise "unexpected fake gh arguments"
          end
        end

        if (config_path = ENV["FAKE_GH_MUTATE_CONFIG"]) && !state["config_mutated"]
          File.open(config_path, "a") { |file| file.write("# synthetic concurrent edit\n") }
          state["config_mutated"] = true
        end
        state.fetch("calls") << {
          "arguments" => arguments,
          "host" => ENV["GH_HOST"],
          "token_matches_expected" => ENV["GH_TOKEN"].to_s == ENV.fetch("FAKE_GH_EXPECTED_GITHUB_TOKEN", ""),
          "enterprise_token_matches_expected" => ENV["GH_ENTERPRISE_TOKEN"].to_s == ENV.fetch("FAKE_GH_EXPECTED_ENTERPRISE_TOKEN", ""),
          "stdin_matches_expected" => stdin_matches_expected
        }
        File.write(state_path, JSON.generate(state))
        STDOUT.write(json_output ? JSON.generate(result) : result) unless result.nil?
        exit exit_status
      RUBY

      executable = File.join(@bin_dir, "gh")
      File.write(executable, "#!#{RbConfig.ruby}\n#{script}")
      FileUtils.chmod(0o700, executable)
    end
  end
end
