# frozen_string_literal: true

require "digest"
require "openssl"
require "securerandom"
require "yaml"

module CredAlignFlow
  # Backend for the local config UI. It writes the rules file
  # (per-repository token overrides and token default-scope overrides)
  # and the two sibling preset-library files the UI stamps from. The YAML
  # config is read-only here and stays hand-edited. Inventory refresh
  # updates the state file through read-only provider calls.
  #
  # Two revisions are reported: `revision` guards writes to the
  # UI-managed files (the files a save depends on) and `display_revision`
  # additionally covers the env inputs that feed availability/digest
  # status, so the page notices value rotation. The display revision is
  # HMAC'd with a per-process key: an unkeyed digest of secret material
  # would be a guessing oracle.
  class ConfigEditor
    class RevisionConflict < Error; end

    SAVE_KEYS = %w[revision rules token_defaults token_presets repo_presets].freeze

    Inputs = Struct.new(:config_bytes, :rules_bytes, :token_presets_bytes, :repo_presets_bytes,
                        :state_bytes, :env_bytes) do
      def revision
        Digest::SHA256.hexdigest(
          [config_bytes, rules_bytes, token_presets_bytes, repo_presets_bytes, state_bytes].join("\0")
        )
      end
    end

    attr_reader :config_path, :env_path, :state_path, :rules_path, :token_presets_path, :repo_presets_path

    def initialize(config_path:, env_path:, state_path:, providers: {})
      @config_path = File.expand_path(config_path)
      @env_path = File.expand_path(env_path)
      @state_path = File.expand_path(state_path)
      config = Config.new(@config_path)
      @rules_path = config.rules_file
      @token_presets_path = PresetLibrary.path_for(@rules_path, :tokens)
      @repo_presets_path = PresetLibrary.path_for(@rules_path, :repos)
      @providers = providers
      @revision_key = SecureRandom.hex(32)
      validate_path_roles!(config)
      return if Fingerprint.configured?

      state = State.new(@state_path)
      Fingerprint.configure!(
        Fingerprint.default_key_file(@env_path),
        require_existing: Fingerprint.protected_records_present?(config, state)
      )
    end

    def update_notice_min_age_days
      config = Config.new(@config_path)
      config.check_for_updates? ? config.update_notice_min_age_days : nil
    end

    def data
      inputs = read_inputs
      config = build_config(inputs.config_bytes)
      build_view(config, State.new(@state_path), Dotenv.load(@env_path), inputs)
    end

    def preview(payload)
      verify_payload!(payload, SAVE_KEYS)
      inputs = read_inputs
      verify_revision!(payload.fetch("revision"), inputs)
      config, = candidate_config(payload, inputs.config_bytes)
      libraries = candidate_libraries(payload, config)
      build_view(config, State.new(@state_path), Dotenv.load(@env_path), inputs, libraries)
    end

    # Check-and-save runs under the rules lockfile so another writer cannot
    # change the UI-managed files between the revision check and the
    # atomic replaces. Presets land first: an interrupted save can leave
    # an unused library update, never a rules state missing its inputs.
    def save(payload)
      verify_payload!(payload, SAVE_KEYS)
      ensure_writable_targets!
      AtomicFile.with_lock(@rules_path) do
        inputs = read_inputs
        verify_revision!(payload.fetch("revision"), inputs)
        config, rules = candidate_config(payload, inputs.config_bytes)
        libraries = candidate_libraries(payload, config)
        libraries.each_value { |library| library.save! unless library.skippable_save? }
        rules.save!
      end
      data
    end

    def refresh_inventory(payload)
      verify_payload!(payload, %w[revision])
      inputs = read_inputs
      verify_revision!(payload.fetch("revision"), inputs)
      config = build_config(inputs.config_bytes)
      env_values = Dotenv.load(@env_path)
      state = State.new(@state_path)
      Inventory.new(config, state, env_values, providers: @providers).refresh!
      build_view(config, state, env_values, read_inputs)
    end

    private

    def read_inputs
      Inputs.new(
        File.binread(@config_path),
        read_bytes(@rules_path),
        read_bytes(@token_presets_path),
        read_bytes(@repo_presets_path),
        read_bytes(@state_path),
        read_bytes(@env_path)
      )
    end

    def read_bytes(path)
      File.exist?(path) ? File.binread(path) : ""
    end

    def display_revision(inputs)
      OpenSSL::HMAC.hexdigest("SHA256", @revision_key, "#{inputs.revision}\0#{inputs.env_bytes}")
    end

    def verify_payload!(payload, keys)
      return if payload.is_a?(Hash) && payload.keys.sort == keys.sort

      raise ConfigError, "request must contain only #{keys.join(' and ')}"
    end

    def verify_revision!(revision, inputs)
      return if revision.is_a?(String) && revision == inputs.revision

      raise RevisionConflict, "inputs changed since this page was loaded; reload before saving"
    end

    # The candidate document is schema v2; Rules normalizes the stored
    # version back to 1 when no token_defaults are present, so rules-only
    # files stay readable by older builds. Reference validation stays
    # strict here: a submitted draft naming unknown tokens or sources is
    # an error, while entries already on disk that went stale after a
    # hand-edited YAML are dropped from the draft instead of blocking it.
    def candidate_config(payload, config_bytes)
      rules = Rules.new(
        @rules_path,
        data: {
          "version" => 2,
          "rules" => payload.fetch("rules"),
          "token_defaults" => payload.fetch("token_defaults")
        }
      )
      config = Config.new(@config_path, data: parse_config(config_bytes), rules: rules)
      rules.validate_references!(config.source_ids, config.secrets.map { |secret| secret.fetch("name") })
      [config, rules]
    end

    # Candidate preset libraries, reference-checked against the candidate
    # config so a save cannot persist a preset that stamps broken state.
    def candidate_libraries(payload, config)
      libraries = {
        "tokens" => PresetLibrary.new(
          @token_presets_path,
          type: :tokens,
          data: { "version" => PresetLibrary::VERSION, "presets" => payload.fetch("token_presets") }
        ),
        "repos" => PresetLibrary.new(
          @repo_presets_path,
          type: :repos,
          data: { "version" => PresetLibrary::VERSION, "presets" => payload.fetch("repo_presets") }
        )
      }
      libraries.each_value { |library| library.validate_references!(config) }
      libraries
    end

    def preset_libraries
      {
        "tokens" => PresetLibrary.new(@token_presets_path, type: :tokens),
        "repos" => PresetLibrary.new(@repo_presets_path, type: :repos)
      }
    end

    def build_config(config_bytes)
      Config.new(@config_path, data: parse_config(config_bytes), rules: Rules.new(@rules_path))
    end

    def parse_config(bytes)
      parsed = YAML.safe_load(bytes, aliases: false)
      raise ConfigError, "Config file must contain a YAML mapping" unless parsed.is_a?(Hash)

      parsed
    rescue Psych::Exception => e
      raise ConfigError, "Invalid config YAML: #{e.message}"
    end

    def build_view(config, state, env_values, inputs, libraries = preset_libraries)
      scaffolder = begin
        Scaffolder.new(@config_path)
      rescue ConfigError
        nil
      end
      ConfigView.new(
        config: config,
        state: state,
        env_values: env_values,
        revision: inputs.revision,
        display_revision: display_revision(inputs),
        scaffolder: scaffolder,
        presets: libraries
      ).to_h
    end

    # Same-file checks must survive path aliases, not just string equality.
    def validate_path_roles!(config)
      config.validate_runtime_paths!(env_path: @env_path, state_path: @state_path)
    end

    def ensure_writable_targets!
      [@rules_path, @token_presets_path, @repo_presets_path].each do |path|
        next unless File.symlink?(path)

        raise ConfigError, "saving through a symlink is disabled; pass the target file path directly: #{path}"
      end
    end
  end
end
