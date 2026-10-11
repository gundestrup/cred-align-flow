# frozen_string_literal: true

module CredAlignFlow
  class Config
    private

    def validate!
      validate_keys!(@data, TOP_LEVEL_KEYS, "config")
      version = @data.fetch("version", 1)
      raise ConfigError, "version must be the integer 1" unless version.is_a?(Integer) && version == 1

      boolean!(@data.fetch("check_for_updates", false), "check_for_updates")

      %w[state_file rules_file env_file].each do |key|
        next unless @data.key?(key)

        value = @data[key]
        raise ConfigError, "#{key} must be a nonempty path string" unless value.is_a?(String) && !value.empty?
      end
      raise ConfigError, "sources must be a nonempty mapping" unless @sources.is_a?(Hash) && !@sources.empty?
      raise ConfigError, "secrets must be an array" unless @secrets.is_a?(Array)

      validate_ignored_env_names!
      @sources.each { |id, source| validate_source!(id, source) }
      validate_github_account_auth!
      validate_secrets!
      validate_file_roles!
    end

    def validate_ignored_env_names!
      return unless @data.key?("ignored_env_names")

      ignored = string_list!(@data["ignored_env_names"], "ignored_env_names")
      ignored.each { |name| validate_environment_name!(name, "ignored_env_names entry") }
    end

    # File roles must refer to different real files: a collision lets an
    # atomic state/rules write replace the hand-edited config, env file, or
    # fingerprint key. env_file may be a symlink (secrets-store indirection);
    # other write targets must not be symlinks because atomic replace would
    # substitute the link itself.
    def validate_file_roles!(env_path: nil, state_path: nil)
      env_path ||= self.env_path
      state_path ||= state_file
      roles = {
        "config" => @path,
        "env_file" => File.expand_path(env_path),
        "fingerprint_key" => Fingerprint.default_key_file(env_path),
        "rules_file" => rules_file,
        "state_file" => File.expand_path(state_path)
      }
      identities = roles.transform_values { |path| canonical_path(path) }
      roles.to_a.combination(2) do |(a, path_a), (b, path_b)|
        raise ConfigError, "#{a} and #{b} must refer to different files (#{path_a})" if identities[a] == identities[b]

        next unless File.exist?(path_a) && File.exist?(path_b)

        raise ConfigError, "#{a} and #{b} refer to the same file (#{path_a})" if File.identical?(path_a, path_b)
      end

      roles.each do |role, path|
        next if role == "env_file"
        next unless File.symlink?(path)

        raise ConfigError, "#{role} must not be a symlink (atomic writes would replace the link): #{path}"
      end
    end

    def canonical_path(path)
      expanded = File.expand_path(path)
      cursor = expanded
      suffix = []
      until File.exist?(cursor) || File.symlink?(cursor)
        parent = File.dirname(cursor)
        break if parent == cursor

        suffix.unshift(File.basename(cursor))
        cursor = parent
      end
      File.join(File.realpath(cursor), *suffix)
    rescue Errno::ENOENT
      expanded
    end

    def validate_source!(id, source)
      validate_source_shape!(id, source)

      case source["type"]
      when "github" then validate_github_source!(id, source)
      when "forgejo" then validate_forgejo_source!(id, source)
      end

      repositories_config(id)
    rescue ProviderError => e
      raise ConfigError, "Invalid source #{id}: #{e.message}"
    end

    def validate_source_shape!(id, source)
      unless id.is_a?(String) && !id.empty? && !id.match?(/[|\s]/)
        raise ConfigError, "source name #{id.inspect} must be a nonempty string without whitespace or |"
      end
      raise ConfigError, "source #{id} must be a mapping" unless source.is_a?(Hash)

      validate_keys!(source, SOURCE_KEYS, "source #{id}")
      type = source["type"]
      raise ConfigError, "source #{id} is missing a string type" unless type.is_a?(String) && !type.empty?
      unless Providers.adapter_for(type)
        raise ConfigError, "unsupported source type #{type.inspect}; supported types: #{Providers.supported_types.join(', ')}"
      end

      validate_source_fields!(id, source)
    end

    def validate_source_fields!(id, source)
      %w[host api_url url auth_env].each do |key|
        next unless source.key?(key)
        raise ConfigError, "source #{id} #{key} must be a string" unless source[key].is_a?(String)
      end

      validate_environment_name!(source["auth_env"], "source #{id} auth_env") if source.key?("auth_env")
      raise ConfigError, "source #{id} must use only one of url or api_url" if source.key?("url") && source.key?("api_url")
      return unless source.key?("owner") && source["owner"].to_s.match?(/[|\s]/)

      raise ConfigError, "source #{id} owner must not contain whitespace or |"
    end

    def validate_github_source!(id, source)
      if source.key?("host") && (source.key?("url") || source.key?("api_url"))
        raise ConfigError, "GitHub source #{id} must use host or url/api_url, not both"
      end
      raise ConfigError, "owner_type is only valid for Forgejo sources" if source.key?("owner_type")

      validate_nonempty_string!(source["owner"], "source #{id} owner")
      if source.key?("host")
        host = source["host"]
        raise ConfigError, "source #{id} host must be a hostname, not a URL" unless host.match?(/\A[A-Za-z0-9.-]+\z/)
      end
      Providers::GitHub.host_for(source)
    end

    def validate_forgejo_source!(id, source)
      raise ConfigError, "host is only valid for GitHub sources" if source.key?("host")
      raise ConfigError, "source #{id} owner must be a string" if source.key?("owner") && !source["owner"].is_a?(String)

      owner_type = source.fetch("owner_type", "user")
      unless %w[user org organization].include?(owner_type)
        raise ConfigError, "Forgejo source #{id} owner_type must be user or organization"
      end
      if %w[org organization].include?(owner_type) && source["owner"].to_s.empty?
        raise ConfigError, "Forgejo organization source #{id} requires an owner"
      end

      Providers::Forgejo.new(source, {})
    end

    def validate_github_account_auth!
      sources_by_host = @sources.select { |_id, source| source["type"] == "github" }
                                .group_by { |_id, source| Providers::GitHub.host_for(source) }
      sources_by_host.each do |host, entries|
        next if entries.length < 2

        missing_auth = entries.select { |_id, source| source["auth_env"].to_s.empty? }.map(&:first)
        next if missing_auth.empty?

        raise ConfigError,
              "GitHub sources sharing host #{host} must each set auth_env to select accounts explicitly: " \
              "#{missing_auth.join(', ')}"
      end
    end

    def validate_secrets!
      names = []
      @secrets.each_with_index do |secret, index|
        context = "secret entry #{index + 1}"
        name = validate_secret!(secret, context)
        raise ConfigError, "duplicate secret name: #{name}" if names.include?(name)

        names << name
      end
    end

    def validate_secret!(secret, context)
      raise ConfigError, "#{context} must be a mapping" unless secret.is_a?(Hash)

      validate_keys!(secret, SECRET_KEYS, context)
      name = validate_secret_name!(secret["name"], context)
      validate_environment_name!(secret["value_env"], "#{context} value_env") if secret.key?("value_env")
      validate_secret_versioning!(secret, context)
      normalize_visibility(secret["visibility"]) if secret.key?("visibility")
      validate_secret_sources!(secret, context)
      validate_secret_exclusions!(secret, context)
      validate_secret_repository_rules!(secret, context)
      validate_targets!(secret, context)
      name
    end

    def validate_secret_name!(name, context)
      validate_nonempty_string!(name, "#{context} name")
      raise ConfigError, "#{context} name exceeds the 100-character GitHub limit" if name.length > 100
      # GitHub uppercases secret names and compares case-insensitively, so
      # local names are required to already be in remote form; mixed-case
      # names would plan creates forever and leak "unexpected" reports.
      unless name.match?(/\A[A-Z_][A-Z0-9_]*\z/)
        raise ConfigError,
              "secret name #{name.inspect} must be uppercase letters, digits, and underscores " \
              "(providers store secret names uppercase)"
      end
      raise ConfigError, "secret name #{name.inspect} uses the reserved GITHUB_ prefix" if name.start_with?("GITHUB_")

      name
    end

    def validate_secret_versioning!(secret, context)
      if secret.key?("value_digest") && !Fingerprint.valid_format?(secret["value_digest"])
        raise ConfigError, "#{context} value_digest must be \"hmac-sha256:<64 hex>\" (or legacy \"sha256:<64 hex>\")"
      end
      raise ConfigError, "#{context} version must be a string" if secret.key?("version") && !secret["version"].is_a?(String)
      if secret.key?("version_at") && secret.key?("updated_at")
        raise ConfigError, "#{context} must use only one of version_at or updated_at"
      end

      version_time = secret_version_time(secret)
      return unless version_time && version_time > Time.now.utc + 300

      raise ConfigError,
            "#{context} version_at is in the future; desired timestamps must not " \
            "predate remote-change detection"
    end

    def validate_secret_sources!(secret, context)
      if secret.key?("sources")
        sources = string_list!(secret["sources"], "#{context} sources")
        raise ConfigError, "#{context} sources must not be empty; omit it to use all sources" if sources.empty?
        if sources.include?("all") && sources.length != 1
          raise ConfigError, "#{context} sources cannot combine all with named sources"
        end

        unknown = sources.reject { |source_id| source_id == "all" || @sources.key?(source_id) }
        raise ConfigError, "#{context} references unknown sources: #{unknown.join(', ')}" unless unknown.empty?
      end

      return unless secret.key?("exclude_sources")

      excluded = string_list!(secret["exclude_sources"], "#{context} exclude_sources")
      unknown = excluded - @sources.keys
      raise ConfigError, "#{context} excludes unknown sources: #{unknown.join(', ')}" unless unknown.empty?
    end

    def validate_secret_exclusions!(secret, context)
      if secret.key?("exclude_repositories") && secret.key?("exclude_repos")
        raise ConfigError, "#{context} must use only one of exclude_repositories or exclude_repos"
      end

      key = secret.key?("exclude_repositories") ? "exclude_repositories" : "exclude_repos"
      return unless secret.key?(key)

      exclusions = secret[key]
      if exclusions.is_a?(Hash)
        exclusions.each do |source_id, patterns|
          unless source_id == "all" || @sources.key?(source_id)
            raise ConfigError, "#{context} excludes repositories for unknown source #{source_id.inspect}"
          end

          string_list!(patterns, "#{context} #{key}[#{source_id}]")
        end
      else
        string_list!(exclusions, "#{context} #{key}")
      end
    end

    def validate_secret_repository_rules!(secret, context)
      return unless secret.key?("repository_rules")

      rules = secret["repository_rules"]
      raise ConfigError, "#{context} repository_rules must be a mapping" unless rules.is_a?(Hash)

      rules.each do |source_id, repositories|
        unless @sources.key?(source_id)
          raise ConfigError, "#{context} repository_rules references unknown source #{source_id.inspect}"
        end
        raise ConfigError, "#{context} repository_rules for #{source_id} must be a mapping" unless repositories.is_a?(Hash)
        unless repositories.keys.all? { |name| valid_repository_name?(name) }
          raise ConfigError, "#{context} repository names must be exact owner/name pairs"
        end

        repositories.each do |name, rule|
          unless Rules::ACTIONS.include?(rule)
            raise ConfigError, "#{context} repository rule for #{name.inspect} must be default, include, or exclude"
          end
        end
      end
    end

    def valid_repository_name?(name)
      Rules.valid_repository_name?(name)
    end

    def validate_targets!(secret, context)
      return unless secret.key?("targets")

      targets = secret["targets"]
      raise ConfigError, "#{context} targets must be a mapping" unless targets.is_a?(Hash)

      targets.each do |provider_type, configured_contexts|
        adapter = Providers.adapter_for(provider_type)
        raise ConfigError, "#{context} targets unsupported provider #{provider_type.inspect}" unless adapter

        contexts = if configured_contexts.is_a?(Hash)
                     configured_contexts.each do |name, enabled|
                       unless [true, false].include?(enabled)
                         raise ConfigError, "#{context} target #{provider_type}.#{name} must be boolean"
                       end
                     end
                     configured_contexts.keys
                   else
                     string_list!(configured_contexts, "#{context} targets.#{provider_type}")
                   end
        unknown = contexts.map(&:to_s).uniq - adapter::CONTEXTS
        raise ConfigError, "#{context} has unsupported #{provider_type} contexts: #{unknown.join(', ')}" unless unknown.empty?
      end
    end

    def validate_keys!(mapping, allowed, context)
      raise ConfigError, "#{context} keys must be strings" unless mapping.keys.all?(String)

      unknown = mapping.keys - allowed
      raise ConfigError, "#{context} has unknown keys: #{unknown.join(', ')}" unless unknown.empty?
    end

    def validate_nonempty_string!(value, context)
      return if value.is_a?(String) && !value.empty?

      raise ConfigError, "#{context} must be a nonempty string"
    end

    def validate_environment_name!(value, context)
      return if value.is_a?(String) && value.match?(ENVIRONMENT_NAME_PATTERN)

      raise ConfigError, "#{context} must be a valid environment variable name"
    end

    def string_list!(value, context)
      value = [value] if value.is_a?(String)
      unless value.is_a?(Array) && value.all? { |entry| entry.is_a?(String) && !entry.empty? }
        raise ConfigError, "#{context} must be a string or an array of nonempty strings"
      end

      value
    end

    def boolean!(value, context)
      return value if [true, false].include?(value)

      raise ConfigError, "#{context} must be true or false"
    end

    def normalize_visibility(value)
      raise ConfigError, "visibility must be a string" unless value.is_a?(String)

      visibility = value.downcase
      return visibility if %w[public private all].include?(visibility)

      raise ConfigError, "visibility must be public, private, or all (got #{value.inspect})"
    end

    def parse_version_time(value, explicit: false)
      value = value.to_s
      if DATE_PATTERN.match?(value)
        date = Date.iso8601(value)
        return Time.utc(date.year, date.month, date.day)
      end
      return Time.iso8601(value).utc if TIMESTAMP_PATTERN.match?(value)
      if explicit || DATETIME_PATTERN.match?(value)
        raise ConfigError,
              "version_at/updated_at must be an ISO8601 date or include a timezone offset (got #{value.inspect})"
      end

      nil
    rescue ArgumentError => e
      raise ConfigError, "invalid version_at/updated_at timestamp: #{value.inspect} (#{e.message})"
    end
  end
end
