# frozen_string_literal: true

require_relative "test_helper"

class InventoryTest < Minitest::Test
  FakeProvider = Struct.new(:repository_list, :secret_calls) do
    def initialize(repository_list, secret_calls)
      super
      @repository_calls = 0
      @repository_metadata_calls = []
    end

    attr_reader :repository_calls, :repository_metadata_calls

    def contexts
      %w[actions dependabot]
    end

    def owner_scoped_context?(_context)
      false
    end

    def validate_context!(context)
      return if contexts.include?(context)

      raise CredAlignFlow::ProviderError, "unsupported context #{context}"
    end

    def repositories
      @repository_calls += 1
      repository_list
    end

    def repository(name)
      @repository_metadata_calls << name
      repository_list.find { |repo| repo["nameWithOwner"] == name } ||
        TestSupport.repository_metadata("name" => name.split("/", 2).last, "nameWithOwner" => name)
    end

    def secrets(repository, context)
      secret_calls << [repository, context]
      [{ "name" => "SONAR_TOKEN", "updatedAt" => "2026-01-01T00:00:00Z" }]
    end
  end

  class OwnerScopeProvider < FakeProvider
    def contexts
      %w[actions user]
    end

    def owner_scoped_context?(context)
      context == "user"
    end
  end

  def test_refresh_records_discovery_and_secret_metadata_for_selected_repositories
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.yml")
      state_path = File.join(dir, "inventory.json")
      File.write(config_path, <<~YAML)
        version: 1
        state_file: #{state_path}
        sources:
          github-main:
            type: github
            owner: example
            repositories:
              visibility: public
              exclude:
                - skipped-repo
        secrets:
          - name: SONAR_TOKEN
            value_env: SONAR_TOKEN_VALUE
            targets:
              github: [actions, dependabot]
      YAML

      repos = [
        repo("selected-repo", "PUBLIC", false, false, false, true),
        repo("skipped-repo", "PUBLIC", false, false, false, true),
        repo("private-repo", "PRIVATE", true, false, false, true),
        repo("readonly-repo", "PUBLIC", false, false, false, false)
      ]
      provider = FakeProvider.new(repos, [])
      config = CredAlignFlow::Config.new(config_path)
      state = CredAlignFlow::State.new(state_path)

      CredAlignFlow::Inventory.new(
        config,
        state,
        {},
        providers: { "github-main" => provider }
      ).refresh!

      repositories = state.data.dig("sources", "github-main", "repositories")

      assert_equal 4, repositories.length
      assert_equal ["example/selected-repo"], state.selected_repositories("github-main").keys
      assert_equal [["example/selected-repo", "actions"], ["example/selected-repo", "dependabot"]], provider.secret_calls
      assert state.remote_secret("github-main", "example/selected-repo", "actions", "SONAR_TOKEN")
    end
  end

  def test_refresh_can_be_limited_to_a_source_pattern
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.yml")
      state_path = File.join(dir, "inventory.json")
      File.write(config_path, <<~YAML)
        version: 1
        state_file: #{state_path}
        sources:
          github-main:
            type: github
            owner: example
            auth_env: GITHUB_MAIN_TOKEN
          github-alt:
            type: github
            owner: example-alt
            auth_env: GITHUB_ALT_TOKEN
        secrets:
          - name: SONAR_TOKEN
            value_env: SONAR_TOKEN_VALUE
            targets:
              github: [actions]
      YAML

      main_provider = FakeProvider.new([repo("main-repo", "PUBLIC", false, false, false, true)], [])
      alt_provider = FakeProvider.new([repo("alt-repo", "PUBLIC", false, false, false, true)], [])
      config = CredAlignFlow::Config.new(config_path)
      state = CredAlignFlow::State.new(state_path)

      refreshed = CredAlignFlow::Inventory.new(
        config,
        state,
        {},
        providers: { "github-main" => main_provider, "github-alt" => alt_provider }
      ).refresh!(source_filter: "github-alt")

      assert_equal ["github-alt"], refreshed
      assert_equal ["github-alt"], state.data.fetch("sources").keys
      assert_empty main_provider.secret_calls
      assert_equal [["example/alt-repo", "actions"]], alt_provider.secret_calls
    end
  end

  def test_context_filtered_refresh_marks_snapshot_partial_and_full_refresh_clears_it
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.yml")
      state_path = File.join(dir, "inventory.json")
      File.write(config_path, <<~YAML)
        version: 1
        state_file: #{state_path}
        sources:
          github-main:
            type: github
            owner: example
            repositories:
              visibility: public
        secrets:
          - name: SONAR_TOKEN
            value_env: SONAR_TOKEN_VALUE
            targets:
              github: [actions, dependabot]
      YAML

      provider = FakeProvider.new([repo("selected-repo", "PUBLIC", false, false, false, true)], [])
      config = CredAlignFlow::Config.new(config_path)
      state = CredAlignFlow::State.new(state_path)
      inventory = CredAlignFlow::Inventory.new(config, state, {}, providers: { "github-main" => provider })

      inventory.refresh!(context_filter: "actions")

      assert_equal [["example/selected-repo", "actions"]], provider.secret_calls
      assert_equal ["actions"], state.refreshed_contexts("github-main")

      provider.secret_calls.clear
      inventory.refresh!

      assert_equal [["example/selected-repo", "actions"], ["example/selected-repo", "dependabot"]],
                   provider.secret_calls
      assert_nil state.refreshed_contexts("github-main")
    end
  end

  def test_include_targets_repositories_without_remote_discovery
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.yml")
      state_path = File.join(dir, "inventory.json")
      File.write(config_path, <<~YAML)
        version: 1
        state_file: #{state_path}
        sources:
          github-main:
            type: github
            owner: example
            repositories:
              include:
                - target-repo
        secrets:
          - name: SONAR_TOKEN
            value_env: SONAR_TOKEN_VALUE
            targets:
              github: [actions]
      YAML

      provider = FakeProvider.new([], [])
      config = CredAlignFlow::Config.new(config_path)
      state = CredAlignFlow::State.new(state_path)

      refreshed = CredAlignFlow::Inventory.new(
        config,
        state,
        {},
        providers: { "github-main" => provider }
      ).refresh!

      assert_equal ["github-main"], refreshed
      assert_equal 0, provider.repository_calls
      assert_equal ["example/target-repo"], provider.repository_metadata_calls
      assert_equal [["example/target-repo", "actions"]], provider.secret_calls
      repository = state.data.dig("sources", "github-main", "repositories", "example/target-repo")

      assert_equal true, repository["explicit"]
      assert_equal true, repository["selected"]
    end
  end

  def test_owner_scope_contexts_are_never_pulled
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.yml")
      state_path = File.join(dir, "inventory.json")
      File.write(config_path, <<~YAML)
        version: 1
        state_file: #{state_path}
        sources:
          forgejo-main:
            type: forgejo
            owner: example
            url: https://forgejo.example
            user_secrets: true
        secrets:
          - name: SONAR_TOKEN
            value_env: SONAR_TOKEN_VALUE
            sources: [forgejo-main]
            targets:
              forgejo: [actions, user]
      YAML

      provider = OwnerScopeProvider.new([repo("selected-repo", "PUBLIC", false, false, false, true)], [])
      config = CredAlignFlow::Config.new(config_path)
      state = CredAlignFlow::State.new(state_path)
      inventory = CredAlignFlow::Inventory.new(config, state, {}, providers: { "forgejo-main" => provider })

      inventory.refresh!

      assert_equal [["example/selected-repo", "actions"]], provider.secret_calls
      assert_empty CredAlignFlow::InventoryCheck.missing_contexts(config, state, "forgejo-main")
      assert_equal "current",
                   CredAlignFlow::InventoryCheck.source_status(config, state, "forgejo-main").fetch("state")

      error = assert_raises(CredAlignFlow::ProviderError) do
        inventory.refresh!(context_filter: "user")
      end
      assert_includes error.message, "owner-scope"
    end
  end

  def test_explicit_non_admin_repository_fails_closed
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.yml")
      state_path = File.join(dir, "state.json")
      File.write(config_path, <<~YAML)
        version: 1
        state_file: #{state_path}
        sources:
          github-main:
            type: github
            owner: example
            repositories:
              include:
                - target-repo
        secrets:
          - name: SONAR_TOKEN
            value_env: SONAR_TOKEN_VALUE
            targets:
              github: [actions]
      YAML
      provider = FakeProvider.new([repo("target-repo", "PRIVATE", true, false, false, false)], [])
      config = CredAlignFlow::Config.new(config_path)
      state = CredAlignFlow::State.new(state_path)

      assert_raises(CredAlignFlow::ProviderError) do
        CredAlignFlow::Inventory.new(config, state, {}, providers: { "github-main" => provider }).refresh!
      end
      assert_equal 0, provider.repository_calls
      assert_equal ["example/target-repo"], provider.repository_metadata_calls
      assert_empty provider.secret_calls
    end
  end

  def test_inventory_status_rejects_old_unidentified_and_truncated_snapshots
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.yml")
      File.write(
        config_path,
        YAML.dump(
          "version" => 1,
          "state_file" => File.join(dir, "inventory.json"),
          "sources" => { "github-main" => { "type" => "github", "owner" => "example" } },
          "secrets" => [{ "name" => "SONAR_TOKEN", "targets" => { "github" => ["actions"] } }]
        )
      )
      config = CredAlignFlow::Config.new(config_path)
      repository = TestSupport.repository_metadata.merge(
        "name_with_owner" => "example/repo",
        "selected" => true,
        "remote_secrets" => { "actions" => {} }
      )
      selection = CredAlignFlow::InventoryCheck.selection_fingerprint(config, "github-main")
      old_state = CredAlignFlow::State.new(File.join(dir, "old.json"))
      old_state.apply_refresh(
        "github-main",
        repositories: { "example/repo" => repository },
        contexts: nil,
        selection: selection,
        discovered_at: (Time.now.utc - CredAlignFlow::InventoryCheck::MAX_AGE_SECONDS - 1).iso8601
      )
      old_status = CredAlignFlow::InventoryCheck.source_status(config, old_state, "github-main")

      assert_equal "stale", old_status.fetch("state")
      assert_includes old_status.fetch("reasons").join(" "), "older"

      legacy_state = CredAlignFlow::State.new(File.join(dir, "legacy.json"))
      legacy_selection = selection.except("identity")
      legacy_state.apply_refresh(
        "github-main",
        repositories: { "example/repo" => repository },
        contexts: nil,
        selection: legacy_selection,
        discovered_at: Time.now.utc.iso8601
      )
      legacy_status = CredAlignFlow::InventoryCheck.source_status(config, legacy_state, "github-main")

      assert_equal "stale", legacy_status.fetch("state")
      assert_includes legacy_status.fetch("reasons").join(" "), "identity was not recorded"

      truncated_state = CredAlignFlow::State.new(File.join(dir, "truncated.json"))
      truncated_state.apply_refresh(
        "github-main",
        repositories: { "example/repo" => repository },
        contexts: nil,
        selection: selection,
        discovered_at: Time.now.utc.iso8601,
        truncated: true
      )

      assert_equal "stale", CredAlignFlow::InventoryCheck.source_status(config, truncated_state, "github-main").fetch("state")
    end
  end

  def test_include_rejects_globs_because_discovery_is_disabled
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.yml")
      File.write(config_path, <<~YAML)
        version: 1
        sources:
          github-main:
            type: github
            owner: example
            repositories:
              include:
                - "repo-*"
        secrets: []
      YAML

      error = assert_raises(CredAlignFlow::ConfigError) do
        CredAlignFlow::Config.new(config_path).repositories_config("github-main")
      end

      assert_includes error.message, "exact names only"
    end
  end

  private

  def repo(name, visibility, private_repo, archived, fork, admin)
    TestSupport.repository_metadata(
      "name" => name,
      "nameWithOwner" => "example/#{name}",
      "visibility" => visibility,
      "isPrivate" => private_repo,
      "isArchived" => archived,
      "isFork" => fork,
      "viewerCanAdminister" => admin
    )
  end
end
