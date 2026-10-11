# frozen_string_literal: true

require_relative "test_helper"

class ConfigEditorTest < Minitest::Test
  class FakeProvider
    attr_reader :secret_calls

    def initialize
      @secret_calls = []
    end

    def repositories
      [
        TestSupport.repository_metadata,
        TestSupport.repository_metadata(
          "id" => "7777",
          "name" => "private-repo",
          "nameWithOwner" => "example/private-repo",
          "visibility" => "PRIVATE",
          "isPrivate" => true
        )
      ]
    end

    def contexts
      %w[actions dependabot]
    end

    def validate_context!(context)
      return if contexts.include?(context)

      raise CredAlignFlow::ProviderError, "unsupported context #{context}"
    end

    def secrets(repository, context)
      @secret_calls << [repository, context]
      return [] unless repository == "example/repo"

      [{ "name" => "SAMPLE_TOKEN", "updatedAt" => "2020-01-01T00:00:00Z" }]
    end
  end

  def test_view_groups_repositories_and_never_returns_local_values
    with_editor do |editor, _config_path, _env_path, _state_path, rules_path|
      view = editor.data
      source = view.fetch("sources").first
      public_repo = source.fetch("repositories").find { |repo| repo.fetch("name") == "example/repo" }
      private_repo = source.fetch("repositories").find { |repo| repo.fetch("name") == "example/private-repo" }
      assigned = public_repo.fetch("assigned").first

      assert_equal "github-main", source.fetch("id")
      assert_equal "public", public_repo.fetch("visibility")
      assert_equal "4242", public_repo.fetch("id")
      assert_equal File.basename(rules_path), view.fetch("rules_file")
      assert_equal({}, view.fetch("rules"))
      assert_empty view.fetch("orphan_rules")
      context = assigned.fetch("contexts").first

      assert_equal "ok", context.fetch("action")
      assert_equal "2020-01-01T00:00:00Z", context.fetch("remote_updated_at")
      assert_equal "2021-01-01T00:00:00Z", context.fetch("applied_at")
      assert_equal "default", assigned.fetch("origin")
      assert_equal "default", private_repo.fetch("not_assigned").first.fetch("category")
      assert_includes JSON.generate(view), "SAMPLE_TOKEN_VALUE"
      refute_includes JSON.generate(view), "very-secret-value-should-not-appear"
      refute_match(/hmac-sha256:/, JSON.generate(view))
    end
  end

  def test_preview_applies_repository_overrides_without_writing
    with_editor do |editor, config_path, _env_path, _state_path, rules_path|
      original = File.binread(config_path)
      view = editor.data
      rules = {
        "github-main" => {
          "example/repo" => { "SAMPLE_TOKEN" => "exclude" },
          "example/private-repo" => { "SAMPLE_TOKEN" => "include" }
        }
      }

      preview = editor.preview("revision" => view.fetch("revision"), "rules" => rules)
      source = preview.fetch("sources").first
      public_repo = source.fetch("repositories").find { |repo| repo.fetch("name") == "example/repo" }
      private_repo = source.fetch("repositories").find { |repo| repo.fetch("name") == "example/private-repo" }

      assert_equal "manual", public_repo.fetch("not_assigned").first.fetch("category")
      assert_equal "manual", private_repo.fetch("assigned").first.fetch("origin")
      assert_equal original, File.binread(config_path)
      refute_path_exists rules_path
    end
  end

  def test_view_flags_manual_includes_outside_default_source_scope
    with_editor do |_original_editor, config_path, env_path, state_path, _rules_path|
      data = YAML.safe_load_file(config_path)
      data.fetch("sources").fetch("github-main")["auth_env"] = "GITHUB_MAIN_TOKEN"
      data.fetch("sources")["github-other"] = {
        "type" => "github",
        "owner" => "other",
        "auth_env" => "GITHUB_OTHER_TOKEN",
        "repositories" => { "visibility" => "public" }
      }
      data.fetch("secrets").first["sources"] = ["github-other"]
      File.write(config_path, YAML.dump(data))
      editor = CredAlignFlow::ConfigEditor.new(
        config_path: config_path, env_path: env_path, state_path: state_path
      )
      view = editor.data
      preview = editor.preview(
        "revision" => view.fetch("revision"),
        "rules" => { "github-main" => { "example/repo" => { "SAMPLE_TOKEN" => "include" } } }
      )
      source = preview.fetch("sources").find { |entry| entry.fetch("id") == "github-main" }
      repository = source.fetch("repositories").find { |entry| entry.fetch("name") == "example/repo" }

      assert_equal true, repository.fetch("crosses_scope").fetch("SAMPLE_TOKEN")
    end
  end

  def test_save_writes_rules_file_and_leaves_the_yaml_config_untouched
    with_editor do |editor, config_path, _env_path, _state_path, rules_path|
      original = File.binread(config_path)
      view = editor.data
      rules = { "github-main" => { "example/private-repo" => { "SAMPLE_TOKEN" => "include" } } }

      saved = editor.save("revision" => view.fetch("revision"), "rules" => rules)
      stored = CredAlignFlow::Rules.new(rules_path)

      assert_equal "include", stored.rule("github-main", "example/private-repo", "SAMPLE_TOKEN")
      assert_equal 0o600, File.stat(rules_path).mode & 0o777
      assert_equal original, File.binread(config_path)
      refute_equal view.fetch("revision"), saved.fetch("revision")
      refute_includes File.read(rules_path), "very-secret-value-should-not-appear"
    end
  end

  def test_saved_rules_change_plan_assignments_for_the_cli
    with_editor do |editor, config_path, _env_path, _state_path, _rules_path|
      view = editor.data
      rules = {
        "github-main" => {
          "example/repo" => { "SAMPLE_TOKEN" => "exclude" },
          "example/private-repo" => { "SAMPLE_TOKEN" => "include" }
        }
      }
      editor.save("revision" => view.fetch("revision"), "rules" => rules)

      config = CredAlignFlow::Config.new(config_path)
      public_assignment = config.secret_assignment(config.secrets.first, "github-main", TestSupport.repository_metadata)
      private_assignment = config.secret_assignment(
        config.secrets.first,
        "github-main",
        TestSupport.repository_metadata(
          "name" => "private-repo",
          "nameWithOwner" => "example/private-repo",
          "visibility" => "PRIVATE",
          "isPrivate" => true
        )
      )

      assert_equal "excluded_manual", public_assignment.first
      assert_equal "assigned_manual", private_assignment.first
    end
  end

  def test_inventory_refresh_updates_read_only_repository_and_secret_metadata
    provider = FakeProvider.new
    with_editor(providers: { "github-main" => provider }) do |editor, _config_path, _env_path, _state_path, _rules_path|
      view = editor.data
      refreshed = editor.refresh_inventory("revision" => view.fetch("revision"))
      source = refreshed.fetch("sources").first

      assert_equal "current", source.fetch("inventory_state")
      assert_equal 2, source.fetch("repositories").length
      assert_equal [["example/private-repo", "actions"], ["example/repo", "actions"]], provider.secret_calls.sort
      refute_includes JSON.generate(refreshed), "very-secret-value-should-not-appear"
    end
  end

  def test_save_rejects_invalid_rules_and_stale_revisions
    with_editor do |editor, _config_path, _env_path, _state_path, rules_path|
      view = editor.data

      assert_raises(CredAlignFlow::ConfigError) do
        editor.preview(
          "revision" => view.fetch("revision"),
          "rules" => { "github-main" => { "example/repo" => { "SAMPLE_TOKEN" => "sometimes" } } }
        )
      end
      assert_raises(CredAlignFlow::ConfigError) do
        editor.preview(
          "revision" => view.fetch("revision"),
          "rules" => { "github-main" => { "example/repo" => { "UNKNOWN_TOKEN" => "include" } } }
        )
      end
      refute_path_exists rules_path

      File.write(rules_path, JSON.generate("version" => 1, "rules" => {}))
      assert_raises(CredAlignFlow::ConfigEditor::RevisionConflict) do
        editor.save("revision" => view.fetch("revision"), "rules" => {})
      end
    end
  end

  def test_orphan_rules_are_reported_when_repositories_leave_the_inventory
    with_editor do |editor, _config_path, _env_path, _state_path, rules_path|
      view = editor.data
      rules = { "github-main" => { "example/vanished" => { "SAMPLE_TOKEN" => "include" } } }
      saved = editor.save("revision" => view.fetch("revision"), "rules" => rules)
      orphan = saved.fetch("orphan_rules").find { |entry| entry.fetch("repository") == "example/vanished" }

      assert_equal "SAMPLE_TOKEN", orphan.fetch("secret")
      assert_equal "include", orphan.fetch("rule")
      assert_path_exists rules_path
    end
  end

  private

  def with_editor(providers: {})
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.yml")
      env_path = File.join(dir, ".env.local")
      state_path = File.join(dir, "inventory.json")
      rules_path = CredAlignFlow::Rules.default_path_for(config_path)
      File.write(config_path, YAML.dump(config_data(state_path)))
      File.write(env_path, "SAMPLE_TOKEN_VALUE=very-secret-value-should-not-appear\n")
      File.chmod(0o600, config_path)
      File.chmod(0o600, env_path)

      config = CredAlignFlow::Config.new(config_path)
      state = CredAlignFlow::State.new(state_path)
      private_repo = TestSupport.repository_metadata(
        "id" => "7777",
        "name" => "private-repo",
        "nameWithOwner" => "example/private-repo",
        "visibility" => "PRIVATE",
        "isPrivate" => true
      )
      TestSupport.seed_source(
        state,
        "github-main",
        repositories: [TestSupport.repository_metadata, private_repo],
        selection: CredAlignFlow::InventoryCheck.selection_fingerprint(config, "github-main"),
        remote_secrets: {
          "example/repo" => { "actions" => { "SAMPLE_TOKEN" => { "updated_at" => "2020-01-01T00:00:00Z" } } },
          "example/private-repo" => { "actions" => {} }
        }
      )
      repo = state.repository("github-main", "example/repo")
      state.record_application(
        "github-main", repo, "actions", "SAMPLE_TOKEN", "v1",
        fingerprint: CredAlignFlow::Fingerprint.digest("SAMPLE_TOKEN", "very-secret-value-should-not-appear"),
        source_identity: config.source_key("github-main"),
        at: Time.utc(2021, 1, 1)
      )
      state.save!

      editor = CredAlignFlow::ConfigEditor.new(
        config_path: config.path,
        env_path: env_path,
        state_path: state_path,
        providers: providers
      )
      yield editor, config_path, env_path, state_path, rules_path
    end
  end

  def config_data(state_path)
    {
      "version" => 1,
      "state_file" => state_path,
      "sources" => {
        "github-main" => {
          "type" => "github",
          "owner" => "example",
          "repositories" => { "visibility" => "all" }
        }
      },
      "secrets" => [{
        "name" => "SAMPLE_TOKEN",
        "value_env" => "SAMPLE_TOKEN_VALUE",
        "value_digest" => CredAlignFlow::Fingerprint.digest("SAMPLE_TOKEN", "very-secret-value-should-not-appear"),
        "version" => "v1",
        "visibility" => "public",
        "sources" => ["github-main"],
        "targets" => { "github" => ["actions"] }
      }]
    }
  end
end
