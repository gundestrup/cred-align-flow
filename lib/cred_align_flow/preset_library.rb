# frozen_string_literal: true

require "json"

module CredAlignFlow
  # UI-managed preset library stored beside the rules file — one file per
  # preset type. Presets are inert templates the UI stamps into the rules
  # file by copy; plan/apply/check never read these files, so they carry
  # no runtime semantics.
  #
  #   {
  #     "version": 1,
  #     "presets": { "<preset name>": { ... } }
  #   }
  #
  # :tokens presets hold default-scope fields (the same set a
  # token_defaults entry may override); applying one stamps those fields
  # into a token's token_defaults entry.
  #
  # :repos presets hold a token => "default|include|exclude" map;
  # applying one stamps those rules onto a chosen repository's per-source
  # rules entry. The "*" key is a catch-all stamped onto every configured
  # token the preset does not name explicitly.
  #
  # File names derive from the rules file: "cred-align.rules.json" pairs
  # with "cred-align.presets-tokens.json"/"cred-align.presets-repos.json",
  # and a plain "rules.json" pairs with "presets-tokens.json" and
  # "presets-repos.json".
  class PresetLibrary
    TYPES = %i[tokens repos].freeze
    VERSION = 1
    NAME_MAX_LENGTH = 80
    ANY_TOKEN = "*"
    TOP_LEVEL_KEYS = %w[version presets].freeze

    attr_reader :path, :type

    def self.path_for(rules_path, type)
      expanded = File.expand_path(rules_path)
      base = File.basename(expanded, ".json")
      stem = base == "rules" ? "" : base.delete_suffix(".rules")
      name = stem.empty? ? "presets-#{type}.json" : "#{stem}.presets-#{type}.json"
      File.join(File.dirname(expanded), name)
    end

    def initialize(path, type:, data: nil)
      @type = type.to_sym
      raise ConfigError, "unknown preset type #{type.inspect}" unless TYPES.include?(@type)

      @path = File.expand_path(path)
      @data = data || read_existing || { "version" => VERSION, "presets" => {} }
      validate!
    end

    def presets
      @data.fetch("presets")
    end

    # An absent file with no presets is worth nothing on disk; the editor
    # skips the write so unused libraries do not clutter the config dir.
    def skippable_save?
      presets.empty? && !File.exist?(@path)
    end

    def save!
      AtomicFile.write(@path, "#{JSON.pretty_generate(@data)}\n", error_class: ConfigError)
    end

    # Reference checks the JSON schema cannot express, run by the editor
    # before a save: repo presets may only name configured tokens (or
    # "*"), token presets may only name configured sources and supported
    # provider contexts.
    def validate_references!(config)
      case @type
      when :repos then validate_token_references!(config)
      when :tokens then validate_scope_references!(config)
      end
    end

    private

    def read_existing
      return nil unless File.exist?(@path)

      parsed = JSON.parse(File.read(@path))
      raise ConfigError, "#{basename} must contain a JSON object" unless parsed.is_a?(Hash)

      parsed
    rescue JSON::ParserError => e
      raise ConfigError, "Invalid preset file #{@path}: #{e.message}"
    end

    def basename
      File.basename(@path)
    end

    def validate!
      unknown = @data.keys - TOP_LEVEL_KEYS
      raise ConfigError, "#{basename} has unknown keys: #{unknown.join(', ')}" unless unknown.empty?

      version = @data.fetch("version", VERSION)
      raise ConfigError, "#{basename} version must be the integer #{VERSION}" unless version.is_a?(Integer) && version == VERSION

      presets = @data.fetch("presets", {})
      raise ConfigError, "#{basename} presets must be a mapping" unless presets.is_a?(Hash)

      presets.each { |name, fields| validate_preset!(name, fields) }
      @data["version"] = VERSION
      @data["presets"] = presets
    end

    def validate_preset!(name, fields)
      unless name.is_a?(String) && !name.empty? && name == name.strip && name.length <= NAME_MAX_LENGTH
        raise ConfigError,
              "#{basename} preset names must be trimmed strings of at most #{NAME_MAX_LENGTH} characters"
      end

      @type == :tokens ? validate_token_preset!(name, fields) : validate_repo_preset!(name, fields)
    end

    def validate_token_preset!(name, fields)
      Rules.validate_scope_fields!(fields, "#{basename} preset #{name.inspect}")
      visibility = fields["visibility"]
      return if visibility.nil? || Config::VISIBILITIES.include?(visibility.downcase)

      raise ConfigError,
            "#{basename} preset #{name.inspect} visibility must be public, private, or all"
    end

    def validate_repo_preset!(name, fields)
      raise ConfigError, "#{basename} preset #{name.inspect} must be a mapping" unless fields.is_a?(Hash)

      fields.each do |token, action|
        unless token == ANY_TOKEN || (token.is_a?(String) && token.match?(Rules::SECRET_NAME_PATTERN))
          raise ConfigError,
                "#{basename} preset #{name.inspect} token keys must be secret names or \"#{ANY_TOKEN}\""
        end
        next if Rules::ACTIONS.include?(action)

        raise ConfigError,
              "#{basename} preset #{name.inspect} rule for #{token.inspect} must be default, include, or exclude"
      end
    end

    def validate_token_references!(config)
      names = config.secrets.filter_map { |secret| secret["name"] if secret.is_a?(Hash) }
      presets.each do |preset_name, fields|
        unknown = fields.keys - names - [ANY_TOKEN]
        next if unknown.empty?

        raise ConfigError,
              "#{basename} preset #{preset_name.inspect} references unknown tokens: #{unknown.join(', ')}"
      end
    end

    def validate_scope_references!(config)
      presets.each do |preset_name, fields|
        validate_preset_sources!(config, preset_name, fields)
        validate_preset_targets!(preset_name, fields["targets"]) if fields.key?("targets")
        validate_preset_exclusions!(config, preset_name, fields["exclude_repositories"])
      end
    end

    def validate_preset_sources!(config, preset_name, fields)
      return unless fields.key?("sources")

      unknown = Array(fields["sources"]) - config.source_ids - %w[all]
      return if unknown.empty?

      raise ConfigError,
            "#{basename} preset #{preset_name.inspect} references unknown sources: #{unknown.join(', ')}"
    end

    def validate_preset_targets!(preset_name, targets)
      targets.each do |provider_type, configured|
        adapter = Providers.adapter_for(provider_type)
        unless adapter
          raise ConfigError,
                "#{basename} preset #{preset_name.inspect} targets unsupported provider #{provider_type.inspect}"
        end

        names = configured.is_a?(Hash) ? configured.keys : Array(configured)
        unknown = names.map(&:to_s) - adapter::CONTEXTS
        next if unknown.empty?

        raise ConfigError,
              "#{basename} preset #{preset_name.inspect} has unsupported #{provider_type} contexts: #{unknown.join(', ')}"
      end
    end

    def validate_preset_exclusions!(config, preset_name, exclusions)
      return unless exclusions.is_a?(Hash)

      unknown = exclusions.keys - config.source_ids - %w[all]
      return if unknown.empty?

      raise ConfigError,
            "#{basename} preset #{preset_name.inspect} excludes repositories for unknown sources: #{unknown.join(', ')}"
    end
  end
end
