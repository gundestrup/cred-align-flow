# frozen_string_literal: true

require_relative "test_helper"
require "time"

class PlannerTest < Minitest::Test
  def test_detects_missing_unverified_and_unexpected_remote_secrets
    Dir.mktmpdir do |dir|
      config = build_config(dir)
      state = CredAlignFlow::State.new(File.join(dir, "inventory.json"))
      TestSupport.seed_source(
        state,
        "github-main",
        remote_secrets: {
          "example/repo" => {
            "actions" => { "UNMANAGED" => { "updated_at" => "2026-01-01T00:00:00Z" } },
            "dependabot" => { "SONAR_TOKEN" => { "updated_at" => "2026-01-01T00:00:00Z" } }
          }
        }
      )

      planner = CredAlignFlow::Planner.new(config, state, { "SONAR_TOKEN_VALUE" => "redacted" })
      actions = planner.plan.map { |item| [item.context, item.secret, item.action] }

      assert_includes actions, %w[actions SONAR_TOKEN create]
      assert_includes actions, %w[dependabot SONAR_TOKEN unverified_present]
      assert_includes actions, %w[actions UNMANAGED unexpected]
    end
  end

  def test_value_rotation_produces_update_even_without_version_change
    Dir.mktmpdir do |dir|
      config = build_config(dir, version: "v1", version_at: "2026-01-01T00:00:00Z")
      state = CredAlignFlow::State.new(File.join(dir, "inventory.json"))
      TestSupport.seed_source(
        state,
        "github-main",
        remote_secrets: {
          "example/repo" => {
            "actions" => { "SONAR_TOKEN" => { "updated_at" => "2026-01-01T00:00:00Z" } },
            "dependabot" => { "SONAR_TOKEN" => { "updated_at" => "2026-01-04T00:00:00Z" } }
          }
        }
      )
      repo = state.repository("github-main", "example/repo")
      # The pushed fingerprint of "old-value" differs from the desired
      # fingerprint of "redacted": the plan must update, version or not.
      state.record_application("github-main", repo, "actions", "SONAR_TOKEN", "v1",
                               fingerprint: CredAlignFlow::Fingerprint.digest("SONAR_TOKEN", "old-value"),
                               source_identity: config.source_key("github-main"), at: Time.utc(2026, 1, 2))
      state.record_application("github-main", repo, "dependabot", "SONAR_TOKEN", "v1",
                               fingerprint: CredAlignFlow::Fingerprint.digest("SONAR_TOKEN", "redacted"),
                               source_identity: config.source_key("github-main"), at: Time.utc(2026, 1, 3))

      planner = CredAlignFlow::Planner.new(config, state, { "SONAR_TOKEN_VALUE" => "redacted" })
      actions = planner.plan.map { |item| [item.context, item.action] }

      assert_includes actions, %w[actions update]
      assert_includes actions, %w[dependabot remote_newer]

      remote_newer = planner.plan.find { |item| item.action == "remote_newer" }

      refute_includes planner.actionable_items, remote_newer
      assert_includes planner.actionable_items(force: true), remote_newer

      filtered = CredAlignFlow::Planner.new(
        config,
        state,
        { "SONAR_TOKEN_VALUE" => "redacted" },
        context_filter: "dependabot"
      )

      assert_equal([%w[dependabot remote_newer]], filtered.plan.map { |item| [item.context, item.action] })
    end
  end

  def test_matching_applied_fingerprint_reports_ok
    Dir.mktmpdir do |dir|
      config = build_config(dir)
      state = CredAlignFlow::State.new(File.join(dir, "inventory.json"))
      TestSupport.seed_source(
        state,
        "github-main",
        remote_secrets: {
          "example/repo" => {
            "actions" => { "SONAR_TOKEN" => { "updated_at" => "2000-01-01T00:00:00Z" } },
            "dependabot" => { "SONAR_TOKEN" => { "updated_at" => "2000-01-01T00:00:00Z" } }
          }
        }
      )
      repo = state.repository("github-main", "example/repo")
      %w[actions dependabot].each do |context|
        state.record_application("github-main", repo, context, "SONAR_TOKEN", "2026-10-07",
                                 fingerprint: CredAlignFlow::Fingerprint.digest("SONAR_TOKEN", "redacted"),
                                 source_identity: config.source_key("github-main"), at: Time.utc(2026, 1, 2))
      end

      planner = CredAlignFlow::Planner.new(config, state, { "SONAR_TOKEN_VALUE" => "redacted" })

      assert(planner.plan.all? { |item| item.action == "ok" })
      assert_empty planner.actionable_items(force: true)
    end
  end

  def test_repository_replacement_invalidates_applied_record
    Dir.mktmpdir do |dir|
      config = build_config(dir)
      state = CredAlignFlow::State.new(File.join(dir, "inventory.json"))
      # The applied journal was written against repo id 4242.
      state.record_application("github-main", TestSupport.repository_metadata("id" => "4242"),
                               "actions", "SONAR_TOKEN", "v1",
                               fingerprint: CredAlignFlow::Fingerprint.digest("SONAR_TOKEN", "redacted"),
                               source_identity: config.source_key("github-main"), at: Time.utc(2026, 1, 2))
      TestSupport.seed_source(
        state,
        "github-main",
        repositories: [TestSupport.repository_metadata("id" => "9999")],
        remote_secrets: {
          "example/repo" => { "actions" => { "SONAR_TOKEN" => { "updated_at" => "2000-01-01T00:00:00Z" } } }
        }
      )

      planner = CredAlignFlow::Planner.new(config, state, { "SONAR_TOKEN_VALUE" => "redacted" })
      actions_item = planner.plan.find { |item| item.context == "actions" }

      assert_equal "unverified_present", actions_item.action
      assert(planner.plan.none? { |item| item.action == "ok" })
    end
  end

  def test_applied_record_from_a_rebound_source_requires_adoption
    Dir.mktmpdir do |dir|
      original_config = build_config(dir)
      state = CredAlignFlow::State.new(File.join(dir, "inventory.json"))
      TestSupport.seed_source(
        state,
        "github-main",
        remote_secrets: {
          "example/repo" => { "actions" => { "SONAR_TOKEN" => { "updated_at" => "2000-01-01T00:00:00Z" } } }
        }
      )
      repo = state.repository("github-main", "example/repo")
      state.record_application(
        "github-main", repo, "actions", "SONAR_TOKEN", "v1",
        fingerprint: CredAlignFlow::Fingerprint.digest("SONAR_TOKEN", "redacted"),
        source_identity: original_config.source_key("github-main"), at: Time.utc(2026, 1, 2)
      )
      raw = YAML.safe_load_file(original_config.path, aliases: false)
      raw.fetch("sources").fetch("github-main")["owner"] = "replacement-owner"
      File.write(original_config.path, YAML.dump(raw))
      rebound_config = CredAlignFlow::Config.new(original_config.path)
      planner = CredAlignFlow::Planner.new(rebound_config, state, { "SONAR_TOKEN_VALUE" => "redacted" })

      assert_equal "unverified_present", planner.plan.find { |item| item.context == "actions" }.action
    end
  end

  def test_desired_version_time_does_not_bypass_remote_newer_guard
    Dir.mktmpdir do |dir|
      # version_at is newer than the remote timestamp — it must NOT be
      # compared against remote; only applied_at proves our last write.
      config = build_config(dir, version: "v9", version_at: "2026-07-01T00:00:00Z")
      state = CredAlignFlow::State.new(File.join(dir, "inventory.json"))
      TestSupport.seed_source(
        state,
        "github-main",
        remote_secrets: {
          "example/repo" => { "actions" => { "SONAR_TOKEN" => { "updated_at" => "2026-06-01T00:00:00Z" } } }
        }
      )
      repo = state.repository("github-main", "example/repo")
      state.record_application("github-main", repo, "actions", "SONAR_TOKEN", "v9",
                               fingerprint: CredAlignFlow::Fingerprint.digest("SONAR_TOKEN", "redacted"),
                               source_identity: config.source_key("github-main"), at: Time.utc(2026, 1, 1))

      planner = CredAlignFlow::Planner.new(config, state, { "SONAR_TOKEN_VALUE" => "redacted" })
      item = planner.plan.find { |entry| entry.context == "actions" }

      assert_equal "remote_newer", item.action
    end
  end

  def test_provider_confirmed_apply_timestamp_defeats_local_clock_skew
    Dir.mktmpdir do |dir|
      # Local clock ran fast: applied_at (local) is ahead of the remote
      # updated_at, so a local-only comparison would miss the drift. The
      # provider-confirmed applied_remote_at is in the remote clock's
      # domain and must win.
      config = build_config(dir)
      state = CredAlignFlow::State.new(File.join(dir, "inventory.json"))
      TestSupport.seed_source(
        state,
        "github-main",
        remote_secrets: {
          "example/repo" => { "actions" => { "SONAR_TOKEN" => { "updated_at" => "2026-01-05T00:00:00Z" } } }
        }
      )
      repo = state.repository("github-main", "example/repo")
      state.record_application("github-main", repo, "actions", "SONAR_TOKEN", "v1",
                               fingerprint: CredAlignFlow::Fingerprint.digest("SONAR_TOKEN", "redacted"),
                               source_identity: config.source_key("github-main"),
                               applied_remote_at: Time.utc(2026, 1, 2), at: Time.utc(2026, 1, 10))

      planner = CredAlignFlow::Planner.new(config, state, { "SONAR_TOKEN_VALUE" => "redacted" })
      item = planner.plan.find { |entry| entry.context == "actions" }

      assert_equal "remote_newer", item.action
      assert_includes item.detail, "provider-confirmed apply"
    end
  end

  def test_legacy_record_without_provider_timestamp_uses_local_apply_time
    Dir.mktmpdir do |dir|
      config = build_config(dir)
      state = CredAlignFlow::State.new(File.join(dir, "inventory.json"))
      TestSupport.seed_source(
        state,
        "github-main",
        remote_secrets: {
          "example/repo" => { "actions" => { "SONAR_TOKEN" => { "updated_at" => "2026-01-05T00:00:00Z" } } }
        }
      )
      repo = state.repository("github-main", "example/repo")
      state.record_application("github-main", repo, "actions", "SONAR_TOKEN", "v1",
                               fingerprint: CredAlignFlow::Fingerprint.digest("SONAR_TOKEN", "redacted"),
                               source_identity: config.source_key("github-main"), at: Time.utc(2026, 1, 10))

      planner = CredAlignFlow::Planner.new(config, state, { "SONAR_TOKEN_VALUE" => "redacted" })
      item = planner.plan.find { |entry| entry.context == "actions" }

      assert_equal "ok", item.action
    end
  end

  def test_invalid_provider_timestamp_is_conservative
    Dir.mktmpdir do |dir|
      config = build_config(dir)
      state = CredAlignFlow::State.new(File.join(dir, "inventory.json"))
      TestSupport.seed_source(
        state,
        "github-main",
        remote_secrets: {
          "example/repo" => { "actions" => { "SONAR_TOKEN" => { "updated_at" => "2026-01-05T00:00:00Z" } } }
        }
      )
      repo = state.repository("github-main", "example/repo")
      state.record_application("github-main", repo, "actions", "SONAR_TOKEN", "v1",
                               fingerprint: CredAlignFlow::Fingerprint.digest("SONAR_TOKEN", "redacted"),
                               source_identity: config.source_key("github-main"), at: Time.utc(2026, 1, 10))
      key = state.data["applied"].keys.first
      state.data["applied"][key]["applied_remote_at"] = "not-a-time"

      planner = CredAlignFlow::Planner.new(config, state, { "SONAR_TOKEN_VALUE" => "redacted" })
      item = planner.plan.find { |entry| entry.context == "actions" }

      assert_equal "remote_newer", item.action
    end
  end

  def test_repository_rules_include_or_exclude_a_repo_over_token_defaults
    Dir.mktmpdir do |dir|
      config = build_config(
        dir,
        secret_options: {
          "repository_rules" => {
            "github-main" => {
              "example/repo" => "exclude",
              "example/private-repo" => "include"
            }
          }
        }
      )
      state = CredAlignFlow::State.new(File.join(dir, "inventory.json"))
      private_repo = TestSupport.repository_metadata(
        "name" => "private-repo",
        "nameWithOwner" => "example/private-repo",
        "visibility" => "PRIVATE",
        "isPrivate" => true
      )
      TestSupport.seed_source(state, "github-main", repositories: [TestSupport.repository_metadata, private_repo])

      planner = CredAlignFlow::Planner.new(config, state, { "SONAR_TOKEN_VALUE" => "redacted" })
      items = planner.plan

      assert_equal ["example/private-repo"], items.map(&:repository).uniq
      assert_equal %w[actions dependabot], items.map(&:context).sort
      public_repo_assignment = config.secret_assignment(
        config.secrets.first, "github-main", TestSupport.repository_metadata
      ).first
      private_repo_assignment = config.secret_assignment(config.secrets.first, "github-main", private_repo).first

      assert_equal "excluded_manual", public_repo_assignment
      assert_equal "assigned_manual", private_repo_assignment
    end
  end

  def test_explicit_source_exclusion_wins_over_repository_include
    Dir.mktmpdir do |dir|
      config = build_config(
        dir,
        secret_options: {
          "exclude_sources" => ["github-main"],
          "repository_rules" => { "github-main" => { "example/repo" => "include" } }
        }
      )
      state = CredAlignFlow::State.new(File.join(dir, "inventory.json"))
      TestSupport.seed_source(state, "github-main")

      planner = CredAlignFlow::Planner.new(config, state, { "SONAR_TOKEN_VALUE" => "redacted" })

      assert_empty planner.plan
      assignment = config.secret_assignment(config.secrets.first, "github-main", TestSupport.repository_metadata).first

      assert_equal "excluded_manual", assignment
    end
  end

  def test_repository_default_override_cancels_legacy_exclusion
    Dir.mktmpdir do |dir|
      config = build_config(
        dir,
        secret_options: {
          "exclude_repositories" => { "github-main" => ["example/*"] },
          "repository_rules" => { "github-main" => { "example/repo" => "default" } }
        }
      )
      state = CredAlignFlow::State.new(File.join(dir, "inventory.json"))
      TestSupport.seed_source(state, "github-main")

      planner = CredAlignFlow::Planner.new(config, state, { "SONAR_TOKEN_VALUE" => "redacted" })

      assert_equal %w[actions dependabot], planner.plan.map(&:context).sort
      assignment = config.secret_assignment(config.secrets.first, "github-main", TestSupport.repository_metadata).first

      assert_equal "assigned_default", assignment
    end
  end

  def test_rules_file_overrides_token_defaults_and_outranks_yaml_repository_rules
    Dir.mktmpdir do |dir|
      config = build_config(
        dir,
        secret_options: { "repository_rules" => { "github-main" => { "example/repo" => "include" } } },
        rules: { "github-main" => { "example/repo" => { "SONAR_TOKEN" => "exclude" } } }
      )
      state = CredAlignFlow::State.new(File.join(dir, "inventory.json"))
      TestSupport.seed_source(state, "github-main")

      planner = CredAlignFlow::Planner.new(config, state, { "SONAR_TOKEN_VALUE" => "redacted" })

      assert_empty planner.plan
      assignment = config.secret_assignment(config.secrets.first, "github-main", TestSupport.repository_metadata).first

      assert_equal "excluded_manual", assignment
    end
  end

  def test_rules_file_include_selects_a_source_outside_default_scope
    Dir.mktmpdir do |dir|
      config = build_config(
        dir,
        extra_sources: { "github-alt" => { "type" => "github", "owner" => "example-alt", "host" => "ghe.example.test" } },
        secret_options: { "sources" => ["github-alt"] },
        rules: { "github-main" => { "example/repo" => { "SONAR_TOKEN" => "include" } } }
      )
      state = CredAlignFlow::State.new(File.join(dir, "inventory.json"))
      TestSupport.seed_source(state, "github-main")

      assert config.secret_applies_to_source?(config.secrets.first, "github-main")
      planner = CredAlignFlow::Planner.new(config, state, { "SONAR_TOKEN_VALUE" => "redacted" })

      assert_equal %w[actions dependabot], planner.plan.map(&:context).sort
    end
  end

  def test_explicit_repo_with_unknown_visibility_fails_closed
    Dir.mktmpdir do |dir|
      config = build_config(dir)
      state = CredAlignFlow::State.new(File.join(dir, "inventory.json"))
      private_repo = TestSupport.repository_metadata(
        "name" => "private-repo",
        "nameWithOwner" => "example/private-repo",
        "visibility" => "unknown",
        "isPrivate" => nil,
        "explicit" => true
      )
      TestSupport.seed_source(state, "github-main", repositories: [private_repo])

      planner = CredAlignFlow::Planner.new(config, state, { "SONAR_TOKEN_VALUE" => "redacted" })

      assert_raises(CredAlignFlow::Error) { planner.plan }
    end
  end

  def test_malformed_remote_timestamp_is_conservative
    Dir.mktmpdir do |dir|
      config = build_config(dir, version: "v1", version_at: "2026-01-01T00:00:00Z")
      state = CredAlignFlow::State.new(File.join(dir, "inventory.json"))
      TestSupport.seed_source(
        state,
        "github-main",
        remote_secrets: {
          "example/repo" => { "actions" => { "SONAR_TOKEN" => { "updated_at" => "not-a-time" } } }
        }
      )
      repo = state.repository("github-main", "example/repo")
      state.record_application("github-main", repo, "actions", "SONAR_TOKEN", "v1",
                               source_identity: config.source_key("github-main"), at: Time.utc(2026, 1, 2))

      planner = CredAlignFlow::Planner.new(config, state, { "SONAR_TOKEN_VALUE" => "redacted" })
      item = planner.plan.find { |entry| entry.context == "actions" }

      assert_equal "remote_newer", item.action
      assert_match(/invalid/, item.detail)
    end
  end

  def test_plan_item_actionability_matches_the_force_policy
    actions = %w[create update unverified_present remote_newer ok missing_value pull_only unexpected unknown]
    expected = {
      false => %w[create update],
      true => %w[create update unverified_present remote_newer]
    }

    expected.each do |force, actionable|
      selected = actions.select do |action|
        CredAlignFlow::Planner::Item.new(action: action).actionable?(force: force)
      end

      assert_equal actionable, selected
    end
  end

  def test_every_planner_action_is_listed_in_ui_metadata
    Dir.mktmpdir do |dir|
      # Exercise a mix of outcomes: ok would need an applied record, but
      # the emitted vocabulary here must always be a subset the UI knows.
      config = build_config(dir)
      state = CredAlignFlow::State.new(File.join(dir, "inventory.json"))
      TestSupport.seed_source(
        state,
        "github-main",
        remote_secrets: {
          "example/repo" => {
            "actions" => { "SONAR_TOKEN" => { "updated_at" => "2000-01-01T00:00:00Z" },
                           "REMOTE_ONLY" => { "updated_at" => "2000-01-01T00:00:00Z" } }
          }
        }
      )

      actions = CredAlignFlow::Planner.new(config, state, { "SONAR_TOKEN_VALUE" => "redacted" })
                                      .plan.map(&:action).uniq

      actions.each do |action|
        assert_includes CredAlignFlow::UiMetadata::STATUSES, action,
                        "planner action #{action} has no UiMetadata entry — the UI would misrender it"
      end
    end
  end

  def test_owner_scope_plans_one_blind_item_per_source
    Dir.mktmpdir do |dir|
      config = build_forgejo_config(dir)
      state = CredAlignFlow::State.new(File.join(dir, "inventory.json"))
      TestSupport.seed_source(
        state,
        "forgejo-main",
        repositories: [
          TestSupport.repository_metadata,
          TestSupport.repository_metadata("name" => "other", "nameWithOwner" => "example/other")
        ],
        selection: CredAlignFlow::InventoryCheck.selection_fingerprint(config, "forgejo-main")
      )

      items = CredAlignFlow::Planner.new(config, state, { "SONAR_TOKEN_VALUE" => "redacted" }).plan
      owner_items = items.select { |item| item.repository == CredAlignFlow::Provider::OWNER_SCOPE_REPOSITORY }
      repo_items = items.select { |item| item.context == "actions" }

      assert_equal 1, owner_items.length
      assert_equal "user", owner_items.first.context
      assert_equal "create", owner_items.first.action
      assert_includes owner_items.first.detail, "cannot be listed"
      assert_equal %w[pull_only pull_only], repo_items.map(&:action)
    end
  end

  def test_owner_scope_compares_against_the_applied_journal
    Dir.mktmpdir do |dir|
      config = build_forgejo_config(dir)
      state = CredAlignFlow::State.new(File.join(dir, "inventory.json"))
      TestSupport.seed_source(
        state,
        "forgejo-main",
        selection: CredAlignFlow::InventoryCheck.selection_fingerprint(config, "forgejo-main")
      )
      state.record_application(
        "forgejo-main", CredAlignFlow::Provider::OWNER_SCOPE_REPOSITORY, "user", "SONAR_TOKEN", "v1",
        fingerprint: CredAlignFlow::Fingerprint.digest("SONAR_TOKEN", "redacted"),
        source_identity: config.source_key("forgejo-main"), at: Time.utc(2026, 1, 2)
      )

      planner = CredAlignFlow::Planner.new(config, state, { "SONAR_TOKEN_VALUE" => "redacted" })
      owner_item = planner.plan.find { |item| item.context == "user" }

      assert_equal "ok", owner_item.action
      assert_includes owner_item.detail, "not enumerable"
    end
  end

  def test_owner_scope_update_when_the_local_value_changed
    Dir.mktmpdir do |dir|
      config = build_forgejo_config(dir)
      state = CredAlignFlow::State.new(File.join(dir, "inventory.json"))
      TestSupport.seed_source(
        state,
        "forgejo-main",
        selection: CredAlignFlow::InventoryCheck.selection_fingerprint(config, "forgejo-main")
      )
      state.record_application(
        "forgejo-main", CredAlignFlow::Provider::OWNER_SCOPE_REPOSITORY, "user", "SONAR_TOKEN", "v1",
        fingerprint: CredAlignFlow::Fingerprint.digest("SONAR_TOKEN", "old-value"),
        source_identity: config.source_key("forgejo-main"), at: Time.utc(2026, 1, 2)
      )

      planner = CredAlignFlow::Planner.new(config, state, { "SONAR_TOKEN_VALUE" => "redacted" })
      owner_item = planner.plan.find { |item| item.context == "user" }

      assert_equal "update", owner_item.action
    end
  end

  def test_owner_scope_fails_closed_without_a_source_snapshot
    Dir.mktmpdir do |dir|
      config = build_forgejo_config(dir)
      state = CredAlignFlow::State.new(File.join(dir, "inventory.json"))

      planner = CredAlignFlow::Planner.new(config, state, { "SONAR_TOKEN_VALUE" => "redacted" })
      owner_item = planner.plan.find { |item| item.context == "user" }

      assert_equal "not_checked", owner_item.action
      refute_includes planner.actionable_items, owner_item
    end
  end

  def test_owner_scope_reports_missing_values
    Dir.mktmpdir do |dir|
      config = build_forgejo_config(dir)
      state = CredAlignFlow::State.new(File.join(dir, "inventory.json"))
      TestSupport.seed_source(
        state,
        "forgejo-main",
        selection: CredAlignFlow::InventoryCheck.selection_fingerprint(config, "forgejo-main")
      )

      planner = CredAlignFlow::Planner.new(config, state, {})
      owner_item = planner.plan.find { |item| item.context == "user" }

      assert_equal "missing_value", owner_item.action
    end
  end

  def test_owner_scope_is_excluded_by_repo_filters
    Dir.mktmpdir do |dir|
      config = build_forgejo_config(dir)
      state = CredAlignFlow::State.new(File.join(dir, "inventory.json"))
      TestSupport.seed_source(
        state,
        "forgejo-main",
        selection: CredAlignFlow::InventoryCheck.selection_fingerprint(config, "forgejo-main")
      )

      planner = CredAlignFlow::Planner.new(
        config, state, { "SONAR_TOKEN_VALUE" => "redacted" }, repo_filter: "example/repo"
      )

      assert_empty(planner.plan.select { |item| item.context == "user" })
    end
  end

  private

  def build_forgejo_config(dir)
    build_config(dir,
                 extra_sources: {
                   "forgejo-main" => {
                     "type" => "forgejo",
                     "owner" => "example",
                     "url" => "https://forgejo.example",
                     "user_secrets" => true
                   }
                 },
                 secret_options: {
                   "sources" => ["forgejo-main"],
                   "targets" => { "forgejo" => %w[actions user] }
                 })
  end

  def build_config(dir, version: "2026-10-07", version_at: nil, secret_options: {}, extra_sources: {}, rules: nil)
    path = File.join(dir, "config.yml")
    secret = {
      "name" => "SONAR_TOKEN",
      "value_env" => "SONAR_TOKEN_VALUE",
      "version" => version,
      "visibility" => "public",
      "targets" => { "github" => %w[actions dependabot] }
    }
    secret["version_at"] = version_at if version_at
    secret.merge!(secret_options)
    sources = {
      "github-main" => {
        "type" => "github",
        "owner" => "example",
        "repositories" => { "visibility" => "public" }
      }
    }.merge(extra_sources)
    File.write(path, YAML.dump(
                       "version" => 1,
                       "state_file" => File.join(dir, "inventory.json"),
                       "sources" => sources,
                       "secrets" => [secret]
                     ))
    if rules
      rules_path = CredAlignFlow::Rules.default_path_for(path)
      CredAlignFlow::Rules.new(rules_path, data: { "version" => 1, "rules" => rules }).save!
    end
    CredAlignFlow::Config.new(path)
  end
end
