# frozen_string_literal: true

require "yaml"

module CredAlignFlow
  class ScaffoldTargetScope
    def initialize(config, targets)
      @config = config
      @targets = Array(targets)
    end

    def resolve
      raise ConfigError, "scaffold imports require at least one explicit --target" if @targets.empty?

      normalized = @targets.map { |target| normalize_target(target) }.uniq
      source_contexts = normalized.group_by { |target| target.fetch(:source) }.transform_values do |entries|
        entries.map { |target| target.fetch(:context) }.uniq.sort
      end
      source_ids_by_type = source_contexts.keys.group_by { |source_id| @config.source(source_id).fetch("type") }
      validate_provider_contexts!(source_contexts, source_ids_by_type)
      validate_repository_contexts!(normalized)

      {
        sources: source_contexts.keys,
        targets: source_ids_by_type.to_h { |type, ids| [type, source_contexts.fetch(ids.first)] },
        repositories: normalized.group_by { |target| target.fetch(:source) }.transform_values do |entries|
          entries.map { |target| target.fetch(:repository) }.uniq.sort
        end,
        tuples: normalized.map do |target|
          [target.fetch(:source), target.fetch(:context), target.fetch(:repository)]
        end
      }
    end

    private

    def normalize_target(target)
      unless target.is_a?(Array) && target.length == 3 && target.all? { |value| value.is_a?(String) && !value.empty? }
        raise ConfigError, "each scaffold target must specify SOURCE|CONTEXT|exact OWNER/REPO"
      end

      source_id, context, repository = target
      source = @config.source(source_id)
      adapter = Providers.adapter_for(source.fetch("type"))
      raise ConfigError, "unsupported scaffold source #{source_id}" unless adapter
      raise ConfigError, "#{source_id} is pull-only and cannot be a scaffold destination" unless adapter::WRITABLE
      unless adapter::CONTEXTS.include?(context)
        raise ConfigError, "#{context.inspect} is not a supported context for #{source_id}"
      end
      unless Rules.valid_repository_name?(repository)
        raise ConfigError, "scaffold repository targets must be exact owner/name pairs"
      end

      { source: source_id, type: source.fetch("type"), context: context, repository: repository }
    end

    def validate_provider_contexts!(source_contexts, source_ids_by_type)
      source_ids_by_type.each_value do |source_ids|
        context_sets = source_ids.map { |source_id| source_contexts.fetch(source_id) }.uniq
        next if context_sets.length == 1

        raise ConfigError, "scaffold targets must use the same contexts for every source of a provider type"
      end
    end

    def validate_repository_contexts!(targets)
      targets.group_by { |target| target.fetch(:source) }.each_value do |source_targets|
        context_sets = source_targets.group_by { |target| target.fetch(:repository) }.values.map do |repository_targets|
          repository_targets.map { |target| target.fetch(:context) }.uniq.sort
        end.uniq
        next if context_sets.length == 1

        raise ConfigError, "scaffold targets must use the same context set for every selected repository per source"
      end
    end
  end

  class ScaffoldEntry
    def initialize(config, env_values, scope, at)
      @config = config
      @env_values = env_values
      @scope = scope
      @at = at
    end

    def render(name, indent)
      pad = " " * indent
      remote_name = name.upcase
      value = @config.value_for({ "name" => name, "value_env" => name }, @env_values)
      lines = [
        "",
        "#{pad}#{Scaffolder::MARKER} #{name} - imported from the env file",
        "#{pad}- name: #{quote(remote_name)}",
        "#{pad}  value_env: #{quote(name)}",
        ("#{pad}  value_digest: #{quote(Fingerprint.digest(remote_name, value))}" if value),
        "#{pad}  version: #{quote(@at.strftime('%Y-%m-%d'))}",
        "#{pad}  version_at: #{quote(@at.strftime('%Y-%m-%dT%H:%M:%SZ'))}",
        "#{pad}  visibility: all"
      ].compact
      (lines + destination_lines(pad)).join("\n") << "\n"
    end

    private

    def destination_lines(pad)
      [
        "#{pad}  sources: [#{@scope.fetch(:sources).map { |id| quote(id) }.join(', ')}]",
        "#{pad}  exclude_repositories:",
        *exclusions(pad),
        "#{pad}  repository_rules:",
        *repository_rules(pad),
        "#{pad}  targets:",
        *targets(pad)
      ]
    end

    def exclusions(pad)
      @scope.fetch(:sources).map { |source_id| "#{pad}    #{quote(source_id)}: [\"*\"]" }
    end

    def repository_rules(pad)
      @scope.fetch(:repositories).flat_map do |source_id, repositories|
        ["#{pad}    #{quote(source_id)}:", *repositories.map { |repository| "#{pad}      #{quote(repository)}: include" }]
      end
    end

    def targets(pad)
      @scope.fetch(:targets).map do |provider_type, contexts|
        context_values = contexts.map { |context| quote(context) }.join(", ")
        "#{pad}    #{quote(provider_type)}: [#{context_values}]"
      end
    end

    def quote(value)
      value.to_s.inspect
    end
  end

  # Appends active secret-entry scaffolds to the YAML config for explicitly
  # selected env-file variables and exact provider destinations. Entries are
  # managed immediately but cannot reach other repositories or contexts; the
  # user may widen their scope later, or list helper variables in
  # `ignored_env_names:` so they are never imported.
  #
  # Safety contract:
  #   * Existing text is edited by insertion only — never reformatted.
  #   * The complete generated document is parsed and fully validated under
  #     a stable sibling lock before the original file is replaced;
  #     unsupported YAML layouts raise without touching the file.
  #   * Generated scalars are always quoted so unusual source IDs or names
  #     can never corrupt the structure.
  class Scaffolder
    MARKER = "# scaffold:"

    def initialize(config_path)
      @config_path = File.expand_path(config_path)
      raise ConfigError, "Config file not found: #{@config_path}" unless File.file?(@config_path)
      raise ConfigError, "config path must not be a symlink: #{@config_path}" if File.symlink?(@config_path)

      @text = File.read(@config_path)
    end

    def candidates(env_values, config)
      validate_config_path!(config)
      candidate_names(env_values, Config.new(@config_path))
    end

    def validate_targets(config, targets)
      validate_config_path!(config)
      scope_for(Config.new(@config_path), targets).fetch(:tuples)
    end

    # Returns { "added" => [...], "digests" => [...], "skipped_digests" => [...] }.
    # `digests` are secrets whose recorded value_digest was brought in line
    # with the current env value; `skipped_digests` names secrets whose
    # digest could not be located in an editable format.
    def apply!(names, config, env_values, targets: [], at: Time.now.utc)
      validate_config_path!(config)
      AtomicFile.with_lock(@config_path) do
        @text = File.read(@config_path)
        apply_locked(names, Config.new(@config_path), env_values, targets, at)
      end
    end

    # Appends names to the top-level `ignored_env_names:` list so helper
    # variables are never reimported. Creates the key when absent.
    def ignore!(names)
      return [] if names.empty?

      AtomicFile.with_lock(@config_path) do
        @text = File.read(@config_path)
        config = Config.new(@config_path)
        additions = names.uniq - config.ignored_env_names
        next [] if additions.empty?

        lines = @text.lines
        index = lines.index { |line| line.match?(/^ignored_env_names:/) }
        new_text =
          if index
            line = lines[index]
            if line.match?(/\[\s*\]\s*(#.*)?$/)
              lines[index] = "ignored_env_names:#{" #{line[/#.*/].strip}" if line[/#.*/]}\n"
            elsif line.match?(/[\[{]/)
              raise ConfigError,
                    "flow-style `ignored_env_names:` is not supported; use a block list"
            end

            boundary = top_level_end(lines, index)
            (lines[0...boundary] + additions.map { |name| "  - #{quote(name)}\n" } + lines[boundary..]).join
          else
            "#{lines.join.sub(/\n?\z/, "\n")}\nignored_env_names:\n#{additions.map { |name| "  - #{quote(name)}\n" }.join}"
          end
        validate_generated!(new_text)
        write_atomically(new_text)
        @text = new_text
        additions
      end
    end

    private

    def apply_locked(names, config, env_values, targets, at)
      names = names.uniq
      unknown = names - candidate_names(env_values, config)
      raise ConfigError, "env names are no longer eligible for import: #{unknown.join(', ')}" unless unknown.empty?

      scope = scope_for(config, targets) unless names.empty?
      lines = @text.lines
      digest_sync = sync_digests(lines, config, env_values)
      if names.empty?
        return empty_result(digest_sync) if digest_sync["digests"].empty?

        replace_text!(lines.join)
        return empty_result(digest_sync)
      end

      insertion = secrets_insertion(lines)
      indent = insertion[:index] ? list_item_indent(lines, insertion[:index]) : 2
      entry_builder = ScaffoldEntry.new(config, env_values, scope, at)
      blocks = names.map { |name| entry_builder.render(name, indent) }
      new_text = inserted_text(lines, insertion, blocks)
      replace_text!(new_text, names)
      { "added" => names }.merge(digest_sync)
    end

    def inserted_text(lines, insertion, blocks)
      case insertion[:kind]
      when :section
        lines[insertion[:index]] = insertion[:replacement] if insertion[:replacement]
        boundary = top_level_end(lines, insertion[:index])
        (lines[0...boundary] + blocks + lines[boundary..]).join
      else
        "#{lines.join.sub(/\n?\z/, "\n")}\nsecrets:\n#{blocks.join}"
      end
    end

    def replace_text!(new_text, imported_names = [])
      validate_generated!(new_text, imported_names)
      write_atomically(new_text)
      @text = new_text
    end

    def empty_result(digest_sync)
      { "added" => [] }.merge(digest_sync)
    end

    def validate_config_path!(config)
      return if config.path == @config_path

      raise ConfigError, "scaffolder config path changed; reload before importing env names"
    end

    def candidate_names(env_values, config)
      referenced = referenced_names(config)
      ignored = config.ignored_env_names
      env_values.keys.reject do |name|
        referenced.include?(name) || ignored.include?(name) || name.end_with?("_FILE")
      end
    end

    def scope_for(config, targets)
      ScaffoldTargetScope.new(config, targets).resolve
    end

    def referenced_names(config)
      names = config.source_ids.filter_map { |source_id| config.source(source_id)["auth_env"] }
      config.secrets.each do |secret|
        names << secret["value_env"] if secret["value_env"]
        names << secret["name"] if secret["name"]
      end
      names
    end

    # Generated YAML always double-quotes scalars, so commas, colons,
    # spaces, and YAML-significant characters in names or source IDs can
    # never corrupt the document.
    def quote(value)
      value.to_s.inspect
    end

    # Finds the top-level `secrets:` key and classifies how entries can be
    # appended. Anything the inserter cannot edit safely is rejected here,
    # before any bytes are produced — a quoted "secrets" key or a second
    # document would silently shadow the real list.
    def secrets_insertion(lines)
      reject_unsupported_format!(lines)
      index = lines.index { |line| line.match?(/^secrets:/) }
      return { kind: :absent } unless index

      line = lines[index]
      if line.match?(/^secrets:\s*\[\s*\]\s*(#.*)?$/)
        # `secrets: []` followed by block items is invalid YAML; drop the
        # flow empty list but keep any trailing comment.
        comment = line[/#.*/]
        replacement = comment ? "secrets: #{comment.strip}\n" : "secrets:\n"
        return { kind: :section, index: index, replacement: replacement }
      end
      reject_uneditable_secrets_line!(line)

      { kind: :section, index: index }
    end

    def reject_unsupported_format!(lines)
      if lines.any? { |line| line.match?(/^["']secrets["']\s*:/) }
        raise ConfigError, "a quoted `secrets:` key is not supported by scaffold"
      end

      # A single leading `---` document marker (as YAML.dump emits) is fine;
      # a second document or an explicit end marker is not.
      documents = lines.each_index.select { |i| lines[i].match?(/^---/) }
      if documents.length > 1 || (documents.any? && documents.first.positive?) ||
         lines.any? { |line| line.match?(/^\.\.\./) }
        raise ConfigError, "multi-document YAML is not supported by scaffold"
      end
    end

    def reject_uneditable_secrets_line!(line)
      if line.match?(/^secrets:\s*[\[{]/)
        raise ConfigError,
              "flow-style `secrets:` collections are not supported by scaffold; " \
              "convert the list to block style (- name: ...) first"
      end
      return unless line.match?(/^secrets:\s*\S/) && !line.match?(/^secrets:\s*#/)

      raise ConfigError, "`secrets:` has a non-list value that scaffold cannot edit"
    end

    def list_item_indent(lines, index)
      boundary = top_level_end(lines, index)
      item = lines[(index + 1)...boundary].find { |line| line.match?(/^\s*-\s+\S/) }
      item ? item[/^\s*/].length : 2
    end

    def top_level_end(lines, index)
      offset = lines[(index + 1)..].index { |line| line.match?(/^\w/) }
      offset ? index + 1 + offset : lines.length
    end

    # Rewrites value_digest lines in place for secrets whose env value
    # rotated. Missing values keep their recorded digest. Secrets whose
    # entry cannot be located in editable form are reported as skipped,
    # never silently missed.
    def sync_digests(lines, config, env_values)
      updated = []
      skipped = []
      config.secrets.each do |secret|
        name = secret["name"]
        value = config.value_for(secret, env_values)
        next unless value

        digest = Fingerprint.digest(name, value)
        next if secret["value_digest"] == digest

        update_digest_line?(lines, name, digest) ? updated << name : skipped << name
      end
      { "digests" => updated, "skipped_digests" => skipped }
    end

    def update_digest_line?(lines, name, digest)
      anchor = lines.index { |line| line.match?(/^secrets:/) } || 0
      name_index = lines[(anchor + 1)..].index do |line|
        entry_name(line) == name
      end
      return false unless name_index

      name_index += anchor + 1
      indent = lines[name_index][/^\s*/].length
      limit = entry_end(lines, name_index, indent)
      entry = ((name_index + 1)...limit)
      line = "#{' ' * (indent + 2)}value_digest: #{quote(digest)}\n"
      found = entry.find { |i| lines[i].match?(/^\s*value_digest:/) }
      if found
        lines[found] = line
      else
        env_line = entry.find { |i| lines[i].match?(/^\s*value_env:/) }
        lines.insert((env_line || name_index) + 1, line)
      end
      true
    end

    def entry_name(line)
      match = line.match(/^\s*-\s+name:\s*(?:"([^"]*)"|'([^']*)'|([^\s#]+))/)
      match && (match[1] || match[2] || match[3])
    end

    def entry_end(lines, name_index, indent)
      offset = lines[(name_index + 1)..].index do |line|
        line.match?(/^[^\s#]/) || (line[/^\s*/].length <= indent && line.match?(/^\s*-\s+\S/))
      end
      offset ? name_index + 1 + offset : lines.length
    end

    # Parses the complete generated document and runs full config
    # validation before anything is replaced. On any failure the original
    # file stays untouched.
    def validate_generated!(new_text, expected_names = [])
      parsed = YAML.safe_load(new_text, aliases: false)
      raise ConfigError, "generated configuration is not a mapping" unless parsed.is_a?(Hash)

      expected_names.each do |name|
        present = Array(parsed["secrets"]).any? { |entry| entry.is_a?(Hash) && entry["name"] == name.upcase }
        raise ConfigError, "generated configuration does not contain #{name}" unless present
      end
      Config.new(@config_path, data: parsed)
      parsed
    rescue Psych::Exception => e
      raise ConfigError, "generated invalid YAML: #{e.message}"
    end

    def write_atomically(content)
      AtomicFile.write(@config_path, content, error_class: ConfigError)
    end
  end
end
