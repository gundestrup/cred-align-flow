# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "yaml"

# End-to-end CLI coverage through the real bin/cred-align-flow executable with a
# fake gh binary and a network guard, complementing the provider-focused
# scenarios in github_cli_test.rb.
class CliTest < Minitest::Test
  TEST_SECRET_VALUE = "synthetic-test-payload"
  TEST_AUTH_TOKEN = "synthetic-test-auth-token"

  def test_help_lists_all_commands
    with_workspace do |workspace|
      stdout, _stderr, status = invoke(workspace)

      assert_predicate status, :success?
      %w[doctor inventory pull plan diff check apply scaffold ui].each do |command|
        assert_includes stdout, command
      end
    end
  end

  def test_version_flag_prints_the_version
    with_workspace do |workspace|
      stdout, _stderr, status = invoke(workspace, "--version")

      assert_predicate status, :success?
      assert_equal CredAlignFlow::VERSION, stdout.strip
    end
  end

  def test_option_values_matching_commands_are_not_treated_as_commands
    with_workspace do |workspace|
      stdout, stderr, status = invoke(workspace, "--config", "plan")

      assert_predicate status, :success?, stderr
      assert_includes stdout, "Usage:"
    end
  end

  def test_global_flags_ignore_option_values
    with_workspace do |workspace|
      stdout, stderr, status = invoke(workspace, "--config", "plan", "--version")

      assert_predicate status, :success?, stderr
      assert_equal "#{CredAlignFlow::VERSION}\n", stdout
    end
  end

  def test_help_rejects_trailing_positional_arguments
    with_workspace do |workspace|
      _stdout, stderr, status = invoke(workspace, "help", "unexpected")

      assert_equal 1, status.exitstatus
      assert_includes stderr, "unexpected arguments"
    end
  end

  def test_unknown_option_fails_with_usage_error
    with_workspace do |workspace|
      _stdout, stderr, status = invoke(workspace, "doctor", "--bogus")

      assert_equal 1, status.exitstatus
      assert_includes stderr, "cred-align-flow:"
    end
  end

  def test_missing_config_file_fails_closed
    with_workspace do |workspace|
      _stdout, stderr, status = invoke(
        workspace, "doctor", environment_overrides: {}, extra_args: ["--config", "/nonexistent/config.yml"]
      )

      assert_equal 1, status.exitstatus
      assert_includes stderr, "cred-align-flow:"
    end
  end

  def test_cli_state_override_cannot_replace_the_config
    with_workspace do |workspace|
      original = File.binread(workspace.fetch(:config_path))
      _stdout, stderr, status = invoke(
        workspace, "doctor", extra_args: ["--state", workspace.fetch(:config_path)]
      )

      assert_equal 1, status.exitstatus
      assert_includes stderr, "different files"
      assert_equal original, File.binread(workspace.fetch(:config_path))
    end
  end

  def test_doctor_reports_paths_secrets_and_digest_status
    with_workspace do |workspace|
      stdout, stderr, status = invoke(workspace, "doctor")

      assert_predicate status, :success?, stderr
      assert_includes stdout, "Config: #{workspace.fetch(:config_path)}"
      assert_includes stdout, "Env file: #{workspace.fetch(:env_path)}"
      assert_includes stdout, "State: #{workspace.fetch(:state_path)}"
      assert_includes stdout, "Secrets configured: 1"
      assert_includes stdout, "all configured values are available"
      assert_includes stdout, "unrecorded"
    end
  end

  def test_doctor_verify_fails_when_provider_authentication_fails
    with_workspace do |workspace|
      stdout, stderr, status = invoke(
        workspace, "doctor", "--verify", environment_overrides: { "FAKE_GH_AUTH_FAIL" => "1" }
      )

      assert_equal 1, status.exitstatus
      assert_includes stdout, "readiness: not authenticated"
      refute_includes stdout + stderr, TEST_AUTH_TOKEN
    end
  end

  def test_doctor_warns_when_value_differs_from_recorded_digest
    with_workspace do |workspace|
      # Record a digest for a different value, then rotate the env value.
      _stdout, stderr, status = invoke(workspace, "scaffold")

      assert_predicate status, :success?, stderr

      File.write(workspace.fetch(:env_path),
                 "GITHUB_TEST_AUTH=#{TEST_AUTH_TOKEN}\nSYNC_TOKEN_VALUE=rotated-payload\nUNMANAGED_TOKEN=x\n")

      stdout, stderr, status = invoke(workspace, "doctor")

      assert_predicate status, :success?, stderr
      assert_includes stdout, "Values changed since the recorded digest"
      assert_includes stdout, "SYNC_TOKEN"
      refute_includes stdout + stderr, "rotated-payload"
    end
  end

  def test_stale_rules_warn_instead_of_failing_the_load
    with_workspace do |workspace|
      rules_path = CredAlignFlow::Rules.default_path_for(workspace.fetch(:config_path))
      File.write(rules_path, JSON.generate(
                               "version" => 1,
                               "rules" => {
                                 "github-main" => { "example/repo" => { "GONE_TOKEN" => "include" } }
                               }
                             ))

      stdout, stderr, status = invoke(workspace, "scaffold")

      assert_predicate status, :success?, stderr
      assert_includes stderr, "stale rule"
      assert_includes stderr, File.basename(rules_path)
      refute_includes stdout + stderr, TEST_SECRET_VALUE
    end
  end

  def test_scaffold_requires_explicit_names_and_exact_targets
    with_workspace do |workspace|
      stdout, stderr, status = invoke(workspace, "scaffold")

      assert_predicate status, :success?, stderr
      assert_includes stdout, "Unimported env names: UNMANAGED_TOKEN"
      assert_empty(CredAlignFlow::Config.new(workspace.fetch(:config_path)).secrets.select do |secret|
        secret["name"] == "UNMANAGED_TOKEN"
      end)

      stdout, stderr, status = invoke(
        workspace, "scaffold", extra_args: [
          "--only", "UNMANAGED_TOKEN", "--target", "github-main|actions|example/repo"
        ]
      )

      assert_predicate status, :success?, stderr
      assert_includes stdout, "Will add 1 active secret entry for exact targets"
      assert_includes stdout, "github-main actions example/repo"

      config = CredAlignFlow::Config.new(workspace.fetch(:config_path))
      entry = config.secrets.find { |secret| secret["name"] == "UNMANAGED_TOKEN" }

      refute_nil entry
      assert_equal "UNMANAGED_TOKEN", entry["value_env"]
      assert_equal CredAlignFlow::Fingerprint.digest("UNMANAGED_TOKEN", "extra-payload"), entry["value_digest"]
      assert_equal ["github-main"], entry["sources"]
      assert_equal ["actions"], entry.dig("targets", "github")
      assert_equal({ "github-main" => ["*"] }, entry["exclude_repositories"])
      assert_equal "include", entry.dig("repository_rules", "github-main", "example/repo")

      stdout, stderr, status = invoke(workspace, "scaffold")

      assert_predicate status, :success?, stderr
      assert_includes stdout, "No unmanaged env-file variables"
      refute_includes stdout + stderr, "extra-payload"
      refute_includes File.read(workspace.fetch(:config_path)), "extra-payload"
    end
  end

  def test_scaffold_ignore_does_not_import_the_name_in_the_same_run
    with_workspace do |workspace|
      _stdout, stderr, status = invoke(workspace, "scaffold", extra_args: ["--ignore", "UNMANAGED_TOKEN"])

      assert_predicate status, :success?, stderr
      config = CredAlignFlow::Config.new(workspace.fetch(:config_path))

      assert_includes config.ignored_env_names, "UNMANAGED_TOKEN"
      refute(config.secrets.any? { |secret| secret["name"] == "UNMANAGED_TOKEN" })
    end
  end

  def test_scaffold_rejects_import_without_exact_targets_without_writing
    with_workspace do |workspace|
      original = File.binread(workspace.fetch(:config_path))
      _stdout, stderr, status = invoke(workspace, "scaffold", extra_args: ["--only", "UNMANAGED_TOKEN"])

      assert_equal 1, status.exitstatus
      assert_includes stderr, "explicit --target"
      assert_equal original, File.binread(workspace.fetch(:config_path))
    end
  end

  def test_scaffold_action_auto_imports_inactive_minimal_entries
    with_workspace do |workspace|
      File.open(workspace.fetch(:config_path), "a") { |file| file.puts "scaffold_action: auto" }
      stdout, stderr, status = invoke(workspace, "scaffold")

      assert_predicate status, :success?, stderr
      assert_includes stdout, "inactive"

      config = CredAlignFlow::Config.new(workspace.fetch(:config_path))
      entry = config.secrets.find { |secret| secret["name"] == "UNMANAGED_TOKEN" }

      refute_nil entry
      refute entry.key?("visibility")
      refute entry.key?("sources")
      refute entry.key?("exclude_repositories")
      refute entry.key?("repository_rules")
      assert_equal({ "github" => [] }, entry["targets"])
      assert_empty config.contexts_for(entry, "github-main")
      refute_includes stdout + stderr, "extra-payload"
    end
  end

  def test_scaffold_action_import_writes_commented_draft_entries
    with_workspace do |workspace|
      File.open(workspace.fetch(:config_path), "a") { |file| file.puts "scaffold_action: import" }
      stdout, stderr, status = invoke(workspace, "scaffold")

      assert_predicate status, :success?, stderr
      assert_includes stdout, "commented"

      text = File.read(workspace.fetch(:config_path))

      assert_includes text, "# scaffold-draft: UNMANAGED_TOKEN"
      assert_includes text, "# - name: \"UNMANAGED_TOKEN\""
      assert_empty(CredAlignFlow::Config.new(workspace.fetch(:config_path)).secrets.select do |secret|
        secret["name"] == "UNMANAGED_TOKEN"
      end)

      # The drafted name is not offered again.
      stdout, stderr, status = invoke(workspace, "scaffold")

      assert_predicate status, :success?, stderr
      assert_includes stdout, "No unmanaged env-file variables"
    end
  end

  def test_scaffold_action_auto_only_without_target_imports_inactive
    with_workspace do |workspace|
      File.open(workspace.fetch(:config_path), "a") { |file| file.puts "scaffold_action: auto" }
      _stdout, stderr, status = invoke(workspace, "scaffold", extra_args: ["--only", "UNMANAGED_TOKEN"])

      assert_predicate status, :success?, stderr
      entry = CredAlignFlow::Config.new(workspace.fetch(:config_path)).secrets.last

      assert_equal "UNMANAGED_TOKEN", entry["name"]
      assert_equal({ "github" => [] }, entry["targets"])
    end
  end

  def test_scaffold_auto_skips_unimportable_names_and_imports_the_rest
    with_workspace(extra_env: { "UNMANAGED_TOKEN" => "extra-payload", "GITHUB_TOKEN" => "x" }) do |workspace|
      File.open(workspace.fetch(:config_path), "a") { |file| file.puts "scaffold_action: auto" }
      stdout, stderr, status = invoke(workspace, "scaffold")

      assert_predicate status, :success?, stderr
      assert_includes stderr, "skipping env name GITHUB_TOKEN: uses the reserved GITHUB_ prefix"
      assert_includes stdout, "UNMANAGED_TOKEN"
      refute_includes stdout, "  GITHUB_TOKEN"

      config = CredAlignFlow::Config.new(workspace.fetch(:config_path))

      assert_equal "UNMANAGED_TOKEN", config.secrets.last["name"]
      refute(config.secrets.any? { |secret| secret["name"] == "GITHUB_TOKEN" })
    end
  end

  def test_scaffold_default_listing_annotates_unimportable_names
    with_workspace(extra_env: { "UNMANAGED_TOKEN" => "x", "GITHUB_TOKEN" => "x" }) do |workspace|
      stdout, stderr, status = invoke(workspace, "scaffold")

      assert_predicate status, :success?, stderr
      assert_includes stdout, "UNMANAGED_TOKEN"
      assert_includes stdout, "GITHUB_TOKEN (cannot be imported: uses the reserved GITHUB_ prefix)"
    end
  end

  def test_scaffold_syncs_digests_after_value_rotation
    with_workspace do |workspace|
      _stdout, stderr, status = invoke(workspace, "scaffold")

      assert_predicate status, :success?, stderr

      File.write(workspace.fetch(:env_path),
                 "GITHUB_TEST_AUTH=#{TEST_AUTH_TOKEN}\nSYNC_TOKEN_VALUE=rotated-payload\nUNMANAGED_TOKEN=extra-payload\n")

      stdout, stderr, status = invoke(workspace, "scaffold")

      assert_predicate status, :success?, stderr
      assert_includes stdout, "Updated value digests"
      assert_includes stdout, "SYNC_TOKEN"

      config = CredAlignFlow::Config.new(workspace.fetch(:config_path))
      secret = config.secrets.find { |s| s["name"] == "SYNC_TOKEN" }

      assert_equal CredAlignFlow::Fingerprint.digest("SYNC_TOKEN", "rotated-payload"),
                   secret["value_digest"]
    end
  end

  def test_plan_offline_rejects_a_truncated_inventory
    with_workspace do |workspace|
      config = CredAlignFlow::Config.new(workspace.fetch(:config_path))
      state = CredAlignFlow::State.new(workspace.fetch(:state_path))
      repository = TestSupport.repository_metadata.merge(
        "name_with_owner" => "example/repo",
        "selected" => true,
        "remote_secrets" => { "actions" => {} }
      )
      state.apply_refresh(
        "github-main",
        repositories: { "example/repo" => repository },
        contexts: nil,
        selection: CredAlignFlow::InventoryCheck.selection_fingerprint(config, "github-main"),
        discovered_at: Time.now.utc.iso8601,
        truncated: true
      )
      state.save!

      _stdout, stderr, status = invoke(workspace, "plan", "--offline")

      assert_equal 1, status.exitstatus
      assert_includes stderr, "may be truncated"
    end
  end

  def test_plan_offline_without_inventory_fails_closed
    with_workspace do |workspace|
      _stdout, stderr, status = invoke(workspace, "plan", "--offline")

      assert_equal 1, status.exitstatus
      assert_includes stderr, "No cached inventory"
    end
  end

  def test_prune_deletes_marked_remote_secrets_with_yes
    with_workspace do |workspace|
      _stdout, stderr, status = invoke(workspace, "apply", "--yes")

      assert_predicate status, :success?, stderr
      rules_path = CredAlignFlow::Rules.default_path_for(workspace.fetch(:config_path))
      File.write(rules_path, JSON.generate(
                               "version" => 1,
                               "rules" => {
                                 "github-main" => { "example/repo" => { "SYNC_TOKEN" => "delete" } }
                               }
                             ))

      _stdout, stderr, status = invoke(workspace, "prune")

      assert_equal 1, status.exitstatus
      assert_includes stderr, "prune requires --yes"
      assert_equal "SYNC_TOKEN", fake_gh_secret_names(workspace, "example/repo", "actions").first

      stdout, stderr, status = invoke(workspace, "prune", "--yes")

      assert_predicate status, :success?, stderr
      assert_includes stdout, "delete"
      assert_includes stdout, "deleted github-main example/repo SYNC_TOKEN (actions)"
      assert_includes stdout, "Prune: 1 deleted"
      assert_empty fake_gh_secret_names(workspace, "example/repo", "actions")

      state = JSON.parse(File.read(workspace.fetch(:state_path)))
      repo_node = state.dig("sources", "github-main", "repositories", "example/repo")

      assert_empty repo_node.dig("remote_secrets", "actions") || {}
      assert_empty(state.fetch("applied", {}).keys.grep(/SYNC_TOKEN/))
      refute_includes stdout + stderr, TEST_SECRET_VALUE

      # Once the remote is gone, the mark is satisfied and prune is clean.
      stdout, _stderr, status = invoke(workspace, "prune", "--yes")

      assert_predicate status, :success?
      assert_includes stdout, "No remote secrets are marked"
    end
  end

  def test_prune_without_marks_is_a_noop
    with_workspace do |workspace|
      _stdout, stderr, status = invoke(workspace, "inventory")

      assert_predicate status, :success?, stderr
      stdout, _stderr, status = invoke(workspace, "prune", "--yes")

      assert_predicate status, :success?
      assert_includes stdout, "No remote secrets are marked"
    end
  end

  def test_confirm_delete_keypresses
    item = CredAlignFlow::Planner::Item.new(
      action: "delete", source: "github-main", repository: "example/repo",
      context: "actions", secret: "SYNC_TOKEN"
    )
    cli = CredAlignFlow::CLI.new
    {
      "y" => :yes,
      "Y" => :yes,
      "n" => :skip,
      "c" => :cancel,
      "x" => :cancel,
      "\n" => :cancel,
      "" => :cancel
    }.each do |keys, expected|
      output = StringIO.new

      assert_equal expected, cli.send(:confirm_delete, item, input: StringIO.new(keys), output: output),
                   "keypress #{keys.inspect} should produce #{expected}"
      assert_includes output.string, "SYNC_TOKEN"
    end
  end

  private

  def fake_gh_secret_names(workspace, repository, context)
    workspace.fetch(:fake_gh).state.fetch("secrets").fetch("#{repository}|#{context}", []).map do |entry|
      entry.fetch("name")
    end
  end

  def with_workspace(extra_env: { "UNMANAGED_TOKEN" => "extra-payload" })
    Dir.mktmpdir("cred-align-flow-cli-test") do |directory|
      config_path = File.join(directory, "config.yml")
      env_path = File.join(directory, "values.env")
      state_path = File.join(directory, "state.json")
      config = {
        "version" => 1,
        "state_file" => state_path,
        "sources" => {
          "github-main" => {
            "type" => "github",
            "owner" => "example",
            "api_url" => "https://github.com",
            "auth_env" => "GITHUB_TEST_AUTH",
            "repositories" => { "visibility" => "all" }
          }
        },
        "secrets" => [
          {
            "name" => "SYNC_TOKEN",
            "value_env" => "SYNC_TOKEN_VALUE",
            "version" => "v1",
            "version_at" => "2026-01-01T00:00:00Z",
            "targets" => { "github" => ["actions"] }
          }
        ]
      }
      File.write(config_path, YAML.dump(config))
      values = { "GITHUB_TEST_AUTH" => TEST_AUTH_TOKEN, "SYNC_TOKEN_VALUE" => TEST_SECRET_VALUE }.merge(extra_env)
      File.write(env_path, "#{values.map { |name, value| "#{name}=#{value}" }.join("\n")}\n")
      fake_gh = TestSupport::FakeGh.new(directory, expected_secret: TEST_SECRET_VALUE,
                                                   expected_github_token: TEST_AUTH_TOKEN)
      yield(
        directory: directory,
        config_path: config_path,
        env_path: env_path,
        state_path: state_path,
        fake_gh: fake_gh
      )
    end
  end

  def invoke(workspace, *, environment_overrides: {}, extra_args: [])
    # A fixed fingerprint key makes subprocess digests reproducible; without
    # it the CLI creates a random .digest-key next to the env file.
    overrides = { "CRED_ALIGN_FLOW_FINGERPRINT_KEY" => "test-only fingerprint key" }
                .merge(environment_overrides)
    TestSupport.run_cli(
      workspace.fetch(:fake_gh),
      *,
      "--config", workspace.fetch(:config_path),
      "--env-file", workspace.fetch(:env_path),
      "--state", workspace.fetch(:state_path),
      *extra_args,
      environment_overrides: overrides
    )
  end
end
