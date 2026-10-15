# frozen_string_literal: true

require_relative "test_helper"

# Drift guards between the schema constants and the surfaces that must
# cover them: the hand-edited documentation, the generated scaffold
# template, the config UI, and the CLI help. When a key, context, or
# enum value is added to the code, these tests fail until the user-facing
# surfaces catch up.
class ConsistencyTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  CONFIG_KEY_LISTS = {
    "top-level" => CredAlignFlow::Config::TOP_LEVEL_KEYS,
    "source" => CredAlignFlow::Config::SOURCE_KEYS,
    "source repositories" => CredAlignFlow::Config::REPOSITORY_KEYS,
    "secret" => CredAlignFlow::Config::SECRET_KEYS
  }.freeze
  DOCUMENTED_KEY_FILES = %w[config.example.yml README.config.md].freeze
  # Every scope field a user can set — the rules-file editable set plus
  # the YAML-only fields the scaffold exposes as optional comments.
  SCAFFOLD_SCOPE_FIELDS = (
    CredAlignFlow::Rules::TOKEN_DEFAULT_KEYS + %w[exclude_sources repository_rules]
  ).freeze

  def test_every_config_key_is_documented
    CONFIG_KEY_LISTS.each do |scope, keys|
      keys.each do |key|
        DOCUMENTED_KEY_FILES.each do |doc|
          assert_match(/\b#{Regexp.escape(key)}\b/, doc_text(doc),
                       "#{scope} key #{key.inspect} is not mentioned in #{doc}")
        end
      end
    end
  end

  def test_scaffold_template_covers_every_adapter_option
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, <<~YAML)
        version: 1
        sources:
          gh-src:
            type: github
            owner: example
            auth_env: TOKEN_A
          fj-src:
            type: forgejo
            owner: example
            owner_type: user
            url: https://forgejo.example
            auth_env: TOKEN_B
        secrets:
          - name: EXISTING_TOKEN
            value_env: EXISTING_TOKEN
      YAML
      config = CredAlignFlow::Config.new(path)
      env = { "TOKEN_A" => "x", "TOKEN_B" => "x", "NEW_TOKEN" => "v" }

      CredAlignFlow::Scaffolder.new(path).apply!(["NEW_TOKEN"], config, env, mode: :import)
      block = File.read(path).split("scaffold-draft: NEW_TOKEN", 2).last

      CredAlignFlow::Providers.supported_types.each do |type|
        adapter = CredAlignFlow::Providers.adapter_for(type)

        adapter::CONTEXTS.each do |context|
          assert_match(/- "#{context}"/, block,
                       "scaffold does not list #{type} context #{context.inspect}")
        end
        adapter.owner_scoped_contexts.each do |context|
          line = block.lines.find { |l| l.include?(%(- "#{context}")) }

          assert_includes line, "user_secrets",
                          "owner context #{context.inspect} lacks its opt-in note"
        end
      end

      SCAFFOLD_SCOPE_FIELDS.each do |field|
        assert_includes block, field,
                        "scaffold draft does not offer scope field #{field.inspect}"
      end
    end
  end

  def test_targeted_scaffold_keeps_full_field_set
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, <<~YAML)
        version: 1
        sources:
          gh-src:
            type: github
            owner: example
            auth_env: TOKEN_A
        secrets: []
      YAML
      config = CredAlignFlow::Config.new(path)
      env = { "TOKEN_A" => "x", "NEW_TOKEN" => "v" }

      CredAlignFlow::Scaffolder.new(path).apply!(
        ["NEW_TOKEN"], config, env, targets: [["gh-src", "actions", "example/repo"]]
      )
      block = File.read(path).split("scaffold: NEW_TOKEN", 2).last

      SCAFFOLD_SCOPE_FIELDS.each do |field|
        assert_includes block, field,
                        "targeted scaffold does not offer scope field #{field.inspect}"
      end
      CredAlignFlow::Providers::GitHub::CONTEXTS.each do |context|
        assert_match(/- "#{context}"/, block,
                     "targeted scaffold does not list context #{context.inspect}")
      end
    end
  end

  def test_ui_exposes_every_scope_field_and_rule_action
    js = File.read(File.join(ROOT, "lib/cred_align_flow/config_ui.js"))

    CredAlignFlow::Rules::TOKEN_DEFAULT_KEYS.each do |field|
      assert_includes(js, %[setField("#{field}",],
                      "config_ui.js has no editor for scope field #{field.inspect}")
    end
    CredAlignFlow::Rules::ACTIONS.each do |action|
      assert_match(/["']#{action}["']/, js,
                   "config_ui.js has no rule option for #{action.inspect}")
    end
  end

  def test_view_payload_lists_every_adapter_context
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, <<~YAML)
        version: 1
        sources:
          gh-src:
            type: github
            owner: example
            auth_env: TOKEN_A
          fj-src:
            type: forgejo
            owner: example
            owner_type: user
            url: https://forgejo.example
            auth_env: TOKEN_B
        secrets: []
      YAML
      state = CredAlignFlow::State.new(File.join(dir, "state.json"))
      presets = {
        "tokens" => CredAlignFlow::PresetLibrary.new(File.join(dir, "tokens.json"), type: :tokens),
        "repos" => CredAlignFlow::PresetLibrary.new(File.join(dir, "repos.json"), type: :repos)
      }
      view = CredAlignFlow::ConfigView.new(
        config: CredAlignFlow::Config.new(path), state: state,
        env_values: {}, revision: "test", presets: presets
      ).to_h

      CredAlignFlow::Providers.supported_types.each do |type|
        contexts = view.fetch("provider_contexts").fetch(type)

        assert_equal CredAlignFlow::Providers.adapter_for(type)::CONTEXTS.sort, contexts.sort,
                     "view payload is missing #{type} contexts"
      end
    end
  end

  def test_ui_help_mentions_every_editable_field_and_provider_type
    help = CredAlignFlow::UiMetadata.to_h.to_s

    CredAlignFlow::Rules::TOKEN_DEFAULT_KEYS.each do |field|
      assert_includes help, field, "ui help does not mention #{field.inspect}"
    end
    CredAlignFlow::Providers.supported_types.each do |type|
      assert_includes help, type, "ui help does not mention provider #{type.inspect}"
    end
  end

  def test_scaffold_modes_and_flags_are_documented
    usage = doc_text("README.usage.md")
    cli_help = File.read(File.join(ROOT, "lib/cred_align_flow/cli.rb"))

    CredAlignFlow::Config::SCAFFOLD_ACTIONS.each do |action|
      %w[README.usage.md README.config.md].each do |doc|
        assert_match(/\b#{action}\b/, doc_text(doc),
                     "scaffold_action #{action.inspect} is not documented in #{doc}")
      end
      assert_match(/["']#{action}["']/, cli_help,
                   "CLI help does not mention scaffold_action #{action.inspect}")
    end
    %w[--only --target --ignore --digests-only].each do |flag|
      assert_includes usage, flag, "README.usage.md does not document #{flag}"
    end
    CredAlignFlow::Rules::ACTIONS.each do |action|
      assert_match(/\b#{action}\b/, doc_text("README.presets.md"),
                   "README.presets.md does not mention rule #{action.inspect}")
    end
  end

  private

  def doc_text(name)
    File.read(File.join(ROOT, name))
  end
end
