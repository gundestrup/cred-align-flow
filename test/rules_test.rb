# frozen_string_literal: true

require_relative "test_helper"

class RulesTest < Minitest::Test
  def test_missing_file_is_empty_and_save_round_trips
    Dir.mktmpdir do |dir|
      path = File.join(dir, "nested", "config.rules.json")
      rules = CredAlignFlow::Rules.new(path)

      assert_equal({}, rules.entries)
      assert_nil rules.rule("github-main", "example/repo", "SONAR_TOKEN")
      refute rules.any_include?("github-main", "SONAR_TOKEN")

      rules = CredAlignFlow::Rules.new(
        path,
        data: {
          "version" => 1,
          "rules" => { "github-main" => { "example/repo" => { "SONAR_TOKEN" => "include" } } }
        }
      )
      rules.save!

      assert_equal 0o600, File.stat(path).mode & 0o777
      loaded = CredAlignFlow::Rules.new(path)

      assert_equal "include", loaded.rule("github-main", "example/repo", "SONAR_TOKEN")
      assert loaded.any_include?("github-main", "SONAR_TOKEN")
      refute loaded.any_include?("github-main", "OTHER_TOKEN")
    end
  end

  def test_rejects_malformed_shapes
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.rules.json")
      invalid = [
        ["[]", "JSON object"],
        [{ "version" => 1, "rules" => [] }, "mapping"],
        [{ "version" => 1, "rules" => { "github-main" => [] } }, "mapping"],
        [{ "version" => 1, "rules" => { "github-main" => { "repo" => {} } } }, "owner/name"],
        [{ "version" => 1, "rules" => { "github-main" => { "example/repo" => { "T" => "maybe" } } } },
         "default, include, or exclude"]
      ]

      invalid.each do |content, fragment|
        data = content.is_a?(String) ? nil : content
        File.write(path, content.is_a?(String) ? content : "") if content.is_a?(String)

        error = assert_raises(CredAlignFlow::ConfigError) do
          data ? CredAlignFlow::Rules.new(path, data: data) : CredAlignFlow::Rules.new(path)
        end

        assert_includes error.message, fragment
      end
    end
  end

  def test_validate_references_flags_unknown_sources_and_tokens
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.rules.json")
      rules = CredAlignFlow::Rules.new(
        path,
        data: { "version" => 1, "rules" => { "github-main" => { "example/repo" => { "SONAR_TOKEN" => "include" } } } }
      )

      rules.validate_references!(["github-main"], ["SONAR_TOKEN"])

      source_error = assert_raises(CredAlignFlow::ConfigError) do
        rules.validate_references!(["github-alt"], ["SONAR_TOKEN"])
      end
      assert_includes source_error.message, "unknown source"

      token_error = assert_raises(CredAlignFlow::ConfigError) do
        rules.validate_references!(["github-main"], ["OTHER_TOKEN"])
      end
      assert_includes token_error.message, "unknown tokens"
    end
  end

  def test_default_path_derives_from_the_config_file_name
    assert_equal(
      "/repo/cred-align.rules.json",
      CredAlignFlow::Rules.default_path_for("/repo/cred-align.local.yml")
    )
    assert_equal(
      "/home/user/.config/cred-align-flow/rules.json",
      CredAlignFlow::Rules.default_path_for("/home/user/.config/cred-align-flow/config.yml")
    )
    assert_equal(
      "/repo/config/rules.json",
      CredAlignFlow::Rules.default_path_for("/repo/config/config.yml")
    )
    assert_equal(
      "/repo/config/cred-align.rules.json",
      CredAlignFlow::Rules.default_path_for("/repo/config/cred-align.local.yml")
    )
  end
end
