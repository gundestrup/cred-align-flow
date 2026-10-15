# frozen_string_literal: true

require_relative "test_helper"

class ScaffolderTest < Minitest::Test
  def with_config(yaml: nil)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, yaml || <<~YAML)
        version: 1
        sources:
          github-main:
            type: github
            owner: example
            auth_env: GITHUB_SYNC_TOKEN
        secrets:
          - name: SONAR_TOKEN
            value_env: SONAR_TOKEN
      YAML
      yield dir, path
    end
  end

  def test_scaffolds_unmanaged_env_vars_as_active_entries_for_exact_targets
    with_config do |_dir, path|
      config = CredAlignFlow::Config.new(path)
      env = {
        "SONAR_TOKEN" => "x", # referenced via value_env
        "GITHUB_SYNC_TOKEN" => "x", # referenced via auth_env
        "NEW_TOKEN" => "x",
        "EMPTY_VAR" => "",
        "ANOTHER_VAR" => "x"
      }

      scaffolder = CredAlignFlow::Scaffolder.new(path)

      assert_equal %w[NEW_TOKEN EMPTY_VAR ANOTHER_VAR], scaffolder.candidates(env, config)

      scaffolder.apply!(scaffolder.candidates(env, config), config, env,
                        targets: target_scope, at: Time.utc(2026, 10, 9, 12, 0, 0))
      text = File.read(path)

      assert_includes text, "# scaffold: NEW_TOKEN"
      assert_includes text, "  - name: \"NEW_TOKEN\""
      assert_includes text, "    version_at: \"2026-10-09T12:00:00Z\""
      assert_includes text, "    sources: [\"github-main\"]"
      assert_includes text, "      \"github\":"
      assert_includes text, "        - \"actions\""
      assert_includes text, "        # - \"agents\""
      assert_includes text, "    exclude_repositories:"
      assert_includes text, "      \"github-main\": [\"*\"]"
      assert_includes text, "        \"example/repo\": include"
      assert_includes text, "# scaffold: EMPTY_VAR"
      refute_includes text, "# scaffold: SONAR_TOKEN"

      # Scaffolded entries are active managed secrets.
      secrets = CredAlignFlow::Config.new(path).secrets

      assert_equal 4, secrets.length
      assert_equal(%w[SONAR_TOKEN NEW_TOKEN EMPTY_VAR ANOTHER_VAR], secrets.map { |s| s["name"] })
      assert_equal 0o600, File.stat(path).mode & 0o777
    end
  end

  def test_apply_is_idempotent_via_active_definition
    with_config do |_dir, path|
      config = CredAlignFlow::Config.new(path)
      env = { "SONAR_TOKEN" => "x", "NEW_TOKEN" => "x" }

      CredAlignFlow::Scaffolder.new(path).apply!(["NEW_TOKEN"], config, env, targets: target_scope)
      scaffolder = CredAlignFlow::Scaffolder.new(path)

      assert_empty scaffolder.candidates(env, CredAlignFlow::Config.new(path))
    end
  end

  def test_appends_secrets_section_when_missing
    with_config(yaml: <<~YAML) do |_dir, path|
      version: 1
      sources:
        github-main:
          type: github
          owner: example
    YAML
      config = CredAlignFlow::Config.new(path)

      CredAlignFlow::Scaffolder.new(path).apply!(["EXTRA_TOKEN"], config, { "EXTRA_TOKEN" => "x" }, targets: target_scope)
      text = File.read(path)

      assert_equal 1, text.scan(/^secrets:/).length # nosemgrep: ruby-redos-string-scan -- anchored literal prefix
      assert_includes text, "# scaffold: EXTRA_TOKEN"
      assert_equal 1, CredAlignFlow::Config.new(path).secrets.length
    end
  end

  def test_inserts_before_a_following_top_level_key
    with_config(yaml: <<~YAML) do |_dir, path|
      version: 1
      secrets:
        - name: SONAR_TOKEN
          value_env: SONAR_TOKEN
      sources:
        github-main:
          type: github
          owner: example
    YAML
      config = CredAlignFlow::Config.new(path)

      CredAlignFlow::Scaffolder.new(path).apply!(["NEW_TOKEN"], config, { "NEW_TOKEN" => "x" }, targets: target_scope)
      text = File.read(path)

      assert_operator text.index("# scaffold: NEW_TOKEN"), :<, text.index("sources:")
      assert_includes text, "  github-main:"
      assert_equal 2, CredAlignFlow::Config.new(path).secrets.length
    end
  end

  def test_records_value_digest_for_imported_entries
    with_config do |_dir, path|
      config = CredAlignFlow::Config.new(path)
      env = { "SONAR_TOKEN" => "x", "NEW_TOKEN" => "secret-value", "EMPTY_VAR" => "" }

      result = CredAlignFlow::Scaffolder.new(path).apply!(%w[NEW_TOKEN EMPTY_VAR], config, env, targets: target_scope)
      text = File.read(path)

      assert_equal %w[NEW_TOKEN EMPTY_VAR], result["added"]
      assert_equal ["SONAR_TOKEN"], result["digests"]
      expected = CredAlignFlow::Fingerprint.digest("NEW_TOKEN", "secret-value")

      assert_includes text, "    value_digest: \"#{expected}\""
      refute_includes text, "value_digest: \"#{CredAlignFlow::Fingerprint.digest('EMPTY_VAR', '')}\""

      reloaded = CredAlignFlow::Config.new(path)
      statuses = reloaded.secrets.to_h do |secret|
        [secret["name"], reloaded.value_digest_status(secret, env)]
      end

      assert_equal :current, statuses["NEW_TOKEN"]
      assert_equal :unrecorded, statuses["EMPTY_VAR"]
    end
  end

  def test_syncs_digest_when_value_rotates
    with_config do |_dir, path|
      env = { "SONAR_TOKEN" => "v1" }
      CredAlignFlow::Scaffolder.new(path).apply!([], CredAlignFlow::Config.new(path), env)
      first = CredAlignFlow::Config.new(path).secrets.find { |s| s["name"] == "SONAR_TOKEN" }["value_digest"]

      rotated = { "SONAR_TOKEN" => "v2" }
      config = CredAlignFlow::Config.new(path)

      assert_equal :changed, config.value_digest_status(config.secrets.first, rotated)

      result = CredAlignFlow::Scaffolder.new(path).apply!([], config, rotated)
      updated = CredAlignFlow::Config.new(path).secrets.find { |s| s["name"] == "SONAR_TOKEN" }

      assert_equal ["SONAR_TOKEN"], result["digests"]
      refute_equal first, updated["value_digest"]
      assert_equal CredAlignFlow::Fingerprint.digest("SONAR_TOKEN", "v2"), updated["value_digest"]
    end
  end

  def test_scaffolded_entry_is_excluded_from_other_repositories
    with_config do |_dir, path|
      config = CredAlignFlow::Config.new(path)
      env = { "NEW_TOKEN" => "synthetic-value" }
      CredAlignFlow::Scaffolder.new(path).apply!(["NEW_TOKEN"], config, env, targets: target_scope)
      scoped = CredAlignFlow::Config.new(path)
      secret = scoped.secrets.last
      other = TestSupport.repository_metadata("nameWithOwner" => "example/other")

      assert_equal "assigned_manual", scoped.secret_assignment(secret, "github-main", TestSupport.repository_metadata).first
      assert_equal "excluded_manual", scoped.secret_assignment(secret, "github-main", other).first
      assert_equal ["actions"], scoped.contexts_for(secret, "github-main")
    end
  end

  def test_rejects_target_tuples_the_config_cannot_represent_without_widening
    with_config do |_dir, path|
      original = File.binread(path)
      config = CredAlignFlow::Config.new(path)
      targets = [
        ["github-main", "actions", "example/repo"],
        ["github-main", "dependabot", "example/other"]
      ]

      assert_raises(CredAlignFlow::ConfigError) do
        CredAlignFlow::Scaffolder.new(path).apply!(
          ["NEW_TOKEN"], config, { "NEW_TOKEN" => "synthetic-value" }, targets: targets
        )
      end
      assert_equal original, File.binread(path)
    end
  end

  def test_stale_scaffold_marker_does_not_hide_unmanaged_name
    with_config(yaml: <<~YAML) do |_dir, path|
      version: 1
      sources:
        github-main:
          type: github
          owner: example
      secrets: []
      # scaffold: NEW_TOKEN - a definition was removed
    YAML
      config = CredAlignFlow::Config.new(path)

      assert_equal ["NEW_TOKEN"], CredAlignFlow::Scaffolder.new(path).candidates({ "NEW_TOKEN" => "x" }, config)
    end
  end

  def test_keeps_recorded_digest_when_value_disappears
    with_config do |_dir, path|
      CredAlignFlow::Scaffolder.new(path).apply!([], CredAlignFlow::Config.new(path), { "SONAR_TOKEN" => "v1" })

      result = CredAlignFlow::Scaffolder.new(path).apply!([], CredAlignFlow::Config.new(path), {})
      config = CredAlignFlow::Config.new(path)

      assert_empty result["digests"]
      assert_equal :missing, config.value_digest_status(config.secrets.first, {})
    end
  end

  def test_auto_mode_imports_minimal_active_entries_under_the_token_defaults
    with_config do |_dir, path|
      config = CredAlignFlow::Config.new(path)
      env = { "NEW_TOKEN" => "synthetic-value" }

      CredAlignFlow::Scaffolder.new(path).apply!(["NEW_TOKEN"], config, env, mode: :auto)
      text = File.read(path)

      assert_includes text, "# scaffold: NEW_TOKEN"
      assert_includes text, "  - name: \"NEW_TOKEN\""
      assert_includes text, "imported and activated under the token defaults"

      scoped = CredAlignFlow::Config.new(path)
      secret = scoped.secrets.find { |entry| entry["name"] == "NEW_TOKEN" }

      assert_equal(
        %w[name value_env value_digest version version_at],
        secret.keys
      )
      assert_equal "assigned_default", scoped.secret_assignment(secret, "github-main", TestSupport.repository_metadata).first
      assert_equal ["actions"], scoped.contexts_for(secret, "github-main")
    end
  end

  def test_import_mode_writes_commented_drafts_and_skips_them_later
    with_config do |_dir, path|
      config = CredAlignFlow::Config.new(path)
      env = { "NEW_TOKEN" => "synthetic-value" }

      CredAlignFlow::Scaffolder.new(path).apply!(["NEW_TOKEN"], config, env, mode: :import)
      text = File.read(path)

      assert_includes text, "# scaffold-draft: NEW_TOKEN"
      assert_includes text, "  # - name: \"NEW_TOKEN\""
      assert_includes text, "    # visibility: all"
      assert_includes text, "      # \"github\":"
      assert_includes text, "        # - \"actions\""
      # Adapter-derived contexts and optional scope fields carry a second
      # "#" so they stay commented even after the entry is activated.
      assert_includes text, "        # # - \"agents\""
      assert_includes text, "    # # exclude_sources:"
      assert_includes text, "    # # exclude_repositories:"
      assert_includes text, "    # # repository_rules:"
      assert_equal 1, CredAlignFlow::Config.new(path).secrets.length

      # A drafted name is not offered for import again.
      scaffolder = CredAlignFlow::Scaffolder.new(path)

      assert_empty scaffolder.candidates(env, CredAlignFlow::Config.new(path))
    end
  end

  def test_uncommented_import_draft_becomes_an_active_entry
    with_config do |_dir, path|
      config = CredAlignFlow::Config.new(path)
      env = { "NEW_TOKEN" => "synthetic-value" }

      CredAlignFlow::Scaffolder.new(path).apply!(["NEW_TOKEN"], config, env, mode: :import)

      # Simulate the user uncommenting the draft entry (not its marker).
      uncommented = File.read(path).each_line.map do |line|
        line.include?("# scaffold-draft:") ? line : line.sub(/\A(\s*)# /, "\\1")
      end.join
      File.write(path, uncommented)

      scoped = CredAlignFlow::Config.new(path)
      secret = scoped.secrets.find { |entry| entry["name"] == "NEW_TOKEN" }

      refute_nil secret
      refute secret.key?("exclude_sources")
      refute secret.key?("exclude_repositories")
      refute secret.key?("repository_rules")
      assert_equal({ "github" => ["actions"] }, secret["targets"])
      assert_equal "assigned_default", scoped.secret_assignment(secret, "github-main", TestSupport.repository_metadata).first
    end
  end

  def test_import_mode_with_explicit_targets_writes_a_targeted_draft
    with_config do |_dir, path|
      config = CredAlignFlow::Config.new(path)
      env = { "NEW_TOKEN" => "synthetic-value" }

      CredAlignFlow::Scaffolder.new(path).apply!(["NEW_TOKEN"], config, env, targets: target_scope, mode: :import)
      text = File.read(path)

      assert_includes text, "# scaffold-draft: NEW_TOKEN"
      assert_includes text, "    # exclude_repositories:"
      assert_includes text, "      # \"github-main\": [\"*\"]"
      assert_includes text, "        # \"example/repo\": include"
      assert_equal 1, CredAlignFlow::Config.new(path).secrets.length
    end
  end

  private

  def target_scope
    [["github-main", "actions", "example/repo"]]
  end
end
