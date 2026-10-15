# frozen_string_literal: true

require_relative "test_helper"

class PresetLibraryTest < Minitest::Test
  StubConfig = Struct.new(:secrets, :source_ids)

  def test_missing_file_is_empty_and_save_round_trips
    Dir.mktmpdir do |dir|
      path = File.join(dir, "nested", "presets-tokens.json")
      library = CredAlignFlow::PresetLibrary.new(path, type: :tokens)

      assert_equal({}, library.presets)
      assert_predicate library, :skippable_save?

      library = CredAlignFlow::PresetLibrary.new(
        path,
        type: :tokens,
        data: {
          "version" => 1,
          "presets" => { "github-ci" => { "visibility" => "all", "targets" => { "github" => %w[actions dependabot] } } }
        }
      )

      refute_predicate library, :skippable_save?
      library.save!

      assert_equal 0o600, File.stat(path).mode & 0o777
      loaded = CredAlignFlow::PresetLibrary.new(path, type: :tokens)

      assert_equal({ "github" => %w[actions dependabot] }, loaded.presets.fetch("github-ci").fetch("targets"))
    end
  end

  def test_existing_file_with_no_presets_is_not_skippable
    Dir.mktmpdir do |dir|
      path = File.join(dir, "presets-repos.json")
      File.write(path, JSON.generate("version" => 1, "presets" => {}))
      library = CredAlignFlow::PresetLibrary.new(path, type: :repos)

      refute_predicate library, :skippable_save?
    end
  end

  def test_path_derives_from_the_rules_file_name
    assert_equal(
      "/repo/cred-align.presets-tokens.json",
      CredAlignFlow::PresetLibrary.path_for("/repo/cred-align.rules.json", :tokens)
    )
    assert_equal(
      "/repo/cred-align.presets-repos.json",
      CredAlignFlow::PresetLibrary.path_for("/repo/cred-align.rules.json", :repos)
    )
    assert_equal(
      "/repo/config/presets-tokens.json",
      CredAlignFlow::PresetLibrary.path_for("/repo/config/rules.json", :tokens)
    )
    assert_equal(
      "/repo/config/presets-repos.json",
      CredAlignFlow::PresetLibrary.path_for("/repo/config/rules.json", :repos)
    )
  end

  def test_rejects_unknown_type_and_malformed_shapes
    Dir.mktmpdir do |dir|
      path = File.join(dir, "presets-tokens.json")

      assert_raises(CredAlignFlow::ConfigError) { CredAlignFlow::PresetLibrary.new(path, type: :bogus) }

      File.write(path, "[]")
      error = assert_raises(CredAlignFlow::ConfigError) { CredAlignFlow::PresetLibrary.new(path, type: :tokens) }
      assert_includes error.message, "JSON object"

      File.write(path, "{ not json")
      error = assert_raises(CredAlignFlow::ConfigError) { CredAlignFlow::PresetLibrary.new(path, type: :tokens) }
      assert_includes error.message, "Invalid preset file"

      invalid = [
        [{ "version" => 2, "presets" => {} }, "integer 1"],
        [{ "version" => 1, "presets" => {}, "extra" => true }, "unknown keys"],
        [{ "version" => 1, "presets" => [] }, "presets must be a mapping"],
        [{ "version" => 1, "presets" => { "  " => {} } }, "preset names"],
        [{ "version" => 1, "presets" => { "p" => [] } }, "must be a mapping"],
        [{ "version" => 1, "presets" => { "p" => { "value_env" => "X" } } }, "unknown keys"],
        [{ "version" => 1, "presets" => { "p" => { "visibility" => "bogus" } } }, "public, private, or all"],
        [{ "version" => 1, "presets" => { "p" => { "targets" => { "github" => %w[actions] } } }, "extra" => 1 }, "unknown keys"]
      ]

      invalid.each do |data, fragment|
        error = assert_raises(CredAlignFlow::ConfigError) do
          CredAlignFlow::PresetLibrary.new(path, type: :tokens, data: data)
        end

        assert_includes error.message, fragment
      end
    end
  end

  def test_repo_presets_validate_token_keys_and_actions
    Dir.mktmpdir do |dir|
      path = File.join(dir, "presets-repos.json")
      library = CredAlignFlow::PresetLibrary.new(
        path,
        type: :repos,
        data: {
          "version" => 1,
          "presets" => { "ci-full" => { "SONAR_TOKEN" => "include", "*" => "default" } }
        }
      )

      assert_equal "include", library.presets.fetch("ci-full").fetch("SONAR_TOKEN")

      [
        [{ "bad token!" => "include" }, "secret names"],
        [{ "SONAR_TOKEN" => "sometimes" }, "default, include, exclude, or delete"],
        ["not-a-map", "must be a mapping"]
      ].each do |fields, fragment|
        error = assert_raises(CredAlignFlow::ConfigError) do
          CredAlignFlow::PresetLibrary.new(path, type: :repos, data: { "version" => 1, "presets" => { "p" => fields } })
        end

        assert_includes error.message, fragment
      end
    end
  end

  def test_validate_references_flags_unknown_tokens_in_repo_presets
    Dir.mktmpdir do |dir|
      path = File.join(dir, "presets-repos.json")
      config = StubConfig.new([{ "name" => "SONAR_TOKEN" }], ["github-main"])
      good = CredAlignFlow::PresetLibrary.new(
        path,
        type: :repos,
        data: { "version" => 1, "presets" => { "p" => { "SONAR_TOKEN" => "include", "*" => "exclude" } } }
      )
      good.validate_references!(config)

      bad = CredAlignFlow::PresetLibrary.new(
        path,
        type: :repos,
        data: { "version" => 1, "presets" => { "p" => { "GHOST_TOKEN" => "include" } } }
      )
      error = assert_raises(CredAlignFlow::ConfigError) { bad.validate_references!(config) }

      assert_includes error.message, "unknown tokens: GHOST_TOKEN"
    end
  end

  def test_validate_references_flags_unknown_sources_and_contexts_in_token_presets
    Dir.mktmpdir do |dir|
      path = File.join(dir, "presets-tokens.json")
      config = StubConfig.new([{ "name" => "SONAR_TOKEN" }], ["github-main"])
      good = CredAlignFlow::PresetLibrary.new(
        path,
        type: :tokens,
        data: {
          "version" => 1,
          "presets" => {
            "p" => {
              "sources" => ["github-main"],
              "targets" => { "github" => %w[actions dependabot] },
              "exclude_repositories" => { "github-main" => ["example/*"], "all" => ["tmp/*"] }
            },
            "map-form" => { "targets" => { "github" => { "actions" => true, "dependabot" => false } } }
          }
        }
      )
      good.validate_references!(config)

      bad = [
        [{ "sources" => ["ghost"] }, "unknown sources"],
        [{ "targets" => { "github" => %w[nonexistent] } }, "unsupported github contexts"],
        [{ "targets" => { "ghost-provider" => %w[actions] } }, "unsupported provider"],
        [{ "exclude_repositories" => { "ghost" => ["x/*"] } }, "unknown sources"],
        [{ "visibility" => "all" }, nil]
      ]

      bad.each do |fields, fragment|
        library = CredAlignFlow::PresetLibrary.new(
          path,
          type: :tokens,
          data: { "version" => 1, "presets" => { "p" => fields } }
        )
        next library.validate_references!(config) if fragment.nil?

        error = assert_raises(CredAlignFlow::ConfigError) { library.validate_references!(config) }
        assert_includes error.message, fragment
      end
    end
  end

  def test_repo_preset_stale_references_and_live_presets
    Dir.mktmpdir do |dir|
      config = StubConfig.new([{ "name" => "SONAR_TOKEN" }], ["github-main"])
      library = CredAlignFlow::PresetLibrary.new(
        File.join(dir, "presets-repos.json"),
        type: :repos,
        data: {
          "version" => 1,
          "presets" => {
            "hosting" => { "SONAR_TOKEN" => "include", "GHOST_TOKEN" => "exclude", "*" => "default" }
          }
        }
      )

      assert_equal(
        [{
          "section" => "preset:repos",
          "preset" => "hosting",
          "secret" => "GHOST_TOKEN",
          "rule" => "exclude",
          "reason" => "token not in config"
        }],
        library.stale_references(config)
      )
      assert_equal(
        { "hosting" => { "SONAR_TOKEN" => "include", "*" => "default" } },
        library.live_presets(config)
      )
      # Strict validation still guards what a save submits.
      assert_raises(CredAlignFlow::ConfigError) { library.validate_references!(config) }
    end
  end

  def test_token_preset_stale_references_and_live_presets
    Dir.mktmpdir do |dir|
      config = StubConfig.new([{ "name" => "SONAR_TOKEN" }], ["github-main"])
      library = CredAlignFlow::PresetLibrary.new(
        File.join(dir, "presets-tokens.json"),
        type: :tokens,
        data: {
          "version" => 1,
          "presets" => {
            "hosting" => {
              "visibility" => "public",
              "sources" => %w[github-main gone-source],
              "exclude_repositories" => { "github-main" => ["x/*"], "gone-source" => ["y/*"] }
            }
          }
        }
      )

      assert_equal(
        [
          {
            "section" => "preset:tokens", "preset" => "hosting",
            "field" => "sources", "value" => "gone-source", "reason" => "source not in config"
          },
          {
            "section" => "preset:tokens", "preset" => "hosting",
            "field" => "exclude_repositories", "value" => "gone-source", "reason" => "source not in config"
          }
        ],
        library.stale_references(config)
      )
      assert_equal(
        {
          "hosting" => {
            "visibility" => "public",
            "sources" => ["github-main"],
            "exclude_repositories" => { "github-main" => ["x/*"] }
          }
        },
        library.live_presets(config)
      )
      assert_raises(CredAlignFlow::ConfigError) { library.validate_references!(config) }
    end
  end

  def test_token_preset_drops_scope_fields_left_empty_by_stale_sources
    Dir.mktmpdir do |dir|
      config = StubConfig.new([{ "name" => "SONAR_TOKEN" }], ["github-main"])
      library = CredAlignFlow::PresetLibrary.new(
        File.join(dir, "presets-tokens.json"),
        type: :tokens,
        data: {
          "version" => 1,
          "presets" => { "gone" => { "sources" => ["ghost"], "exclude_repositories" => { "ghost" => ["x"] } } }
        }
      )

      assert_equal({ "gone" => {} }, library.live_presets(config))
    end
  end
end
