# frozen_string_literal: true

require_relative "config_view_repositories"

module CredAlignFlow
  # Builds the read-only view model for the config UI. Secret values and
  # value fingerprints are never included — only availability and digest
  # status. Rule provenance is reported separately from the effective rule
  # so the page can distinguish "delete a JSON override" from "write an
  # explicit default that cancels YAML intent".
  class ConfigView
    include ConfigViewRepositories

    # presets is a {"tokens" => PresetLibrary, "repos" => PresetLibrary}
    # pair — the candidate libraries during preview, the saved ones
    # otherwise.
    def initialize(config:, state:, env_values:, revision:, presets:,
                   display_revision: revision, scaffolder: nil)
      @config = config
      @state = state
      @env_values = env_values
      @revision = revision
      @display_revision = display_revision
      @scaffolder = scaffolder
      @token_presets = presets.fetch("tokens")
      @repo_presets = presets.fetch("repos")
    end

    def to_h
      {
        "config_file" => File.basename(@config.path),
        "rules_file" => File.basename(@config.rules_file),
        "preset_files" => {
          "tokens" => File.basename(@token_presets.path),
          "repos" => File.basename(@repo_presets.path)
        },
        "revision" => @revision,
        "display_revision" => @display_revision,
        "generated_at" => @state.data["generated_at"],
        "check_for_updates" => @config.check_for_updates?,
        "provider_contexts" => provider_contexts,
        "owner_contexts" => provider_types.to_h do |type|
          [type, Providers.adapter_for(type).owner_scoped_contexts]
        end,
        "builtin_token_presets" => json_safe(Providers.builtin_token_presets(provider_types)),
        "secrets" => secret_entries,
        "sources" => source_entries,
        "rules" => @config.rules.entries,
        "token_defaults" => @config.rules.token_defaults,
        "token_presets" => @token_presets.presets,
        "repo_presets" => @repo_presets.presets,
        "orphan_rules" => orphan_rules,
        "unimported_env_names" => unimported_env_names,
        "ignored_env_names" => @config.ignored_env_names,
        "scaffold_action" => @config.scaffold_action,
        "action_summary" => action_summary,
        "meta" => UiMetadata.to_h
      }
    end

    private

    def provider_contexts
      provider_types.to_h do |type|
        [type, Providers.adapter_for(type)::CONTEXTS]
      end
    end

    def provider_types
      @config.source_ids.map { |source_id| @config.source(source_id).fetch("type") }.uniq
    end

    # "config" is the effective entry (YAML merged with rules-file
    # token_defaults); "yaml" is the hand-edited source entry and
    # "overrides" the overlay fields, so the page can show provenance and
    # reset overrides without resending merged data.
    def secret_entries
      @config.secrets.each_with_index.map do |secret, index|
        raw = @config.raw_secrets[index]
        {
          "config" => json_safe(secret).except("value_digest"),
          "yaml" => raw.is_a?(Hash) ? json_safe(raw).except("value_digest") : {},
          "overrides" => json_safe(@config.rules.default_overlay(secret["name"]) || {}),
          "value_available" => !@config.value_for(secret, @env_values).nil?,
          "value_digest_status" => @config.value_digest_status(secret, @env_values).to_s
        }
      end
    end

    def unimported_env_names
      return [] unless @scaffolder

      @scaffolder.candidates(@env_values, @config)
    rescue ConfigError
      []
    end

    def action_summary
      build_plan_items.group_by(&:action).transform_values(&:length)
    end

    def source_entries
      build_plan_items
      @config.source_ids.each_with_index.map do |source_id, source_index|
        source = @config.source(source_id)
        node = @state.data.dig("sources", source_id)
        repositories = node ? node.fetch("repositories", {}) : {}
        status = InventoryCheck.source_status(@config, @state, source_id)
        missing_contexts = status["missing_contexts"]
        adapter = Providers.adapter_for(source.fetch("type"))
        {
          "id" => source_id,
          "type" => source.fetch("type"),
          "owner" => source.fetch("owner", ""),
          "writable" => adapter.nil? || adapter::WRITABLE,
          "owner_scope_writable" => adapter ? adapter.owner_scope_writable?(source) : false,
          "discovered_at" => node && node["discovered_at"],
          "inventory_state" => status["state"],
          "stale_reasons" => status["reasons"],
          "contexts_not_refreshed" => missing_contexts,
          "repositories" => repositories.sort_by { |name, _repo| name }.each_with_index.map do |(name, repo), repo_index|
            repository_entry(source_id, source_index, repo_index, name, repo, node, missing_contexts)
          end
        }
      end
    end

    def repository_entry(source_id, source_index, repo_index, name, repository, node, missing_contexts)
      assignment_rows = @config.secrets.map do |secret|
        repository_rule_entry(secret, source_id, name, repository, node, missing_contexts)
      end
      {
        "name" => repository.fetch("name_with_owner", name),
        "id" => repository["id"].to_s,
        "visibility" => repository.fetch("visibility", "unknown").to_s.downcase,
        "selected" => repository["selected"] == true,
        "admin" => repository["admin"] == true,
        "anchor" => "repo-#{source_index}-#{repo_index}",
        "rule_modes" => assignment_rows.to_h { |row| [row.fetch("secret_name"), row.fetch("rule_mode")] },
        "rule_sources" => assignment_rows.to_h { |row| [row.fetch("secret_name"), row.fetch("rule_source")] },
        "legacy_exclusions" => assignment_rows.to_h { |row| [row.fetch("secret_name"), row.fetch("legacy_exclusion")] },
        "locked_sources" => assignment_rows.to_h { |row| [row.fetch("secret_name"), row.fetch("source_locked")] },
        "crosses_scope" => assignment_rows.to_h { |row| [row.fetch("secret_name"), row.fetch("crosses_scope")] },
        "assigned" => assignment_rows.filter_map { |row| row["assigned"] },
        "not_assigned" => assignment_rows.filter_map { |row| row["not_assigned"] },
        "unexpected" => unexpected_items(source_id, name)
      }
    end

    def orphan_rules
      @config.rules.entries.flat_map do |source_id, repositories|
        known = @state.data.dig("sources", source_id, "repositories")
        next [] unless known

        repositories.flat_map do |repository_name, secrets|
          next [] if known.key?(repository_name)

          secrets.map do |secret_name, rule|
            { "source" => source_id, "repository" => repository_name, "secret" => secret_name, "rule" => rule }
          end
        end
      end
    end

    def plan_index
      @plan_index ||= build_plan_items.to_h do |item|
        [[item.source, item.repository, item.context, item.secret], item]
      end
    end

    def build_plan_items
      return @plan_items if @plan_items

      @plan_items = []
      @config.source_ids.each do |source_id|
        next unless @state.data.dig("sources", source_id)

        missing_contexts = InventoryCheck.missing_contexts(@config, @state, source_id)
        plan_contexts = missing_contexts.empty? ? [nil] : @config.contexts_for_source(source_id) - missing_contexts
        plan_contexts.each do |context|
          planner = Planner.new(
            @config,
            @state,
            @env_values,
            source_filter: source_id,
            context_filter: context
          )
          @plan_items.concat(planner.plan)
        end
      end
      @plan_items
    end

    def json_safe(value)
      case value
      when Hash
        value.to_h { |key, entry| [key.to_s, json_safe(entry)] }
      when Array
        value.map { |entry| json_safe(entry) }
      when Time
        value.utc.iso8601
      when Date
        value.iso8601
      else
        value
      end
    end
  end
end
