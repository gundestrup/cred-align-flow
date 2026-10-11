# frozen_string_literal: true

require "digest"
require "openssl"
require "securerandom"
require "yaml"

module CredAlignFlow
  # Backend for the local config UI. The only file it writes is the rules
  # file (per-repository token overrides); the YAML config is read-only here
  # and stays hand-edited. Inventory refresh updates the state file through
  # read-only provider calls.
  #
  # Two revisions are reported: `revision` guards rules-file writes (the
  # files a save depends on) and `display_revision` additionally covers the
  # env inputs that feed availability/digest status, so the page notices
  # value rotation. The display revision is HMAC'd with a per-process key:
  # an unkeyed digest of secret material would be a guessing oracle.
  class ConfigEditor
    class RevisionConflict < Error; end

    Inputs = Struct.new(:config_bytes, :rules_bytes, :state_bytes, :env_bytes) do
      def revision
        Digest::SHA256.hexdigest([config_bytes, rules_bytes, state_bytes].join("\0"))
      end
    end

    attr_reader :config_path, :env_path, :state_path, :rules_path

    def initialize(config_path:, env_path:, state_path:, providers: {})
      @config_path = File.expand_path(config_path)
      @env_path = File.expand_path(env_path)
      @state_path = File.expand_path(state_path)
      config = Config.new(@config_path)
      @rules_path = config.rules_file
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
      verify_payload!(payload, %w[revision rules])
      inputs = read_inputs
      verify_revision!(payload.fetch("revision"), inputs)
      rules = candidate_rules(payload.fetch("rules"), inputs.config_bytes)
      config = Config.new(@config_path, data: parse_config(inputs.config_bytes), rules: rules)
      build_view(config, State.new(@state_path), Dotenv.load(@env_path), inputs)
    end

    # Check-and-save runs under the rules lockfile so another writer cannot
    # change the file between the revision check and the atomic replace.
    def save(payload)
      verify_payload!(payload, %w[revision rules])
      ensure_writable_rules!
      AtomicFile.with_lock(@rules_path) do
        inputs = read_inputs
        verify_revision!(payload.fetch("revision"), inputs)
        rules = candidate_rules(payload.fetch("rules"), inputs.config_bytes)
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
        File.exist?(@rules_path) ? File.binread(@rules_path) : "",
        File.exist?(@state_path) ? File.binread(@state_path) : "",
        File.exist?(@env_path) ? File.binread(@env_path) : ""
      )
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

    def candidate_rules(payload_rules, config_bytes)
      rules = Rules.new(@rules_path, data: { "version" => 1, "rules" => payload_rules })
      Config.new(@config_path, data: parse_config(config_bytes), rules: rules)
      rules
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

    def build_view(config, state, env_values, inputs)
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
        scaffolder: scaffolder
      ).to_h
    end

    # Same-file checks must survive path aliases, not just string equality.
    def validate_path_roles!(config)
      config.validate_runtime_paths!(env_path: @env_path, state_path: @state_path)
    end

    def ensure_writable_rules!
      return unless File.symlink?(@rules_path)

      raise ConfigError, "saving through a rules symlink is disabled; pass the target file path directly"
    end
  end
end
