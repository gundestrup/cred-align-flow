# frozen_string_literal: true

require_relative "test_helper"

class ConfigTest < Minitest::Test
  def test_loads_sources_secrets_and_targets
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, <<~YAML)
        version: 1
        state_file: #{File.join(dir, 'inventory.json')}
        sources:
          github-main:
            type: github
            owner: example
            repositories:
              visibility: public
              exclude:
                - excluded-repo
        secrets:
          - name: SONAR_TOKEN
            value_env: SONAR_TOKEN_VALUE
            version: "2026-10-07"
            version_at: "2026-10-07T12:30:00+02:00"
            visibility: public
            sources: [github-main]
            targets:
              github: [actions, dependabot]
      YAML

      config = CredAlignFlow::Config.new(path)

      assert_equal ["github-main"], config.source_ids
      assert_equal %w[actions dependabot], config.contexts_for(config.secrets.first, "github-main")
      assert_equal "public", config.secret_visibility(config.secrets.first)
      assert_equal "SONAR_TOKEN_VALUE", config.value_ref(config.secrets.first)
      assert_equal "2026-10-07", config.secret_version(config.secrets.first)
      assert_equal Time.utc(2026, 10, 7, 10, 30), config.secret_version_time(config.secrets.first)
    end
  end

  def test_scaffold_action_accepts_known_modes_and_defaults_to_default
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      base = {
        "version" => 1,
        "sources" => { "github-main" => { "type" => "github", "owner" => "example" } },
        "secrets" => []
      }
      File.write(path, YAML.dump(base))

      assert_equal "default", CredAlignFlow::Config.new(path).scaffold_action

      %w[import auto default].each do |action|
        File.write(path, YAML.dump(base.merge("scaffold_action" => action)))

        assert_equal action, CredAlignFlow::Config.new(path).scaffold_action
      end

      File.write(path, YAML.dump(base.merge("scaffold_action" => "everything")))
      error = assert_raises(CredAlignFlow::ConfigError) { CredAlignFlow::Config.new(path) }

      assert_includes error.message, "scaffold_action"

      File.write(path, YAML.dump(base.merge("scaffold_action" => true)))

      assert_raises(CredAlignFlow::ConfigError) { CredAlignFlow::Config.new(path) }
    end
  end

  def test_forgejo_user_target_requires_the_source_opt_in
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      data = {
        "version" => 1,
        "sources" => {
          "forgejo-main" => {
            "type" => "forgejo", "owner" => "example", "url" => "https://forgejo.example"
          },
          "forgejo-alt" => {
            "type" => "forgejo", "owner" => "other", "url" => "https://forgejo2.example"
          }
        },
        "secrets" => [{
          "name" => "SONAR_TOKEN",
          "sources" => ["forgejo-main"],
          "targets" => { "forgejo" => %w[actions user] }
        }]
      }

      File.write(path, YAML.dump(data))
      error = assert_raises(CredAlignFlow::ConfigError) { CredAlignFlow::Config.new(path) }
      assert_includes error.message, "user_secrets"

      # The opt-in is per source: another Forgejo source without it is
      # unaffected because the secret does not apply to it.
      data["sources"]["forgejo-main"]["user_secrets"] = true
      File.write(path, YAML.dump(data))
      config = CredAlignFlow::Config.new(path)

      assert_equal %w[actions user], config.contexts_for(config.secrets.first, "forgejo-main")
    end
  end

  def test_user_secrets_flag_is_forgejo_only
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, YAML.dump(
                         "version" => 1,
                         "sources" => {
                           "github-main" => {
                             "type" => "github", "owner" => "example", "user_secrets" => true
                           }
                         },
                         "secrets" => []
                       ))

      error = assert_raises(CredAlignFlow::ConfigError) { CredAlignFlow::Config.new(path) }
      assert_includes error.message, "user_secrets is only valid for Forgejo"
    end
  end

  def test_update_notice_settings_default_and_validate
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      source = {
        "version" => 1,
        "sources" => { "github-main" => { "type" => "github", "owner" => "example" } },
        "secrets" => []
      }
      File.write(path, YAML.dump(source))
      config = CredAlignFlow::Config.new(path)

      refute_predicate config, :check_for_updates?
      assert_equal 7, config.update_notice_min_age_days

      source["check_for_updates"] = true
      source["update_notice_min_age_days"] = 0
      File.write(path, YAML.dump(source))
      config = CredAlignFlow::Config.new(path)

      assert_equal true, config.check_for_updates?
      assert_equal 0, config.update_notice_min_age_days

      source["update_notice_min_age_days"] = -1
      File.write(path, YAML.dump(source))
      assert_raises(CredAlignFlow::ConfigError) { CredAlignFlow::Config.new(path) }

      source["update_notice_min_age_days"] = "7"
      File.write(path, YAML.dump(source))
      assert_raises(CredAlignFlow::ConfigError) { CredAlignFlow::Config.new(path) }

      source["update_notice_min_age_days"] = 7
      source["check_for_updates"] = "true"
      File.write(path, YAML.dump(source))
      assert_raises(CredAlignFlow::ConfigError) { CredAlignFlow::Config.new(path) }
    end
  end

  def test_secret_visibility_defaults_to_public
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, YAML.dump(
                         "version" => 1,
                         "sources" => { "github-main" => { "type" => "github", "owner" => "example" } },
                         "secrets" => [{ "name" => "SONAR_TOKEN" }]
                       ))

      config = CredAlignFlow::Config.new(path)

      assert_equal "public", config.secret_visibility(config.secrets.first)
    end
  end

  def test_version_timestamp_requires_an_explicit_timezone
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, <<~YAML)
        version: 1
        sources:
          github-main:
            type: github
            owner: example
        secrets:
          - name: SONAR_TOKEN
            version_at: "2026-10-07T12:30:00"
      YAML

      error = assert_raises(CredAlignFlow::ConfigError) do
        CredAlignFlow::Config.new(path)
      end

      assert_includes error.message, "timezone offset"
    end
  end

  def test_rejects_malformed_config_version
    assert_invalid_config(version: "1invalid")
  end

  def test_rejects_string_repository_booleans
    assert_invalid_config(source_options: { "repositories" => { "include_archived" => "false" } })
  end

  def test_requires_auth_env_for_multiple_github_sources_on_the_same_host
    assert_invalid_config(
      additional_sources: {
        "github-alt" => {
          "type" => "github",
          "owner" => "other",
          "api_url" => "https://api.github.com"
        }
      }
    )
  end

  def test_rejects_secret_names_over_the_provider_limit
    assert_invalid_config(secrets: [{ "name" => "A" * 101 }])
  end

  def test_unimportable_secret_name_reason_flags_names_that_can_never_validate
    assert_nil CredAlignFlow::Config.unimportable_secret_name_reason("PLAIN_TOKEN")
    assert_equal "uses the reserved GITHUB_ prefix",
                 CredAlignFlow::Config.unimportable_secret_name_reason("GITHUB_TOKEN")
    assert_includes CredAlignFlow::Config.unimportable_secret_name_reason("lowercase"),
                    "uppercase letters, digits, and underscores"
    assert_includes CredAlignFlow::Config.unimportable_secret_name_reason("9LEADING"),
                    "uppercase letters, digits, and underscores"
    assert_includes CredAlignFlow::Config.unimportable_secret_name_reason("A" * 101),
                    "100-character GitHub limit"
  end

  def test_rejects_misspelled_secret_source_key
    assert_invalid_config(secrets: [{ "name" => "SONAR_TOKEN", "source" => ["github-main"] }])
  end

  def test_rejects_unknown_secret_source_ids
    assert_invalid_config(
      source_options: { "auth_env" => "GITHUB_MAIN_TOKEN" },
      secrets: [{ "name" => "SONAR_TOKEN", "sources" => ["github-mian"] }],
      additional_sources: {
        "github-alt" => { "type" => "github", "owner" => "other", "auth_env" => "GITHUB_ALT_TOKEN" }
      }
    )
  end

  def test_rejects_invalid_secret_visibility_when_loading_config
    assert_invalid_config(secrets: [{ "name" => "SONAR_TOKEN", "visibility" => "pubic" }])
  end

  def test_rejects_invalid_rules_file_setting
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, YAML.dump(
                         "version" => 1,
                         "rules_file" => 42,
                         "sources" => { "github-main" => { "type" => "github", "owner" => "example" } },
                         "secrets" => []
                       ))

      assert_raises(CredAlignFlow::ConfigError) { CredAlignFlow::Config.new(path) }
    end
  end

  def test_rejects_invalid_env_file_setting
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, YAML.dump(
                         "version" => 1,
                         "env_file" => 42,
                         "sources" => { "github-main" => { "type" => "github", "owner" => "example" } },
                         "secrets" => []
                       ))

      assert_raises(CredAlignFlow::ConfigError) { CredAlignFlow::Config.new(path) }
    end
  end

  def test_relative_file_paths_resolve_against_the_config_directory
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, YAML.dump(
                         "version" => 1,
                         "state_file" => "inventory.json",
                         "rules_file" => "rules.json",
                         "env_file" => "secrets.env",
                         "sources" => { "github-main" => { "type" => "github", "owner" => "example" } },
                         "secrets" => []
                       ))

      config = CredAlignFlow::Config.new(path)

      assert_equal File.join(dir, "inventory.json"), config.state_file
      assert_equal File.join(dir, "rules.json"), config.rules_file
      assert_equal File.join(dir, "secrets.env"), config.env_path
    end
  end

  def test_fingerprint_hmac_matches_an_independent_expected_vector
    previous_env_key = ENV.delete(CredAlignFlow::Fingerprint::ENV_KEY)
    previous_key = CredAlignFlow::Fingerprint.key
    CredAlignFlow::Fingerprint.key = "test-key"

    assert_equal "hmac-sha256:aea6329927260cef2c600c2fd2b946cc287b59d8c41b59ff44e7be38200246cf",
                 CredAlignFlow::Fingerprint.digest("TOKEN", "value")
  ensure
    CredAlignFlow::Fingerprint.key = previous_key
    ENV[CredAlignFlow::Fingerprint::ENV_KEY] = previous_env_key if previous_env_key
  end

  def test_fingerprint_key_is_private_and_ignored
    previous_key = CredAlignFlow::Fingerprint.key
    previous_env_key = ENV.delete(CredAlignFlow::Fingerprint::ENV_KEY)
    Dir.mktmpdir do |dir|
      key_path = File.join(dir, ".digest-key")
      key = CredAlignFlow::Fingerprint.configure!(key_path)

      assert_match(/\A[0-9a-f]{64}\z/, key)
      assert_equal 0o600, File.stat(key_path).mode & 0o777
      assert_includes File.read(File.expand_path("../.gitignore", __dir__)), ".digest-key"
    end
  ensure
    CredAlignFlow::Fingerprint.key = previous_key
    ENV[CredAlignFlow::Fingerprint::ENV_KEY] = previous_env_key if previous_env_key
  end

  def test_missing_fingerprint_key_is_not_regenerated_when_hmac_records_exist
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      state_path = File.join(dir, "state.json")
      File.write(path, YAML.dump(
                         "version" => 1,
                         "state_file" => state_path,
                         "env_file" => File.join(dir, "values.env"),
                         "rules_file" => File.join(dir, "rules.json"),
                         "sources" => { "github-main" => { "type" => "github", "owner" => "example" } },
                         "secrets" => [{ "name" => "SONAR_TOKEN", "value_digest" => "hmac-sha256:#{'a' * 64}" }]
                       ))
      config = CredAlignFlow::Config.new(path)
      state = CredAlignFlow::State.new(state_path)
      key_path = File.join(dir, ".digest-key")

      assert_raises(CredAlignFlow::ConfigError) do
        CredAlignFlow::Fingerprint.configure!(
          key_path, require_existing: CredAlignFlow::Fingerprint.protected_records_present?(config, state)
        )
      end
      refute_path_exists key_path
    end
  end

  def test_value_resolution_uses_the_injected_process_environment
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, YAML.dump(
                         "version" => 1,
                         "state_file" => File.join(dir, "state.json"),
                         "sources" => { "github-main" => { "type" => "github", "owner" => "example" } },
                         "secrets" => [{ "name" => "SONAR_TOKEN" }]
                       ))
      config = CredAlignFlow::Config.new(path)
      secret = config.secrets.first
      previous = CredAlignFlow.environment

      # The env-file map wins; the injected process environment is the
      # fallback — and ambient variables outside it never resolve.
      CredAlignFlow.environment = { "SONAR_TOKEN" => "from-process-env" }

      assert_equal "from-env-file", config.value_for(secret, { "SONAR_TOKEN" => "from-env-file" })
      assert_equal "from-process-env", config.value_for(secret, {})

      CredAlignFlow.environment = {}

      assert_nil config.value_for(secret, {})
    ensure
      CredAlignFlow.environment = previous
    end
  end

  def test_fingerprint_key_file_rejects_broad_permissions
    Dir.mktmpdir do |dir|
      key_path = File.join(dir, ".digest-key")
      File.write(key_path, "a" * 64)
      File.chmod(0o644, key_path)

      assert_raises(CredAlignFlow::ConfigError) { CredAlignFlow::Fingerprint.configure!(key_path) }
    end
  end

  def test_runtime_path_validation_rejects_override_collisions
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      data = {
        "version" => 1,
        "env_file" => File.join(dir, "values.env"),
        "state_file" => File.join(dir, "state.json"),
        "rules_file" => File.join(dir, "rules.json"),
        "sources" => { "github-main" => { "type" => "github", "owner" => "example" } },
        "secrets" => []
      }
      File.write(path, YAML.dump(data))
      config = CredAlignFlow::Config.new(path)

      assert_raises(CredAlignFlow::ConfigError) do
        config.validate_runtime_paths!(env_path: config.env_path, state_path: path)
      end
    end
  end

  def test_config_rejects_state_path_that_collides_with_fingerprint_key
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      env_path = File.join(dir, "values.env")
      File.write(path, YAML.dump(
                         "version" => 1,
                         "env_file" => env_path,
                         "state_file" => File.join(dir, ".digest-key"),
                         "rules_file" => File.join(dir, "rules.json"),
                         "sources" => { "github-main" => { "type" => "github", "owner" => "example" } },
                         "secrets" => []
                       ))

      assert_raises(CredAlignFlow::ConfigError) { CredAlignFlow::Config.new(path) }
    end
  end

  def test_runtime_path_validation_resolves_aliases_with_missing_files
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      real_directory = File.join(dir, "real")
      alias_directory = File.join(dir, "alias")
      FileUtils.mkdir_p(real_directory)
      File.symlink(real_directory, alias_directory)
      data = {
        "version" => 1,
        "env_file" => File.join(real_directory, "values.env"),
        "state_file" => File.join(dir, "state.json"),
        "rules_file" => File.join(dir, "rules.json"),
        "sources" => { "github-main" => { "type" => "github", "owner" => "example" } },
        "secrets" => []
      }
      File.write(path, YAML.dump(data))
      config = CredAlignFlow::Config.new(path)

      assert_raises(CredAlignFlow::ConfigError) do
        config.validate_runtime_paths!(
          env_path: File.join(real_directory, "values.env"),
          state_path: File.join(alias_directory, "values.env")
        )
      end
    end
  end

  def test_token_defaults_overlay_replaces_yaml_scope_fields
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      rules_path = CredAlignFlow::Rules.default_path_for(path)
      File.write(path, YAML.dump(
                         "version" => 1,
                         "sources" => { "github-main" => { "type" => "github", "owner" => "example" } },
                         "secrets" => [{
                           "name" => "SONAR_TOKEN",
                           "visibility" => "public",
                           "sources" => ["github-main"],
                           "targets" => { "github" => ["actions"] },
                           "exclude_repos" => ["legacy/repo"]
                         }]
                       ))
      File.write(rules_path, JSON.generate(
                               "version" => 2,
                               "rules" => {},
                               "token_defaults" => {
                                 "SONAR_TOKEN" => {
                                   "visibility" => "all",
                                   "targets" => { "github" => %w[actions dependabot] },
                                   "exclude_repositories" => ["example/repo"]
                                 }
                               }
                             ))

      config = CredAlignFlow::Config.new(path)
      secret = config.secrets.first

      assert_equal "all", config.secret_visibility(secret)
      assert_equal %w[actions dependabot], config.contexts_for(secret, "github-main")
      assert_equal ["example/repo"], config.secret_exclusions(secret, "github-main")
      assert_equal ["legacy/repo"], config.raw_secrets.first.fetch("exclude_repos")
      refute config.secrets.first.key?("exclude_repos")
      assert_equal "all", config.token_default_overlay(secret).fetch("visibility")
    end
  end

  def test_token_defaults_keep_unset_yaml_fields_and_hard_locks
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      rules_path = CredAlignFlow::Rules.default_path_for(path)
      File.write(path, YAML.dump(
                         "version" => 1,
                         "sources" => {
                           "github-main" => {
                             "type" => "github", "owner" => "example", "auth_env" => "GITHUB_MAIN_TOKEN"
                           },
                           "github-alt" => {
                             "type" => "github", "owner" => "other", "auth_env" => "GITHUB_ALT_TOKEN"
                           }
                         },
                         "secrets" => [{
                           "name" => "SONAR_TOKEN",
                           "sources" => ["github-main"],
                           "exclude_sources" => ["github-alt"]
                         }]
                       ))
      File.write(rules_path, JSON.generate(
                               "version" => 2,
                               "rules" => {},
                               "token_defaults" => { "SONAR_TOKEN" => { "sources" => %w[github-main github-alt] } }
                             ))

      config = CredAlignFlow::Config.new(path)
      secret = config.secrets.first

      assert config.secret_source_selected_by_default?(secret, "github-alt")
      refute config.secret_applies_to_source?(secret, "github-alt")
      assignment, = config.secret_assignment(secret, "github-alt", { "nameWithOwner" => "other/repo" })

      assert_equal "excluded_manual", assignment
    end
  end

  def test_tolerates_token_defaults_for_unknown_tokens
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      rules_path = CredAlignFlow::Rules.default_path_for(path)
      File.write(path, YAML.dump(
                         "version" => 1,
                         "sources" => { "github-main" => { "type" => "github", "owner" => "example" } },
                         "secrets" => [{ "name" => "SONAR_TOKEN" }]
                       ))
      File.write(rules_path, JSON.generate(
                               "version" => 2,
                               "rules" => {},
                               "token_defaults" => { "GONE_TOKEN" => { "visibility" => "all" } }
                             ))

      config = CredAlignFlow::Config.new(path)
      stale = config.stale_rules

      assert_equal "SONAR_TOKEN", config.secrets.first.fetch("name")
      assert_equal 1, stale.length
      assert_equal "token_defaults", stale.first.fetch("section")
      assert_equal "GONE_TOKEN", stale.first.fetch("secret")
      assert_equal "token not in config", stale.first.fetch("reason")
    end
  end

  def test_rejects_invalid_token_default_values_with_overlay_context
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      rules_path = CredAlignFlow::Rules.default_path_for(path)
      File.write(path, YAML.dump(
                         "version" => 1,
                         "sources" => { "github-main" => { "type" => "github", "owner" => "example" } },
                         "secrets" => [{ "name" => "SONAR_TOKEN" }]
                       ))
      File.write(rules_path, JSON.generate(
                               "version" => 2,
                               "rules" => {},
                               "token_defaults" => { "SONAR_TOKEN" => { "visibility" => "bogus" } }
                             ))

      error = assert_raises(CredAlignFlow::ConfigError) { CredAlignFlow::Config.new(path) }

      assert_includes error.message, "token_defaults"
    end
  end

  def test_tolerates_rules_file_references_to_unknown_tokens_and_sources
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      rules_path = CredAlignFlow::Rules.default_path_for(path)
      File.write(path, YAML.dump(
                         "version" => 1,
                         "sources" => { "github-main" => { "type" => "github", "owner" => "example" } },
                         "secrets" => [{ "name" => "SONAR_TOKEN" }]
                       ))
      File.write(rules_path, JSON.generate(
                               "version" => 1,
                               "rules" => {
                                 "github-main" => { "example/repo" => { "GONE_TOKEN" => "include" } },
                                 "gone-source" => { "example/repo" => { "SONAR_TOKEN" => "exclude" } }
                               }
                             ))

      config = CredAlignFlow::Config.new(path)
      stale = config.stale_rules

      assert_equal 2, stale.length
      assert_equal "GONE_TOKEN", stale.first.fetch("secret")
      assert_equal "token not in config", stale.first.fetch("reason")
      assert_equal "gone-source", stale.last.fetch("source")
      assert_equal "source not in config", stale.last.fetch("reason")
    end
  end

  def test_rejects_repository_rules_for_unknown_sources
    assert_invalid_config(
      secrets: [{
        "name" => "SONAR_TOKEN",
        "repository_rules" => { "github-mian" => { "example/repo" => "include" } }
      }]
    )
  end

  def test_rejects_invalid_repository_rule_values
    assert_invalid_config(
      secrets: [{
        "name" => "SONAR_TOKEN",
        "repository_rules" => { "github-main" => { "example/repo" => "maybe" } }
      }]
    )
  end

  def test_rejects_repository_rule_patterns
    assert_invalid_config(
      secrets: [{
        "name" => "SONAR_TOKEN",
        "repository_rules" => { "github-main" => { "example/*" => "include" } }
      }]
    )
  end

  private

  def assert_invalid_config(version: 1, source_options: {}, secrets: [], additional_sources: {})
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      source = { "type" => "github", "owner" => "example" }.merge(source_options)
      sources = { "github-main" => source }.merge(additional_sources)
      File.write(path, YAML.dump(
                         "version" => version,
                         "sources" => sources,
                         "secrets" => secrets
                       ))

      assert_raises(CredAlignFlow::ConfigError) { CredAlignFlow::Config.new(path) }
    end
  end
end
