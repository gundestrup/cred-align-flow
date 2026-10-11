# frozen_string_literal: true

require "fileutils"
require "json"
require "tempfile"

module CredAlignFlow
  # Per-repository token overrides stored in a JSON file next to the YAML
  # config. The YAML file is hand-edited intent (sources, secrets, and each
  # secret's default scope); this file holds repo-specific include/exclude
  # overrides managed by the local config UI. The UI writes only this file;
  # it never modifies the YAML config.
  #
  # Format:
  #   {
  #     "version": 1,
  #     "rules": {
  #       "<source_id>": {
  #         "<owner/repo>": { "<SECRET_NAME>": "default|include|exclude" }
  #       }
  #     }
  #   }
  #
  # "include"/"exclude" override the secret's default source/visibility scope
  # for that repository; "default" restores the default and cancels a
  # hand-authored repository_rules or exclude_repositories match.
  # exclude_sources in the YAML config always wins over a rules file include.
  class Rules
    ACTIONS = %w[default include exclude].freeze
    SECRET_NAME_PATTERN = /\A[A-Za-z_][A-Za-z0-9_]*\z/
    SOURCE_ID_PATTERN = /\A[^\s|]+\z/

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

    def initialize(path, data: nil)
      @path = File.expand_path(path)
      @data = data || read_existing || empty_rules
      validate!
    end

    def entries
      @data.fetch("rules")
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
      { "version" => 1, "rules" => {} }
    end

    def validate!
      version = @data.fetch("version", 1)
      raise ConfigError, "rules file version must be the integer 1" unless version.is_a?(Integer) && version == 1

      rules = @data.fetch("rules", {})
      raise ConfigError, "rules file rules must be a mapping" unless rules.is_a?(Hash)

      rules.each { |source_id, repositories| validate_source_rules!(source_id, repositories) }
      @data["rules"] = rules
      @data["version"] = version
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
