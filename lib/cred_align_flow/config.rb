# frozen_string_literal: true

require "date"
require "time"
require "yaml"

module CredAlignFlow
  class Config
    DEFAULT_NAMES = [
      "cred-align.local.yml",
      "cred-align.local.yaml",
      File.join("config", "cred-align.local.yml"),
      File.join("config", "cred-align.local.yaml"),
      File.join("config", "config.yml")
    ].freeze
    DEFAULT_ENV_NAMES = [
      ".env.local",
      File.join("config", ".env.local"),
      File.join("config", "secrets.env")
    ].freeze
    TOP_LEVEL_KEYS = %w[version state_file rules_file env_file check_for_updates update_notice_min_age_days ignored_env_names
                        sources secrets].freeze
    SOURCE_KEYS = %w[type owner owner_type host api_url url auth_env repositories].freeze
    REPOSITORY_KEYS = %w[visibility include_archived include_forks include exclude].freeze
    SECRET_KEYS = %w[
      name value_env value_digest version version_at updated_at visibility sources exclude_sources
      exclude_repositories exclude_repos repository_rules targets
    ].freeze
    DIGEST_PATTERN = Fingerprint::PATTERN
    DATE_PATTERN = /\A\d{4}-\d{2}-\d{2}\z/
    DATETIME_PATTERN = /\A\d{4}-\d{2}-\d{2}T/
    TIMESTAMP_PATTERN = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})\z/i
    ENVIRONMENT_NAME_PATTERN = /\A[A-Za-z_][A-Za-z0-9_]*\z/

    attr_reader :path, :sources, :secrets, :rules

    def self.default_path
      DEFAULT_NAMES.each do |name|
        candidate = File.expand_path(name)
        return candidate if File.exist?(candidate)
      end

      File.join(xdg_config_home, "cred-align-flow", "config.yml")
    end

    def self.default_env_path
      DEFAULT_ENV_NAMES.each do |name|
        candidate = File.expand_path(name)
        return candidate if File.exist?(candidate)
      end

      File.join(xdg_config_home, "cred-align-flow", "secrets.env")
    end

    def self.default_state_path
      xdg_state = ENV.fetch("XDG_STATE_HOME", File.join(Dir.home, ".local", "state"))
      File.join(xdg_state, "cred-align-flow", "inventory.json")
    end

    def self.xdg_config_home
      ENV.fetch("XDG_CONFIG_HOME", File.join(Dir.home, ".config"))
    end
    private_class_method :xdg_config_home

    def initialize(path, data: nil, rules: nil)
      @path = File.expand_path(path)
      raise ConfigError, "Config file not found: #{@path}" unless File.exist?(@path)

      parsed = data || YAML.safe_load_file(@path, aliases: false)
      raise ConfigError, "Config file must contain a YAML mapping" unless parsed.is_a?(Hash)

      @data = parsed
      @sources = parsed.fetch("sources", {})
      @secrets = parsed.fetch("secrets", [])
      validate!
      @rules = rules || Rules.new(rules_file)
      @rules.validate_references!(source_ids, @secrets.map { |secret| secret.fetch("name") })
    rescue Psych::Exception => e
      raise ConfigError, "Invalid config YAML: #{e.message}"
    end

    def state_file
      expand_config_path(@data.fetch("state_file", self.class.default_state_path))
    end

    def rules_file
      expand_config_path(@data.fetch("rules_file") { Rules.default_path_for(@path) })
    end

    def env_path
      expand_config_path(@data.fetch("env_file", self.class.default_env_path))
    end

    def validate_runtime_paths!(env_path:, state_path:)
      validate_file_roles!(env_path: env_path, state_path: state_path)
    end

    def source_ids
      @sources.keys
    end

    def source(id)
      @sources.fetch(id) { raise ConfigError, "Unknown source: #{id}" }
    end

    def ignored_env_names
      @data.fetch("ignored_env_names", [])
    end

    def check_for_updates?
      @data.fetch("check_for_updates", false)
    end

    def update_notice_min_age_days
      @data.fetch("update_notice_min_age_days", 7)
    end

    # Stable identity for a configured source — type + endpoint + owner —
    # so applied records and inventory snapshots can detect when a source
    # ID was rebound to a different account or host.
    def source_key(source_id)
      source = source(source_id)
      type = source.fetch("type")
      endpoint =
        case type
        when "github" then Providers::GitHub.host_for(source)
        when "forgejo" then Providers::Forgejo.api_base_for(source)
        else
          [source["host"], source["api_url"], source["url"]].compact.first.to_s
        end
      "#{type}|#{endpoint}|#{source['owner']}"
    end

    def repositories_config(source_id)
      repo_config = source(source_id).fetch("repositories", {})
      raise ConfigError, "repositories for #{source_id} must be a mapping" unless repo_config.is_a?(Hash)

      validate_keys!(repo_config, REPOSITORY_KEYS, "repositories for #{source_id}")
      include = string_list!(repo_config.fetch("include", []), "repositories.include")
      include.each do |repository|
        next unless repository.match?(/[*?\[\]{}]/)

        raise ConfigError, "repositories.include accepts exact names only because it disables discovery: #{repository.inspect}"
      end
      exclude = string_list!(repo_config.fetch("exclude", []), "repositories.exclude")
      include_archived = boolean!(repo_config.fetch("include_archived", false), "repositories.include_archived")
      include_forks = boolean!(repo_config.fetch("include_forks", false), "repositories.include_forks")

      {
        "visibility" => normalize_visibility(repo_config.fetch("visibility", "public")),
        "include_archived" => include_archived,
        "include_forks" => include_forks,
        "include" => include,
        "exclude" => exclude
      }
    end

    def secret_applies_to_source?(secret, source_id)
      return false if Array(secret["exclude_sources"]).map(&:to_s).include?(source_id)
      return true if secret_source_selected_by_default?(secret, source_id)
      return true if @rules.any_include?(source_id, secret.fetch("name"))

      secret.fetch("repository_rules", {}).fetch(source_id, {}).value?("include")
    end

    def secret_assignment(secret, source_id, repository)
      repo_name = if repository.is_a?(Hash)
                    repository.fetch("nameWithOwner", repository.fetch("name_with_owner", ""))
                  else
                    repository.to_s
                  end
      if Array(secret["exclude_sources"]).map(&:to_s).include?(source_id)
        return ["excluded_manual", "source is explicitly excluded"]
      end

      repository_rule = secret_repository_rule(secret, source_id, repo_name)
      return ["assigned_manual", "explicit repository include"] if repository_rule == "include"
      return ["excluded_manual", "explicit repository exclusion"] if repository_rule == "exclude"

      if repository_rule != "default" && Selector.matches_any?(secret_exclusions(secret, source_id), repository)
        return ["excluded_manual", "matches an explicit repository exclusion"]
      end
      unless secret_source_selected_by_default?(secret, source_id)
        return ["excluded_default", "source is outside the token's default source scope"]
      end
      unless Selector.visibility_matches?(repository, secret_visibility(secret))
        return ["excluded_default", "repository visibility is outside the token's default scope"]
      end

      ["assigned_default", "matches the token's default source and visibility rules"]
    end

    # rules.json overrides a hand-authored repository_rules entry for the
    # same source/repository/secret; the YAML layer is the fallback.
    def secret_repository_rule(secret, source_id, repository_name)
      @rules.rule(source_id, repository_name, secret.fetch("name")) ||
        secret.fetch("repository_rules", {}).fetch(source_id, {})[repository_name]
    end

    # Where the effective per-repository rule comes from: "rules" (the UI
    # file), "yaml" (hand-authored repository_rules), or nil (defaults).
    # The UI needs this to distinguish "delete the JSON override" from
    # "write an explicit default that cancels YAML intent".
    def repository_rule_provenance(secret, source_id, repository_name)
      name = secret.fetch("name")
      return "rules" if @rules.rule(source_id, repository_name, name)
      return "yaml" if secret.fetch("repository_rules", {}).fetch(source_id, {})[repository_name]

      nil
    end

    def contexts_for(secret, source_id)
      source_type = source(source_id).fetch("type")
      targets = secret.fetch("targets", {})
      raw = targets.is_a?(Hash) ? targets[source_type] : nil

      contexts =
        case raw
        when Hash
          raw.select { |_name, enabled| enabled }.keys
        when nil
          source_type == "github" ? ["actions"] : []
        else
          Array(raw)
        end

      contexts.map(&:to_s).uniq
    end

    def contexts_for_source(source_id)
      secrets.each_with_object([]) do |secret, contexts|
        next unless secret_applies_to_source?(secret, source_id)

        contexts.concat(contexts_for(secret, source_id))
      end.uniq
    end

    def secret_visibility(secret)
      normalize_visibility(secret.fetch("visibility", "public"))
    end

    def secret_exclusions(secret, source_id)
      exclusions = secret["exclude_repositories"] || secret["exclude_repos"] || []
      case exclusions
      when Hash
        Array(exclusions[source_id]) + Array(exclusions["all"])
      else
        Array(exclusions)
      end.map(&:to_s)
    end

    def secret_source_selected_by_default?(secret, source_id)
      configured = Array(secret["sources"]).map(&:to_s)
      configured.empty? || configured.include?("all") || configured.include?(source_id)
    end

    def secret_version(secret)
      secret.fetch("version", "1").to_s
    end

    def secret_version_time(secret)
      explicit = secret["version_at"] || secret["updated_at"]
      value = explicit || secret["version"]
      return nil if value.nil?
      return value.utc if value.is_a?(Time)

      parse_version_time(value.to_s, explicit: !explicit.nil?)
    end

    def value_ref(secret)
      secret.fetch("value_env", secret.fetch("name")).to_s
    end

    def value_for(secret, env_values)
      ref = value_ref(secret)
      value = env_values[ref] || ENV.fetch(ref, nil)
      return nil if value.nil? || value.empty?

      value
    end

    # Keyed fingerprint of the current desired value — the material the
    # planner compares against the applied journal. Never exposed in UI
    # payloads; see Fingerprint for the key handling.
    def desired_fingerprint(secret, env_values)
      value = value_for(secret, env_values)
      value ? Fingerprint.digest(secret.fetch("name"), value) : nil
    end

    # :current, :changed (recorded digest but value rotated), :missing (no
    # value), :unverifiable (keyed digest but no key), or :unrecorded.
    def value_digest_status(secret, env_values)
      recorded = secret["value_digest"]
      return :unrecorded unless Fingerprint.valid_format?(recorded)

      value = value_for(secret, env_values)
      return :missing unless value
      return :unverifiable if recorded.start_with?(Fingerprint::PREFIX) && !Fingerprint.configured?

      Fingerprint.matches?(recorded, secret.fetch("name"), value) ? :current : :changed
    end

    # Relative state_file/rules_file paths resolve against the config file's
    # directory so a self-contained config/ dir stays portable.
    def expand_config_path(value)
      File.expand_path(value.to_s, File.dirname(@path))
    end
  end
end

require_relative "config_validation"
