# frozen_string_literal: true

require "fileutils"
require "json"
require "tempfile"

module CredAlignFlow
  # UI-managed file stored next to the YAML config. The YAML file is
  # hand-edited intent (sources, token identity, and each token's YAML
  # defaults); this file holds the local config UI's managed state:
  #
  #   {
  #     "version": 2,
  #     "rules": {
  #       "<source_id>": {
  #         "<owner/repo>": { "<SECRET_NAME>": "default|include|exclude" }
  #       }
  #     },
  #     "token_defaults": {
  #       "<SECRET_NAME>": { "visibility" => ..., "sources" => ...,
  #                          "targets" => ..., "exclude_repositories" => ... }
  #     }
  #   }
  #
  # "rules" — "include"/"exclude" override the secret's default
  # source/visibility scope for that repository; "default" restores the
  # default and cancels a hand-authored repository_rules or
  # exclude_repositories match. exclude_sources in the YAML config always
  # wins over a rules file include.
  #
  # "token_defaults" — per-secret default-scope overrides that replace the
  # same-named YAML fields (a field absent here keeps the YAML value).
  # Identity and lifecycle keys (name, value_env, digests, versions,
  # exclude_sources, repository_rules) are never overridable.
  #
  # Named presets live in the sibling preset files (see PresetLibrary);
  # the UI stamps them into this file by copy.
  #
  # Version 1 files contain only "rules". Version 2 adds
  # "token_defaults"; older builds reject the file outright instead of
  # silently ignoring overrides that change the plan.
  class Rules
    ACTIONS = %w[default include exclude].freeze
    SECRET_NAME_PATTERN = /\A[A-Za-z_][A-Za-z0-9_]*\z/
    SOURCE_ID_PATTERN = /\A[^\s|]+\z/
    TOKEN_DEFAULT_KEYS = %w[visibility sources targets exclude_repositories].freeze
    TOP_LEVEL_KEYS = %w[version rules token_defaults].freeze
    SUPPORTED_VERSIONS = [1, 2].freeze

    attr_reader :path, :data

    def self.default_path_for(config_path)
      expanded = File.expand_path(config_path)
      stem = File.basename(expanded).sub(/\.ya?ml\z/i, "").sub(/\.local\z/i, "")
      name = stem == "config" ? "rules.json" : "#{stem}.rules.json"
      File.join(File.dirname(expanded), name)
    end

    def self.valid_repository_name?(name)
      return false unless name.is_a?(String) && name.count("/") == 1

      owner, repository = name.split("/", -1)
      !owner.empty? && !repository.empty? && !name.match?(/[\s*?\[\]{}|]/)
    end

    # Shape-level checks only: source existence, visibility values, and
    # target contexts are validated when Config merges a token_defaults
    # entry into its secret and runs full secret validation. Preset
    # libraries reuse the same shapes for token presets.
    def self.validate_scope_fields!(fields, context)
      raise ConfigError, "#{context} must be a mapping" unless fields.is_a?(Hash)

      unknown = fields.keys - TOKEN_DEFAULT_KEYS
      raise ConfigError, "#{context} has unknown keys: #{unknown.join(', ')}" unless unknown.empty?

      fields.each do |key, value|
        valid =
          case key
          when "visibility" then value.is_a?(String)
          when "sources" then string_list_shape?(value)
          when "targets" then targets_shape?(value)
          when "exclude_repositories" then exclusions_shape?(value)
          end
        raise ConfigError, "#{context} #{key} has an invalid shape" unless valid
      end
    end

    def self.string_list_shape?(value)
      return true if value.is_a?(String) && !value.empty?
      return false unless value.is_a?(Array)

      value.all? { |entry| entry.is_a?(String) && !entry.empty? }
    end
    private_class_method :string_list_shape?

    def self.targets_shape?(value)
      return false unless value.is_a?(Hash)

      value.all? do |_type, contexts|
        string_list_shape?(contexts) ||
          (contexts.is_a?(Hash) && contexts.values.all? { |enabled| [true, false].include?(enabled) })
      end
    end
    private_class_method :targets_shape?

    def self.exclusions_shape?(value)
      return string_list_shape?(value) unless value.is_a?(Hash)

      value.all? { |_source, patterns| string_list_shape?(patterns) }
    end
    private_class_method :exclusions_shape?

    def initialize(path, data: nil)
      @path = File.expand_path(path)
      @data = data || read_existing || empty_rules
      validate!
    end

    def entries
      @data.fetch("rules")
    end

    def token_defaults
      @data.fetch("token_defaults")
    end

    def default_overlay(secret_name)
      token_defaults[secret_name]
    end

    def rule(source_id, repository_name, secret_name)
      entries.dig(source_id, repository_name, secret_name)
    end

    def any_include?(source_id, secret_name)
      entries.fetch(source_id, {}).any? { |_repo, secrets| secrets[secret_name] == "include" }
    end

    def validate_references!(source_ids, secret_names)
      entries.each do |source_id, repositories|
        unless source_ids.include?(source_id)
          raise ConfigError, "#{File.basename(@path)} references unknown source #{source_id.inspect}"
        end

        repositories.each do |repository_name, secrets|
          unknown = secrets.keys - secret_names
          next if unknown.empty?

          raise ConfigError,
                "#{File.basename(@path)} rules for #{repository_name.inspect} reference " \
                "unknown tokens: #{unknown.join(', ')}"
        end
      end

      unknown = token_defaults.keys - secret_names
      return if unknown.empty?

      raise ConfigError,
            "#{File.basename(@path)} token_defaults references unknown tokens: #{unknown.join(', ')}"
    end

    def save!
      directory = File.dirname(@path)
      directory_existed = File.directory?(directory)
      FileUtils.mkdir_p(directory)
      FileUtils.chmod(0o700, directory) unless directory_existed
      Tempfile.create([".cred-align-flow-rules-", ".tmp"], directory, mode: 0o600) do |file|
        file.write("#{JSON.pretty_generate(@data)}\n")
        file.flush
        file.fsync
        File.chmod(0o600, file.path)
        File.rename(file.path, @path)
      end
      File.chmod(0o600, @path)
    rescue SystemCallError => e
      raise ConfigError, "could not save rules file: #{e.message}"
    end

    private

    def read_existing
      return nil unless File.exist?(@path)

      parsed = JSON.parse(File.read(@path))
      raise ConfigError, "Rules file must contain a JSON object: #{@path}" unless parsed.is_a?(Hash)

      parsed
    rescue JSON::ParserError => e
      raise ConfigError, "Invalid rules file #{@path}: #{e.message}"
    end

    def empty_rules
      { "version" => 1, "rules" => {}, "token_defaults" => {} }
    end

    def validate!
      unknown = @data.keys - TOP_LEVEL_KEYS
      raise ConfigError, "rules file has unknown keys: #{unknown.join(', ')}" unless unknown.empty?

      version = @data.fetch("version", 1)
      unless version.is_a?(Integer) && SUPPORTED_VERSIONS.include?(version)
        raise ConfigError, "rules file version must be the integer 1 or 2"
      end

      rules = validate_rules_section!
      defaults = validate_defaults_section!

      if version == 1 && defaults.any?
        raise ConfigError,
              "rules file version 1 holds only per-repository rules; " \
              "token_defaults require version 2"
      end

      @data["rules"] = rules
      @data["token_defaults"] = defaults
      @data["version"] = defaults.empty? ? 1 : 2
    end

    def validate_rules_section!
      rules = @data.fetch("rules", {})
      raise ConfigError, "rules file rules must be a mapping" unless rules.is_a?(Hash)

      rules.each { |source_id, repositories| validate_source_rules!(source_id, repositories) }
      rules
    end

    def validate_defaults_section!
      validate_mapping_section!("token_defaults").each do |name, fields|
        unless name.is_a?(String) && name.match?(SECRET_NAME_PATTERN)
          raise ConfigError, "token_defaults keys must be valid secret names (#{name.inspect})"
        end

        self.class.validate_scope_fields!(fields, "token_defaults entry for #{name.inspect}")
      end
    end

    def validate_mapping_section!(key)
      section = @data.fetch(key, {})
      raise ConfigError, "rules file #{key} must be a mapping" unless section.is_a?(Hash)

      section
    end

    def validate_source_rules!(source_id, repositories)
      unless source_id.is_a?(String) && !source_id.empty? && source_id.match?(SOURCE_ID_PATTERN)
        raise ConfigError, "rules file has invalid source name #{source_id.inspect}"
      end
      raise ConfigError, "rules for source #{source_id.inspect} must be a mapping" unless repositories.is_a?(Hash)

      repositories.each do |repository_name, secrets|
        unless self.class.valid_repository_name?(repository_name)
          raise ConfigError, "rules for #{source_id.inspect} must use exact owner/name repository keys"
        end
        raise ConfigError, "rules for #{repository_name.inspect} must be a mapping" unless secrets.is_a?(Hash)

        secrets.each do |secret_name, action|
          unless secret_name.is_a?(String) && secret_name.match?(SECRET_NAME_PATTERN)
            raise ConfigError, "rule token names must be valid secret names (#{secret_name.inspect})"
          end
          unless ACTIONS.include?(action)
            raise ConfigError,
                  "rule for #{secret_name.inspect} on #{repository_name.inspect} must be default, include, or exclude"
          end
        end
      end
    end
  end
end
