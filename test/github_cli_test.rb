# frozen_string_literal: true

require_relative "test_helper"
require "yaml"

class GitHubCliTest < Minitest::Test
  TEST_SECRET_VALUE = "synthetic-test-payload"
  TEST_AUTH_TOKEN = "synthetic-test-auth-token"

  def test_pull_uses_expected_gh_commands_and_keeps_contexts_separate
    with_workspace(contexts: %w[actions dependabot]) do |workspace|
      stdout, stderr, status = invoke(workspace, "pull", "--source", "github-main")

      assert_predicate status, :success?, stderr
      calls = workspace.fetch(:fake_gh).calls
      repo_call = calls.find { |call| call.fetch("arguments").first(2) == %w[repo list] }
      secret_calls = calls.select { |call| call.fetch("arguments").first(2) == %w[secret list] }

      assert_equal(
        ["repo", "list", "example", "--limit", "1000", "--json",
         "name,nameWithOwner,id,isPrivate,isArchived,isFork,visibility,viewerCanAdminister"],
        repo_call.fetch("arguments")
      )
      assert_equal(
        [
          ["secret", "list", "--repo", "example/repo", "--app", "actions", "--json", "name,updatedAt"],
          ["secret", "list", "--repo", "example/repo", "--app", "dependabot", "--json", "name,updatedAt"]
        ],
        secret_calls.map { |call| call.fetch("arguments") }
      )
      assert(secret_calls.all? { |call| call.fetch("token_matches_expected") })
      refute(calls.any? { |call| call.fetch("arguments").first(2) == %w[secret set] })
      refute_includes stdout + stderr, TEST_SECRET_VALUE
      refute_includes stdout + stderr, TEST_AUTH_TOKEN
      refute_includes File.read(workspace.fetch(:state_path)), TEST_SECRET_VALUE
      refute_includes File.read(workspace.fetch(:state_path)), TEST_AUTH_TOKEN
    end
  end

  def test_github_secret_value_limit_matches_provider_limit
    provider = CredAlignFlow::Providers::GitHub.new(
      { "type" => "github", "owner" => "example", "api_url" => "https://github.com" },
      {}
    )

    assert_equal 48 * 1024, CredAlignFlow::Providers::GitHub::MAX_SECRET_VALUE_BYTES
    assert_raises(CredAlignFlow::ProviderError) do
      provider.set_secret("example/repo", "actions", "SYNC_TOKEN", "x" * ((48 * 1024) + 1))
    end
  end

  def test_github_repo_list_drains_large_subprocess_output
    repositories = Array.new(1_000) do |index|
      repository_metadata("example", "example/repo-#{index}")
    end
    with_workspace(contexts: ["actions"], repositories: repositories) do |workspace|
      lib_path = File.expand_path("../lib", __dir__)
      script = <<~RUBY
        require "cred_align_flow"
        provider = CredAlignFlow::Providers::GitHub.new(
          { "type" => "github", "owner" => "example", "api_url" => "https://github.com", "auth_env" => "GITHUB_TEST_AUTH" },
          { "GITHUB_TEST_AUTH" => ENV.fetch("GITHUB_TEST_AUTH") }
        )
        puts provider.repositories.length.to_s + ":" + provider.truncated?.to_s
      RUBY
      environment = workspace.fetch(:fake_gh).environment.merge("GITHUB_TEST_AUTH" => TEST_AUTH_TOKEN)
      stdout, stderr, status = Open3.capture3(
        environment, RbConfig.ruby, "-I", lib_path, "-e", script, unsetenv_others: true
      )

      assert_predicate status, :success?, stderr
      assert_equal "1000:true", stdout.strip
    end
  end

  def test_enterprise_source_uses_enterprise_host_and_token_environment
    with_workspace(api_url: "https://ghe.example.test/api/v3", contexts: ["actions"]) do |workspace|
      stdout, stderr, status = invoke(workspace, "pull")

      assert_predicate status, :success?, stderr
      assert_equal "ghe.example.test", workspace.fetch(:fake_gh).calls.first.fetch("host")
      assert(workspace.fetch(:fake_gh).calls.all? { |call| call.fetch("enterprise_token_matches_expected") })
      refute(workspace.fetch(:fake_gh).calls.any? { |call| call.fetch("token_matches_expected") })
      refute_includes stdout + stderr, TEST_AUTH_TOKEN
    end
  end

  def test_github_api_url_uses_github_com_authentication
    with_workspace(api_url: "https://api.github.com", contexts: ["actions"]) do |workspace|
      stdout, stderr, status = invoke(workspace, "pull")

      assert_predicate status, :success?, stderr
      assert(workspace.fetch(:fake_gh).calls.all? { |call| call.fetch("token_matches_expected") })
      refute(workspace.fetch(:fake_gh).calls.any? { |call| call.fetch("enterprise_token_matches_expected") })
      refute_includes stdout + stderr, TEST_AUTH_TOKEN
    end
  end

  def test_enterprise_cloud_source_uses_github_token
    with_workspace(api_url: "https://api.acme.ghe.com", contexts: ["actions"]) do |workspace|
      _stdout, stderr, status = invoke(workspace, "pull")

      assert_predicate status, :success?, stderr
      assert_equal "acme.ghe.com", workspace.fetch(:fake_gh).calls.first.fetch("host")
      assert(workspace.fetch(:fake_gh).calls.all? { |call| call.fetch("token_matches_expected") })
      refute(workspace.fetch(:fake_gh).calls.any? { |call| call.fetch("enterprise_token_matches_expected") })
    end
  end

  def test_explicit_include_checks_only_the_named_repository_metadata
    with_workspace(contexts: ["actions"], include_repositories: ["example/repo"]) do |workspace|
      stdout, stderr, status = invoke(workspace, "pull")

      assert_predicate status, :success?, stderr
      calls = workspace.fetch(:fake_gh).calls
      repo_view = calls.find { |call| call.fetch("arguments").first(2) == %w[repo view] }

      expected_view = %w[repo view example/repo --json
                         name,nameWithOwner,id,isPrivate,isArchived,isFork,visibility,viewerCanAdminister]

      assert_equal expected_view, repo_view.fetch("arguments")

      refute(calls.any? { |call| call.fetch("arguments").first(2) == %w[repo list] })
      secret_list_call = calls.find { |call| call.fetch("arguments").first(2) == %w[secret list] }

      assert_equal "example/repo", secret_list_call.fetch("arguments")[3]
      refute_includes stdout + stderr, TEST_AUTH_TOKEN
    end
  end

  def test_explicit_private_repo_is_not_targeted_by_public_secret
    repositories = [repository_metadata("example", "example/repo").merge("visibility" => "PRIVATE", "isPrivate" => true)]
    with_workspace(
      contexts: ["actions"],
      include_repositories: ["example/repo"],
      secret_visibility: "public",
      repositories: repositories
    ) do |workspace|
      stdout, stderr, status = invoke(workspace, "apply", "--yes")

      assert_predicate status, :success?, stderr
      refute_includes stdout, "create"
      refute_predicate(write_calls(workspace.fetch(:fake_gh)), :any?)
    end
  end

  def test_explicit_repo_with_unknown_status_fails_before_secret_listing_or_write
    repositories = [repository_metadata("example", "example/repo").merge("visibility" => "unknown")]
    with_workspace(contexts: ["actions"], include_repositories: ["example/repo"], repositories: repositories) do |workspace|
      _stdout, stderr, status = invoke(workspace, "apply", "--yes")

      assert_equal 1, status.exitstatus
      assert_includes stderr, "visibility"
      refute(workspace.fetch(:fake_gh).calls.any? { |call| call.fetch("arguments").first(2) == %w[secret list] })
      refute_predicate(write_calls(workspace.fetch(:fake_gh)), :any?)
    end
  end

  def test_multiple_github_sources_use_separate_auth_and_shared_secret_value
    enterprise_source = {
      "type" => "github",
      "owner" => "enterprise",
      "api_url" => "https://ghe.example.test/api/v3",
      "auth_env" => "GITHUB_ENTERPRISE_TEST_AUTH",
      "repositories" => { "visibility" => "all" }
    }
    repositories = [
      repository_metadata("personal", "example/repo"),
      repository_metadata("enterprise", "enterprise/repo")
    ]

    with_workspace(
      contexts: ["actions"],
      additional_sources: { "github-enterprise" => enterprise_source },
      secret_sources: %w[github-main github-enterprise],
      secret_visibility: "all",
      auth_values: { "GITHUB_ENTERPRISE_TEST_AUTH" => "synthetic-enterprise-auth" },
      repositories: repositories,
      expected_github_token: TEST_AUTH_TOKEN,
      expected_enterprise_token: "synthetic-enterprise-auth"
    ) do |workspace|
      stdout, stderr, status = invoke(workspace, "apply", "--yes")

      assert_predicate status, :success?, stderr
      calls = write_calls(workspace.fetch(:fake_gh))

      assert_equal %w[enterprise/repo example/repo], calls.map { |call| option(call, "--repo") }.sort
      personal = calls.find { |call| option(call, "--repo") == "example/repo" }
      enterprise = calls.find { |call| option(call, "--repo") == "enterprise/repo" }

      assert personal.fetch("token_matches_expected")
      refute personal.fetch("enterprise_token_matches_expected")
      assert enterprise.fetch("enterprise_token_matches_expected")
      refute enterprise.fetch("token_matches_expected")
      assert(calls.all? { |call| call.fetch("stdin_matches_expected") })
      refute_includes stdout + stderr, TEST_AUTH_TOKEN
      refute_includes stdout + stderr, "synthetic-enterprise-auth"
    end
  end

  def test_same_host_github_accounts_use_source_specific_auth_values
    alternate_source = {
      "type" => "github",
      "owner" => "alternate",
      "api_url" => "https://api.github.com",
      "auth_env" => "GITHUB_ALTERNATE_AUTH",
      "repositories" => { "visibility" => "all" }
    }
    repositories = [
      repository_metadata("personal", "example/repo"),
      repository_metadata("alternate", "alternate/repo")
    ]

    with_workspace(
      contexts: ["actions"],
      additional_sources: { "github-alternate" => alternate_source },
      secret_sources: %w[github-main github-alternate],
      secret_visibility: "all",
      auth_values: { "GITHUB_ALTERNATE_AUTH" => "synthetic-alternate-auth" },
      repositories: repositories,
      expected_github_token: TEST_AUTH_TOKEN
    ) do |workspace|
      _stdout, stderr, status = invoke(workspace, "apply", "--source", "github-main", "--yes")

      assert_predicate status, :success?, stderr

      workspace.fetch(:fake_gh).expected_github_token = "synthetic-alternate-auth"
      _stdout, stderr, status = invoke(workspace, "apply", "--source", "github-alternate", "--yes")

      assert_predicate status, :success?, stderr

      calls = write_calls(workspace.fetch(:fake_gh))

      assert_equal %w[alternate/repo example/repo], calls.map { |call| option(call, "--repo") }.sort
      assert(calls.all? { |call| call.fetch("token_matches_expected") })
      refute(calls.any? { |call| call.fetch("enterprise_token_matches_expected") })
    end
  end

  def test_doctor_uses_the_isolated_fake_cli
    with_workspace(contexts: ["actions"]) do |workspace|
      stdout, stderr, status = invoke(workspace, "doctor")

      assert_predicate status, :success?, stderr
      assert_includes stdout, "gh version 2.99.0"
      assert_equal([["--version"]], workspace.fetch(:fake_gh).calls.map { |call| call.fetch("arguments") })
      refute_includes stdout + stderr, TEST_AUTH_TOKEN
    end
  end

  def test_doctor_does_not_echo_untrusted_cli_version_output
    with_workspace(contexts: ["actions"]) do |workspace|
      stdout, stderr, status = invoke(
        workspace,
        "doctor",
        environment_overrides: { "FAKE_GH_VERSION_OUTPUT" => "gh version #{TEST_AUTH_TOKEN}\n" }
      )

      assert_predicate status, :success?, stderr
      assert_includes stdout, "provider CLI unavailable"
      refute_includes stdout + stderr, TEST_AUTH_TOKEN
    end
  end

  def test_doctor_fails_when_a_configured_auth_reference_is_missing
    with_workspace(contexts: ["actions"], auth_values: { "GITHUB_TEST_AUTH" => "" }) do |workspace|
      stdout, stderr, status = invoke(workspace, "doctor")

      assert_equal 1, status.exitstatus, "stdout:\n#{stdout}\nstderr:\n#{stderr}"
      assert_includes stdout, "GITHUB_TEST_AUTH"
      assert_empty workspace.fetch(:fake_gh).calls
      refute_includes stdout + stderr, TEST_AUTH_TOKEN
    end
  end

  def test_cli_workflow_pulls_plans_checks_dry_runs_and_writes_only_to_fake_gh
    with_workspace(contexts: %w[actions dependabot]) do |workspace|
      _stdout, stderr, status = invoke(workspace, "pull")

      assert_predicate status, :success?, stderr

      stdout, stderr, status = invoke(workspace, "plan", "--offline")

      assert_predicate status, :success?, stderr
      assert_includes stdout, "create"

      stdout, stderr, status = invoke(workspace, "check", "--offline")

      assert_equal 1, status.exitstatus, stderr
      assert_includes stdout, "create"

      stdout, stderr, status = invoke(workspace, "apply", "--dry-run")

      assert_predicate status, :success?, stderr
      assert_includes stdout, "Dry run: no remote secrets were changed."
      assert_empty write_calls(workspace.fetch(:fake_gh))

      stdout, stderr, status = invoke(workspace, "apply", "--yes")

      assert_predicate status, :success?, stderr
      assert_equal 2, write_calls(workspace.fetch(:fake_gh)).length
      assert_equal %w[actions dependabot], write_calls(workspace.fetch(:fake_gh)).map { |call| option(call, "--app") }.sort
      assert(write_calls(workspace.fetch(:fake_gh)).all? { |call| call.fetch("stdin_matches_expected") })
      assert(write_calls(workspace.fetch(:fake_gh)).all? do |call|
        !call.fetch("arguments").include?(TEST_SECRET_VALUE)
      end)
      refute_includes stdout + stderr, TEST_SECRET_VALUE
      refute_includes stdout + stderr, TEST_AUTH_TOKEN
      refute_includes File.read(workspace.fetch(:state_path)), TEST_SECRET_VALUE
      refute_includes File.read(workspace.fetch(:state_path)), TEST_AUTH_TOKEN
      refute_includes File.read(workspace.fetch(:fake_gh).state_path), TEST_SECRET_VALUE
      refute_includes File.read(workspace.fetch(:fake_gh).state_path), TEST_AUTH_TOKEN

      stdout, stderr, status = invoke(workspace, "check", "--offline")

      assert_predicate status, :success?, stderr
      assert_includes stdout, "ok"
    end
  end

  def test_apply_filters_writes_to_the_requested_repository_and_context
    with_workspace(contexts: %w[actions dependabot]) do |workspace|
      stdout, stderr, status = invoke(
        workspace,
        "apply",
        "--repo", "example/repo",
        "--context", "dependabot",
        "--yes"
      )

      assert_predicate status, :success?, stderr
      calls = write_calls(workspace.fetch(:fake_gh))

      assert_equal 1, calls.length
      assert_equal ["secret", "set", "SYNC_TOKEN", "--repo", "example/repo", "--app", "dependabot"],
                   calls.first.fetch("arguments")
      assert calls.first.fetch("stdin_matches_expected")
      refute_includes stdout + stderr, TEST_SECRET_VALUE
      refute_includes stdout + stderr, TEST_AUTH_TOKEN
    end
  end

  def test_context_scoped_apply_marks_partial_inventory_and_offline_read_fails_closed
    with_workspace(contexts: %w[actions dependabot]) do |workspace|
      _stdout, stderr, status = invoke(workspace, "apply", "--context", "dependabot", "--yes")

      assert_predicate status, :success?, stderr

      list_calls = workspace.fetch(:fake_gh).calls.select do |call|
        call.fetch("arguments").first(2) == %w[secret list]
      end

      assert_equal ["dependabot"], list_calls.map { |call| option(call, "--app") }.uniq

      state = JSON.parse(File.read(workspace.fetch(:state_path)))

      assert_equal ["dependabot"], state.dig("sources", "github-main", "refreshed_contexts")

      _stdout, stderr, status = invoke(workspace, "plan", "--offline")

      assert_equal 1, status.exitstatus
      assert_includes stderr, "does not cover actions"
      assert_includes stderr, "dependabot"

      _stdout, stderr, status = invoke(workspace, "plan", "--offline", "--context", "dependabot")

      assert_predicate status, :success?, stderr

      _stdout, stderr, status = invoke(workspace, "pull")

      assert_predicate status, :success?, stderr
      assert_nil JSON.parse(File.read(workspace.fetch(:state_path)))
                     .dig("sources", "github-main", "refreshed_contexts")
    end
  end

  def test_apply_secret_filter_limits_writes_to_the_selected_token
    with_workspace(contexts: ["actions"], secret_names: %w[SYNC_TOKEN DEPLOY_TOKEN]) do |workspace|
      stdout, stderr, status = invoke(workspace, "apply", "--secret", "SYNC_TOKEN", "--yes")

      assert_predicate status, :success?, stderr
      calls = write_calls(workspace.fetch(:fake_gh))

      assert_equal 1, calls.length
      assert_equal "SYNC_TOKEN", calls.first.fetch("arguments").fetch(2)
      assert calls.first.fetch("stdin_matches_expected")
      refute_includes stdout + stderr, TEST_SECRET_VALUE
      refute_includes stdout + stderr, TEST_AUTH_TOKEN
    end
  end

  def test_apply_aborts_when_configuration_changes_during_inventory_refresh
    with_workspace(contexts: ["actions"]) do |workspace|
      stdout, stderr, status = invoke(
        workspace,
        "apply",
        "--yes",
        environment_overrides: { "FAKE_GH_MUTATE_CONFIG" => workspace.fetch(:config_path) }
      )

      assert_equal 1, status.exitstatus
      assert_includes stderr, "changed while preparing this command"
      refute(workspace.fetch(:fake_gh).calls.any? do |call|
        call.fetch("arguments").first(2) == %w[secret set]
      end)
      assert_includes File.read(workspace.fetch(:config_path)), "synthetic concurrent edit"
      refute_includes stdout + stderr, TEST_SECRET_VALUE
    end
  end

  def test_apply_requires_explicit_approval_without_an_interactive_terminal
    with_workspace(contexts: ["actions"]) do |workspace|
      stdout, stderr, status = invoke(workspace, "apply")

      assert_equal 1, status.exitstatus
      assert_includes stderr, "requires --yes"
      assert_empty write_calls(workspace.fetch(:fake_gh))
      refute_includes stdout + stderr, TEST_SECRET_VALUE
    end
  end

  def test_apply_with_missing_values_returns_failure_without_writing
    with_workspace(contexts: ["actions"], include_value: false) do |workspace|
      stdout, stderr, status = invoke(workspace, "apply", "--yes")

      assert_equal 1, status.exitstatus
      assert_includes stdout, "missing_value"
      assert_includes stdout, "blocked"
      assert_empty write_calls(workspace.fetch(:fake_gh))
      refute_includes stdout + stderr, TEST_AUTH_TOKEN
    end
  end

  def test_remote_newer_secret_is_not_written_without_force
    remote = {
      "example/repo|actions" => [
        { "name" => "SYNC_TOKEN", "updatedAt" => "2099-01-04T00:00:00Z" }
      ]
    }
    managed = {
      "version" => "v1",
      "applied_at" => "2099-01-02T00:00:00Z",
      "source_identity" => "github|github.com|example",
      "repo_id" => "4242"
    }

    with_workspace(contexts: ["actions"], remote_secrets: remote, managed_record: managed) do |workspace|
      stdout, stderr, status = invoke(workspace, "apply", "--yes")

      assert_equal 1, status.exitstatus, stderr
      assert_includes stdout, "remote_newer"
      assert_empty write_calls(workspace.fetch(:fake_gh))

      stdout, stderr, status = invoke(workspace, "apply", "--force", "--yes")

      assert_predicate status, :success?, stderr
      assert_equal 1, write_calls(workspace.fetch(:fake_gh)).length
      assert write_calls(workspace.fetch(:fake_gh)).first.fetch("stdin_matches_expected")
      refute_includes stdout + stderr, TEST_SECRET_VALUE
      refute_includes stdout + stderr, TEST_AUTH_TOKEN
      refute_includes File.read(workspace.fetch(:state_path)), TEST_SECRET_VALUE
      refute_includes File.read(workspace.fetch(:fake_gh).state_path), TEST_SECRET_VALUE
    end
  end

  def test_apply_does_not_echo_values_reflected_in_gh_stderr
    with_workspace(contexts: ["actions"]) do |workspace|
      stdout, stderr, status = invoke(
        workspace, "apply", "--yes", environment_overrides: { "FAKE_GH_FAIL_WRITE" => "1" }
      )

      assert_equal 1, status.exitstatus
      assert_includes stdout, "failed with exit 1"
      refute_includes stdout + stderr, TEST_SECRET_VALUE
      refute_includes stdout + stderr, TEST_AUTH_TOKEN
    end
  end

  def test_check_fails_for_missing_local_value_without_a_write
    with_workspace(contexts: ["actions"], include_value: false) do |workspace|
      stdout, stderr, status = invoke(workspace, "check")

      assert_equal 1, status.exitstatus, stderr
      assert_includes stdout, "missing_value"
      assert_empty write_calls(workspace.fetch(:fake_gh))
      refute_includes stdout + stderr, TEST_SECRET_VALUE
      refute_includes stdout + stderr, TEST_AUTH_TOKEN
    end
  end

  def test_offline_network_guard_blocks_socket_connections
    with_workspace(contexts: ["actions"]) do |workspace|
      stdout, stderr, status = Open3.capture3(
        workspace.fetch(:fake_gh).environment,
        RbConfig.ruby,
        "-r",
        workspace.fetch(:fake_gh).network_guard_path,
        "-e",
        'TCPSocket.allocate.connect(Socket.sockaddr_in(1, "127.0.0.1"))',
        unsetenv_others: true
      )

      refute_predicate status, :success?, stdout
      assert_includes stderr, "network disabled by offline test harness"
    end
  end

  def test_missing_fake_gh_fails_closed_instead_of_finding_a_real_cli
    with_workspace(contexts: ["actions"]) do |workspace|
      empty_path = File.join(workspace.fetch(:directory), "empty-path")
      Dir.mkdir(empty_path)
      stdout, stderr, status = invoke(
        workspace,
        "pull",
        environment_overrides: { "PATH" => empty_path }
      )

      assert_equal 1, status.exitstatus
      assert_includes stderr, "Unable to run gh"
      refute_includes stdout + stderr, TEST_AUTH_TOKEN
    end
  end

  def test_source_configuration_is_validated_before_any_gh_invocation
    error = assert_raises(CredAlignFlow::ConfigError) do
      CredAlignFlow::Providers::GitHub.new({ "type" => "github" }, {})
    end
    assert_includes error.message, "missing owner"

    ["-flag-injection", "bad owner"].each do |owner|
      assert_raises(CredAlignFlow::ConfigError) do
        CredAlignFlow::Providers::GitHub.new({ "type" => "github", "owner" => owner }, {})
      end
    end

    error = assert_raises(CredAlignFlow::ConfigError) do
      CredAlignFlow::Providers::GitHub.new(
        { "type" => "github", "owner" => "example", "api_url" => "ftp://example.test" }, {}
      )
    end
    assert_includes error.message, "http(s)"

    error = assert_raises(CredAlignFlow::ConfigError) do
      CredAlignFlow::Providers::GitHub.new(
        { "type" => "github", "owner" => "example", "api_url" => "https://not a url" }, {}
      )
    end
    assert_includes error.message, "api_url/url"

    assert_raises(CredAlignFlow::ConfigError) do
      CredAlignFlow::Providers::GitHub.new(
        { "type" => "github", "owner" => "example", "host" => "-bad" }, {}
      )
    end
  end

  def test_argument_validation_rejects_flag_like_or_malformed_names
    provider = CredAlignFlow::Providers::GitHub.new(
      { "type" => "github", "owner" => "example" }, {}
    )

    # The reserved GITHUB_ prefix, a leading digit, and a hyphen are all
    # invalid secret names; each must fail before gh is invoked.
    %w[GITHUB_TOKEN 2BAD BAD-NAME].each do |name|
      assert_raises(CredAlignFlow::ProviderError) do
        provider.set_secret("example/repo", "actions", name, "v")
      end
    end

    assert_raises(CredAlignFlow::ProviderError) do
      provider.set_secret("-evil", "actions", "OK_NAME", "v")
    end
    assert_raises(CredAlignFlow::ProviderError) { provider.repository("-f") }
    assert_raises(CredAlignFlow::ProviderError) { provider.secrets("bad repo", "actions") }
    assert_raises(CredAlignFlow::ProviderError) { provider.secrets("example/repo", "bogus") }
  end

  def test_malformed_or_duplicate_secret_listing_fails_closed
    remote = { "example/repo|actions" => [{ "name" => "DUP_TOKEN" }, { "name" => "dup_token" }] }
    with_workspace(contexts: ["actions"], remote_secrets: remote) do |workspace|
      stdout, stderr, status = invoke(workspace, "pull")

      assert_equal 1, status.exitstatus
      assert_includes stderr, "malformed or duplicate"
      refute_includes stdout + stderr, TEST_AUTH_TOKEN
    end
  end

  private

  def with_workspace(
    contexts:, api_url: "https://github.com",
    include_value: true,
    remote_secrets: {},
    managed_record: nil,
    secret_names: ["SYNC_TOKEN"],
    additional_sources: {},
    secret_sources: nil,
    secret_visibility: nil,
    include_repositories: [],
    auth_values: {},
    repositories: TestSupport::FakeGh::DEFAULT_REPOSITORIES,
    expected_github_token: TEST_AUTH_TOKEN,
    expected_enterprise_token: TEST_AUTH_TOKEN
  )
    Dir.mktmpdir("cred-align-flow-github-test") do |directory|
      config_path = File.join(directory, "config.yml")
      env_path = File.join(directory, "values.env")
      state_path = File.join(directory, "state.json")
      sources = {
        "github-main" => {
          "type" => "github",
          "owner" => "example",
          "api_url" => api_url,
          "auth_env" => "GITHUB_TEST_AUTH",
          "repositories" => { "visibility" => "all", "include" => include_repositories }
        }
      }.merge(additional_sources)
      secrets = secret_names.map do |name|
        secret = {
          "name" => name,
          "value_env" => "SYNC_TOKEN_VALUE",
          "version" => "v1",
          "version_at" => "2026-01-01T00:00:00Z",
          "targets" => { "github" => contexts.dup }
        }
        secret["sources"] = secret_sources if secret_sources
        secret["visibility"] = secret_visibility if secret_visibility
        secret
      end
      config = {
        "version" => 1,
        "state_file" => state_path,
        "sources" => sources,
        "secrets" => secrets
      }
      File.write(config_path, YAML.dump(config))
      values = { "GITHUB_TEST_AUTH" => TEST_AUTH_TOKEN }.merge(auth_values)
      env_lines = values.map { |name, value| "#{name}=#{value}" }
      env_lines << "SYNC_TOKEN_VALUE=#{TEST_SECRET_VALUE}" if include_value
      File.write(env_path, "#{env_lines.join("\n")}\n")
      if managed_record
        # Applied records key on the stable repository identity (id:...).
        application_key = ["github-main", "id:4242", "actions", "SYNC_TOKEN"].join("|")
        File.write(state_path, JSON.generate(
                                 "version" => 1,
                                 "generated_at" => nil,
                                 "sources" => {},
                                 "applied" => { application_key => managed_record }
                               ))
      end

      fake_gh = TestSupport::FakeGh.new(
        directory,
        repositories: repositories,
        secrets: remote_secrets,
        expected_secret: TEST_SECRET_VALUE,
        expected_github_token: expected_github_token,
        expected_enterprise_token: expected_enterprise_token
      )
      yield(
        directory: directory,
        config_path: config_path,
        env_path: env_path,
        state_path: state_path,
        fake_gh: fake_gh
      )
    end
  end

  def invoke(workspace, command, *, environment_overrides: {})
    overrides = { "CRED_ALIGN_FLOW_FINGERPRINT_KEY" => "test-only fingerprint key" }
                .merge(environment_overrides)
    TestSupport.run_cli(
      workspace.fetch(:fake_gh),
      command,
      "--config", workspace.fetch(:config_path),
      "--env-file", workspace.fetch(:env_path),
      "--state", workspace.fetch(:state_path),
      *,
      environment_overrides: overrides
    )
  end

  def option(call, name)
    arguments = call.fetch("arguments")
    arguments[arguments.index(name) + 1]
  end

  def repository_metadata(_owner, full_name)
    TestSupport.repository_metadata(
      "name" => full_name.split("/", 2).last,
      "nameWithOwner" => full_name,
      "isPrivate" => true,
      "visibility" => "PRIVATE"
    )
  end

  def write_calls(fake_gh)
    fake_gh.calls.select { |call| call.fetch("arguments").first(2) == %w[secret set] }
  end
end
