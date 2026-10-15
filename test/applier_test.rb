# frozen_string_literal: true

require_relative "test_helper"
require "json"

class ApplierTest < Minitest::Test
  FakeProvider = Struct.new(:calls, :remote_names, :remote_clock) do
    def initialize(calls, remote_names = [], remote_clock = nil)
      super
    end

    def writable?(_context = nil)
      true
    end

    def owner_scoped_context?(_context)
      false
    end

    def contexts
      %w[actions]
    end

    def secrets(_repository, _context)
      remote_names
    end

    def repository(name)
      TestSupport.repository_metadata("name" => name.split("/").last, "nameWithOwner" => name)
    end

    def set_secret(repository, context, name, value)
      calls << [repository, context, name, value]
      remote_names.reject! { |secret| secret["name"] == name }
      entry = { "name" => name }
      entry["updatedAt"] = (remote_clock || Time.now.utc).iso8601 unless remote_clock == :none
      remote_names << entry
    end
  end

  class OwnerScopeProvider < FakeProvider
    def owner_scoped_context?(context)
      context == "user"
    end
  end

  class CountLimitedProvider < FakeProvider
    MAX_REPOSITORY_SECRETS = 2
  end

  class SizeLimitedProvider < FakeProvider
    MAX_SECRET_VALUE_BYTES = 4
  end

  class PullOnlyProvider < FakeProvider
    def writable?(_context = nil)
      false
    end
  end

  class AdminRevokedProvider < FakeProvider
    def repository(name)
      TestSupport.repository_metadata(
        "name" => name.split("/").last,
        "nameWithOwner" => name,
        "viewerCanAdminister" => false
      )
    end
  end

  # Runs a caller-supplied mutation inside the provider write so the
  # post-write transaction observes a changed local snapshot.
  class MutatingWriteProvider < FakeProvider
    def initialize(calls, remote_names = [], remote_clock = nil, &mutation)
      super(calls, remote_names, remote_clock)
      @mutation = mutation
    end

    def set_secret(repository, context, name, value)
      super
      @mutation&.call
    end
  end

  class MutatingOwnerScopeProvider < MutatingWriteProvider
    def owner_scoped_context?(context)
      context == "user"
    end
  end

  class FailingWriteProvider < FakeProvider
    def set_secret(*)
      raise CredAlignFlow::ProviderError, "synthetic provider failure"
    end
  end

  def test_apply_sets_missing_secret_and_updates_metadata_only_state
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
            version: "2026-10-07"
            targets:
              github: [actions]
      YAML

      config = CredAlignFlow::Config.new(config_path)
      state = CredAlignFlow::State.new(state_path)
      TestSupport.seed_source(
        state, "github-main", selection: CredAlignFlow::InventoryCheck.selection_fingerprint(config, "github-main")
      )
      state.save!

      env_values = { "SONAR_TOKEN_VALUE" => "never-write-me" }
      planner = CredAlignFlow::Planner.new(config, state, env_values)
      provider = FakeProvider.new([])
      outcomes = CredAlignFlow::Applier.new(
        config,
        state,
        env_values,
        providers: { "github-main" => provider }
      ).apply(planner.actionable_items)

      assert_equal ["applied"], outcomes.map(&:status)
      assert_equal [["example/repo", "actions", "SONAR_TOKEN", "never-write-me"]], provider.calls
      record = state.applied_record("github-main", state.repository("github-main", "example/repo"),
                                    "actions", "SONAR_TOKEN")

      assert_equal "2026-10-07", record["version"]
      assert_equal CredAlignFlow::Fingerprint.digest("SONAR_TOKEN", "never-write-me"), record["fingerprint"]
      assert state.remote_secret("github-main", "example/repo", "actions", "SONAR_TOKEN")
      refute_includes File.read(state_path), "never-write-me"
    end
  end

  def test_apply_records_provider_confirmed_timestamp
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
              github: [actions]
      YAML
      config = CredAlignFlow::Config.new(config_path)
      state = CredAlignFlow::State.new(state_path)
      TestSupport.seed_source(
        state, "github-main", selection: CredAlignFlow::InventoryCheck.selection_fingerprint(config, "github-main")
      )
      state.save!

      # The provider's clock is deliberately skewed from the local clock;
      # the applied baseline must record the provider's timestamp.
      remote_time = Time.now.utc + 7200
      provider = FakeProvider.new([], [], remote_time)
      env_values = { "SONAR_TOKEN_VALUE" => "synthetic-value" }
      plan = CredAlignFlow::Planner.new(config, state, env_values)
      outcomes = CredAlignFlow::Applier.new(
        config, state, env_values, providers: { "github-main" => provider }
      ).apply(plan.actionable_items)

      assert_equal ["applied"], outcomes.map(&:status)
      record = state.applied_record("github-main", state.repository("github-main", "example/repo"),
                                    "actions", "SONAR_TOKEN")

      assert_equal remote_time.iso8601, record["applied_remote_at"]
      assert_equal remote_time.iso8601,
                   state.remote_secret("github-main", "example/repo", "actions", "SONAR_TOKEN")["updated_at"]
    end
  end

  def test_apply_writes_owner_scope_secrets_without_repository_guards
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
            version: "2026-10-07"
            sources: [forgejo-main]
            targets:
              forgejo: [user]
      YAML

      config = CredAlignFlow::Config.new(config_path)
      state = CredAlignFlow::State.new(state_path)
      TestSupport.seed_source(
        state, "forgejo-main", selection: CredAlignFlow::InventoryCheck.selection_fingerprint(config, "forgejo-main")
      )
      state.save!

      env_values = { "SONAR_TOKEN_VALUE" => "never-write-me" }
      provider = OwnerScopeProvider.new([])
      plan = CredAlignFlow::Planner.new(config, state, env_values)
      owner_item = plan.plan.find { |item| item.context == "user" }

      assert_equal CredAlignFlow::Provider::OWNER_SCOPE_REPOSITORY, owner_item.repository
      assert_equal "create", owner_item.action

      outcomes = CredAlignFlow::Applier.new(
        config, state, env_values, providers: { "forgejo-main" => provider }
      ).apply(plan.actionable_items)

      assert_equal ["applied"], outcomes.map(&:status)
      assert_equal [["@owner", "user", "SONAR_TOKEN", "never-write-me"]], provider.calls

      record = state.applied_record("forgejo-main", "@owner", "user", "SONAR_TOKEN")

      assert_equal CredAlignFlow::Fingerprint.digest("SONAR_TOKEN", "never-write-me"), record["fingerprint"]
      refute_includes File.read(state_path), "never-write-me"

      # The applied journal now suppresses re-pushes even though the
      # store cannot be listed to confirm the write.
      follow_up = CredAlignFlow::Planner.new(config, state, env_values)

      assert_equal "ok", follow_up.plan.find { |item| item.context == "user" }.action
    end
  end

  def test_apply_without_remote_timestamp_degrades_to_local_baseline
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
              github: [actions]
      YAML
      config = CredAlignFlow::Config.new(config_path)
      state = CredAlignFlow::State.new(state_path)
      TestSupport.seed_source(
        state, "github-main", selection: CredAlignFlow::InventoryCheck.selection_fingerprint(config, "github-main"),
                              remote_secrets: {
                                "example/repo" => { "actions" => { "SONAR_TOKEN" => {} } }
                              }
      )
      state.save!

      # Provider accepts the write but never reports an updated_at.
      provider = FakeProvider.new([], [{ "name" => "SONAR_TOKEN" }], :none)
      env_values = { "SONAR_TOKEN_VALUE" => "synthetic-value" }
      plan = CredAlignFlow::Planner.new(config, state, env_values)
      outcomes = CredAlignFlow::Applier.new(
        config, state, env_values, providers: { "github-main" => provider }
      ).apply(plan.actionable_items(force: true), force: true)

      assert_equal ["applied"], outcomes.map(&:status)
      assert_includes outcomes.first.detail, "local clock"
      record = state.applied_record("github-main", state.repository("github-main", "example/repo"),
                                    "actions", "SONAR_TOKEN")

      assert_nil record["applied_remote_at"]
    end
  end

  def test_applied_fingerprint_tracks_rotation_through_scaffold_and_apply
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
            version: "v1"
            targets:
              github: [actions]
      YAML
      config = CredAlignFlow::Config.new(config_path)
      state = CredAlignFlow::State.new(state_path)
      TestSupport.seed_source(
        state, "github-main", selection: CredAlignFlow::InventoryCheck.selection_fingerprint(config, "github-main")
      )
      state.save!
      provider = FakeProvider.new([])
      old_values = { "SONAR_TOKEN_VALUE" => "synthetic-value-A" }
      initial_plan = CredAlignFlow::Planner.new(config, state, old_values)

      assert_equal "create", initial_plan.plan.first.action
      assert_equal ["applied"], CredAlignFlow::Applier.new(
        config, state, old_values, providers: { "github-main" => provider }
      ).apply(initial_plan.actionable_items).map(&:status)

      rotated_values = { "SONAR_TOKEN_VALUE" => "synthetic-value-B" }
      config = CredAlignFlow::Config.new(config_path)
      CredAlignFlow::Scaffolder.new(config_path).apply!([], config, rotated_values)
      config = CredAlignFlow::Config.new(config_path)
      state = CredAlignFlow::State.new(state_path)
      rotated_plan = CredAlignFlow::Planner.new(config, state, rotated_values)

      assert_equal "update", rotated_plan.plan.first.action
      assert_equal ["applied"], CredAlignFlow::Applier.new(
        config, state, rotated_values, providers: { "github-main" => provider }
      ).apply(rotated_plan.actionable_items).map(&:status)
      assert_equal "ok", CredAlignFlow::Planner.new(
        config, state, rotated_values
      ).plan.first.action
      refute_includes File.read(state_path), "synthetic-value-A"
      refute_includes File.read(state_path), "synthetic-value-B"
    end
  end

  def test_state_save_failure_after_remote_write_is_reported
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
              github: [actions]
      YAML
      config = CredAlignFlow::Config.new(config_path)
      state = CredAlignFlow::State.new(state_path)
      TestSupport.seed_source(
        state, "github-main", selection: CredAlignFlow::InventoryCheck.selection_fingerprint(config, "github-main")
      )
      state.save!
      provider = FakeProvider.new([])
      env_values = { "SONAR_TOKEN_VALUE" => "synthetic-value" }
      plan = CredAlignFlow::Planner.new(config, state, env_values)

      atomic_file_singleton = CredAlignFlow::AtomicFile.singleton_class
      atomic_write = CredAlignFlow::AtomicFile.method(:write)
      atomic_file_singleton.remove_method(:write)
      atomic_file_singleton.define_method(:write) do |*_arguments, **_options|
        raise CredAlignFlow::StateError, "disk full"
      end
      begin
        outcomes = CredAlignFlow::Applier.new(config, state, env_values, providers: { "github-main" => provider })
                                         .apply(plan.actionable_items)
      ensure
        atomic_file_singleton.remove_method(:write)
        atomic_file_singleton.define_method(:write, atomic_write)
      end
      persisted = CredAlignFlow::State.new(state_path)

      assert_equal ["failed"], outcomes.map(&:status)
      assert_includes outcomes.first.detail, "remote write succeeded"
      assert_equal 1, provider.calls.length
      assert_nil persisted.applied_record("github-main", persisted.repository("github-main", "example/repo"),
                                          "actions", "SONAR_TOKEN")
    end
  end

  def test_preflight_blocks_all_items_before_any_write
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
              github: [actions]
          - name: MISSING_TOKEN
            value_env: NO_SUCH_ENV
            targets:
              github: [actions]
      YAML

      config = CredAlignFlow::Config.new(config_path)
      state = CredAlignFlow::State.new(state_path)
      TestSupport.seed_source(
        state, "github-main", selection: CredAlignFlow::InventoryCheck.selection_fingerprint(config, "github-main")
      )
      state.save!

      env_values = { "SONAR_TOKEN_VALUE" => "value-one" }
      planner = CredAlignFlow::Planner.new(config, state, env_values)
      provider = FakeProvider.new([])
      # The full plan includes the missing_value item: it is reported as
      # skipped while the writable item still applies.
      outcomes = CredAlignFlow::Applier.new(
        config, state, env_values, providers: { "github-main" => provider }
      ).apply(planner.plan)

      assert_equal(%w[SONAR_TOKEN], provider.calls.map { |call| call[2] })
      assert_equal %w[skipped applied], outcomes.sort_by { |o| o.item.secret }.map(&:status)
    end
  end

  def test_repository_secret_count_limit_blocks_the_batch_before_writing
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
              github: [actions]
      YAML
      config = CredAlignFlow::Config.new(config_path)
      state = CredAlignFlow::State.new(state_path)
      TestSupport.seed_source(
        state,
        "github-main",
        selection: CredAlignFlow::InventoryCheck.selection_fingerprint(config, "github-main"),
        remote_secrets: {
          "example/repo" => { "actions" => { "EXISTING_ONE" => {}, "EXISTING_TWO" => {} } }
        }
      )
      provider = CountLimitedProvider.new([])
      plan = CredAlignFlow::Planner.new(config, state, { "SONAR_TOKEN_VALUE" => "value" })

      outcomes = CredAlignFlow::Applier.new(
        config, state, { "SONAR_TOKEN_VALUE" => "value" }, providers: { "github-main" => provider }
      ).apply(plan.actionable_items)

      assert_equal ["skipped"], outcomes.map(&:status)
      assert_includes outcomes.first.detail, "2-secret provider limit"
      assert_empty provider.calls
    end
  end

  def test_secret_value_size_limit_blocks_before_writing
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
              github: [actions]
      YAML
      config = CredAlignFlow::Config.new(config_path)
      state = CredAlignFlow::State.new(state_path)
      TestSupport.seed_source(
        state, "github-main", selection: CredAlignFlow::InventoryCheck.selection_fingerprint(config, "github-main")
      )
      provider = SizeLimitedProvider.new([])
      env_values = { "SONAR_TOKEN_VALUE" => "too-long" }
      plan = CredAlignFlow::Planner.new(config, state, env_values)

      outcome = CredAlignFlow::Applier.new(
        config, state, env_values, providers: { "github-main" => provider }
      ).apply(plan.actionable_items).first

      assert_equal "skipped", outcome.status
      assert_includes outcome.detail, "4-byte provider limit"
      assert_empty provider.calls
    end
  end

  def test_remote_timestamp_comparison_uses_fail_closed_provider_baseline
    applier = CredAlignFlow::Applier.allocate
    remote = { "updated_at" => "2026-01-05T00:00:00Z" }
    malformed_provider_baseline = {
      "applied_remote_at" => "not-a-time",
      "applied_at" => "2026-01-10T00:00:00Z"
    }
    legacy_record = { "applied_at" => "2026-01-10T00:00:00Z" }

    assert_equal true, applier.send(:remote_changed_since_apply?, remote, malformed_provider_baseline)
    refute applier.send(:remote_changed_since_apply?, remote, legacy_record)
  end

  def test_create_is_skipped_when_remote_appears_after_the_plan
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
              github: [actions]
      YAML

      config = CredAlignFlow::Config.new(config_path)
      state = CredAlignFlow::State.new(state_path)
      TestSupport.seed_source(
        state, "github-main", selection: CredAlignFlow::InventoryCheck.selection_fingerprint(config, "github-main")
      )
      state.save!

      env_values = { "SONAR_TOKEN_VALUE" => "value-one" }
      planner = CredAlignFlow::Planner.new(config, state, env_values)
      # The remote re-check sees the secret already exists.
      provider = FakeProvider.new([], [{ "name" => "SONAR_TOKEN" }])
      outcomes = CredAlignFlow::Applier.new(
        config, state, env_values, providers: { "github-main" => provider }
      ).apply(planner.actionable_items(force: true), force: true)

      assert_equal ["skipped"], outcomes.map(&:status)
      assert_empty provider.calls
      assert_nil state.applied_record("github-main", state.repository("github-main", "example/repo"),
                                      "actions", "SONAR_TOKEN")
    end
  end

  def test_pull_only_source_skips_the_write
    seeded_github_source do |config, state, _state_path|
      provider = PullOnlyProvider.new([])
      env_values = { "SONAR_TOKEN_VALUE" => "synthetic-value" }
      plan = CredAlignFlow::Planner.new(config, state, env_values)
      outcome = CredAlignFlow::Applier.new(
        config, state, env_values, providers: { "github-main" => provider }
      ).apply(plan.actionable_items).first

      assert_equal "skipped", outcome.status
      assert_includes outcome.detail, "pull-only"
      assert_empty provider.calls
    end
  end

  def test_repository_admin_recheck_skips_before_any_write
    seeded_github_source do |config, state, _state_path|
      provider = AdminRevokedProvider.new([])
      env_values = { "SONAR_TOKEN_VALUE" => "synthetic-value" }
      plan = CredAlignFlow::Planner.new(config, state, env_values)
      outcome = CredAlignFlow::Applier.new(
        config, state, env_values, providers: { "github-main" => provider }
      ).apply(plan.actionable_items).first

      assert_equal "skipped", outcome.status
      assert_includes outcome.detail, "repository identity or admin permission changed"
      assert_empty provider.calls
    end
  end

  def test_provider_failure_during_write_is_reported_as_failed
    seeded_github_source do |config, state, _state_path|
      provider = FailingWriteProvider.new([])
      env_values = { "SONAR_TOKEN_VALUE" => "synthetic-value" }
      plan = CredAlignFlow::Planner.new(config, state, env_values)
      outcome = CredAlignFlow::Applier.new(
        config, state, env_values, providers: { "github-main" => provider }
      ).apply(plan.actionable_items).first

      assert_equal "failed", outcome.status
      assert_includes outcome.detail, "synthetic provider failure"
      assert_nil state.applied_record("github-main", state.repository("github-main", "example/repo"),
                                      "actions", "SONAR_TOKEN")
    end
  end

  def test_state_change_during_write_fails_after_the_remote_write
    seeded_github_source do |config, state, state_path|
      # The transaction re-reads the state file, so the mutation must
      # land on disk inside the provider write.
      provider = MutatingWriteProvider.new([]) do
        data = JSON.parse(File.read(state_path))
        data.fetch("sources").fetch("github-main").fetch("repositories").delete("example/repo")
        File.write(state_path, JSON.pretty_generate(data))
      end
      env_values = { "SONAR_TOKEN_VALUE" => "synthetic-value" }
      plan = CredAlignFlow::Planner.new(config, state, env_values)
      outcome = CredAlignFlow::Applier.new(
        config, state, env_values, providers: { "github-main" => provider }
      ).apply(plan.actionable_items).first
      persisted = CredAlignFlow::State.new(state_path)

      assert_equal "failed", outcome.status
      assert_includes outcome.detail, "remote write succeeded"
      assert_equal 1, provider.calls.length
      assert_nil persisted.applied_record("github-main", persisted.repository("github-main", "example/repo"),
                                          "actions", "SONAR_TOKEN")
    end
  end

  def test_update_is_skipped_when_the_remote_secret_disappears_after_the_plan
    seeded_github_source do |config, state, _state_path|
      provider = FakeProvider.new([])
      initial_values = { "SONAR_TOKEN_VALUE" => "synthetic-value-A" }
      plan = CredAlignFlow::Planner.new(config, state, initial_values)

      assert_equal ["applied"], CredAlignFlow::Applier.new(
        config, state, initial_values, providers: { "github-main" => provider }
      ).apply(plan.actionable_items).map(&:status)

      rotated_values = { "SONAR_TOKEN_VALUE" => "synthetic-value-B" }
      update_plan = CredAlignFlow::Planner.new(config, state, rotated_values)

      assert_equal "update", update_plan.plan.first.action

      # The secret vanishes between the plan and the write.
      provider.remote_names.clear
      outcome = CredAlignFlow::Applier.new(
        config, state, rotated_values, providers: { "github-main" => provider }
      ).apply(update_plan.actionable_items).first

      assert_equal "skipped", outcome.status
      assert_includes outcome.detail, "disappeared after the plan"
      assert_equal 1, provider.calls.length
    end
  end

  def test_update_is_skipped_when_the_remote_changed_after_the_plan_unless_forced
    seeded_github_source do |config, state, _state_path|
      remote_time = Time.now.utc + 7200
      provider = FakeProvider.new([], [], remote_time)
      initial_values = { "SONAR_TOKEN_VALUE" => "synthetic-value-A" }
      plan = CredAlignFlow::Planner.new(config, state, initial_values)

      assert_equal ["applied"], CredAlignFlow::Applier.new(
        config, state, initial_values, providers: { "github-main" => provider }
      ).apply(plan.actionable_items).map(&:status)

      rotated_values = { "SONAR_TOKEN_VALUE" => "synthetic-value-B" }
      update_plan = CredAlignFlow::Planner.new(config, state, rotated_values)

      assert_equal "update", update_plan.plan.first.action

      # The remote entry moved past the provider-confirmed apply baseline.
      remote = provider.remote_names.find { |secret| secret["name"] == "SONAR_TOKEN" }
      remote["updatedAt"] = (remote_time + 3600).iso8601
      outcome = CredAlignFlow::Applier.new(
        config, state, rotated_values, providers: { "github-main" => provider }
      ).apply(update_plan.actionable_items).first

      assert_equal "skipped", outcome.status
      assert_includes outcome.detail, "changed after the plan"
      assert_equal 1, provider.calls.length

      forced = CredAlignFlow::Applier.new(
        config, state, rotated_values, providers: { "github-main" => provider }
      ).apply(update_plan.actionable_items(force: true), force: true).first

      assert_equal "applied", forced.status
      assert_equal 2, provider.calls.length
    end
  end

  def test_create_is_skipped_when_the_remote_grew_past_the_provider_limit
    # Preflight counts the inventory snapshot (one known secret), while
    # the write-time re-check sees the provider already at its limit.
    remote_secrets = { "example/repo" => { "actions" => { "EXISTING_ONE" => {} } } }
    seeded_github_source(remote_secrets: remote_secrets) do |config, state, _state_path|
      provider = CountLimitedProvider.new(
        [], [{ "name" => "EXISTING_ONE" }, { "name" => "EXISTING_TWO" }]
      )
      env_values = { "SONAR_TOKEN_VALUE" => "synthetic-value" }
      plan = CredAlignFlow::Planner.new(config, state, env_values)

      assert_equal "create", plan.plan.find { |item| item.secret == "SONAR_TOKEN" }.action
      outcome = CredAlignFlow::Applier.new(
        config, state, env_values, providers: { "github-main" => provider }
      ).apply(plan.actionable_items).first

      assert_equal "skipped", outcome.status
      assert_includes outcome.detail, "already has the 2-secret provider limit"
      assert_empty provider.calls
    end
  end

  def test_owner_scope_write_reports_state_failure_after_the_remote_write
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
              forgejo: [user]
      YAML
      config = CredAlignFlow::Config.new(config_path)
      state = CredAlignFlow::State.new(state_path)
      TestSupport.seed_source(
        state, "forgejo-main", selection: CredAlignFlow::InventoryCheck.selection_fingerprint(config, "forgejo-main")
      )
      state.save!

      provider = MutatingOwnerScopeProvider.new([]) do
        data = JSON.parse(File.read(state_path))
        data.fetch("sources").fetch("forgejo-main")["identity"] = "changed-during-write"
        File.write(state_path, JSON.pretty_generate(data))
      end
      env_values = { "SONAR_TOKEN_VALUE" => "synthetic-value" }
      plan = CredAlignFlow::Planner.new(config, state, env_values)
      outcome = CredAlignFlow::Applier.new(
        config, state, env_values, providers: { "forgejo-main" => provider }
      ).apply(plan.actionable_items).first

      assert_equal "failed", outcome.status
      assert_includes outcome.detail, "remote write succeeded"
      assert_equal 1, provider.calls.length
      assert_nil CredAlignFlow::State.new(state_path).applied_record(
        "forgejo-main", CredAlignFlow::Provider::OWNER_SCOPE_REPOSITORY, "user", "SONAR_TOKEN"
      )
    end
  end

  private

  def seeded_github_source(remote_secrets: {})
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
              github: [actions]
      YAML
      config = CredAlignFlow::Config.new(config_path)
      state = CredAlignFlow::State.new(state_path)
      TestSupport.seed_source(
        state, "github-main",
        selection: CredAlignFlow::InventoryCheck.selection_fingerprint(config, "github-main"),
        remote_secrets: remote_secrets
      )
      state.save!
      yield config, state, state_path
    end
  end
end
