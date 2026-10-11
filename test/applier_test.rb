# frozen_string_literal: true

require_relative "test_helper"
require "json"

class ApplierTest < Minitest::Test
  FakeProvider = Struct.new(:calls, :remote_names, :remote_clock) do
    def initialize(calls, remote_names = [], remote_clock = nil)
      super
    end

    def writable?
      true
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

  class CountLimitedProvider < FakeProvider
    MAX_REPOSITORY_SECRETS = 2
  end

  class SizeLimitedProvider < FakeProvider
    MAX_SECRET_VALUE_BYTES = 4
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
end
