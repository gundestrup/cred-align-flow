# frozen_string_literal: true

module CredAlignFlow
  # Builds the read-only view model for the config UI. Secret values and
  # value fingerprints are never included — only availability and digest
  # status. Rule provenance is reported separately from the effective rule
  # so the page can distinguish "delete a JSON override" from "write an
  # explicit default that cancels YAML intent".
  class ConfigView
    def initialize(config:, state:, env_values:, revision:, display_revision: revision, scaffolder: nil)
      @config = config
      @state = state
      @env_values = env_values
      @revision = revision
      @display_revision = display_revision
      @scaffolder = scaffolder
    end

    def to_h
      {
        "config_file" => File.basename(@config.path),
        "rules_file" => File.basename(@config.rules_file),
        "revision" => @revision,
        "display_revision" => @display_revision,
        "generated_at" => @state.data["generated_at"],
        "check_for_updates" => @config.check_for_updates?,
        "provider_contexts" => provider_contexts,
        "secrets" => secret_entries,
        "sources" => source_entries,
        "rules" => @config.rules.entries,
        "orphan_rules" => orphan_rules,
        "unimported_env_names" => unimported_env_names,
        "ignored_env_names" => @config.ignored_env_names,
        "action_summary" => action_summary,
        "meta" => UiMetadata.to_h
      }
    end

    private

    def provider_contexts
      types = @config.source_ids.map { |source_id| @config.source(source_id).fetch("type") }.uniq
      types.to_h do |type|
        [type, Providers.adapter_for(type)::CONTEXTS]
      end
    end

    def secret_entries
      @config.secrets.map do |secret|
        {
          "config" => json_safe(secret).except("value_digest"),
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

    def legacy_exclusion?(explicit_rule, secret, source_id, repository)
      explicit_rule.nil? && Selector.matches_any?(@config.secret_exclusions(secret, source_id), repository)
    end

    def manual_include_crosses_scope?(explicit_rule, secret, source_id, repository)
      return false unless explicit_rule == "include"

      !@config.secret_source_selected_by_default?(secret, source_id) ||
        !Selector.visibility_matches?(repository, @config.secret_visibility(secret)) ||
        Selector.matches_any?(@config.secret_exclusions(secret, source_id), repository)
    end

    def repository_rule_entry(secret, source_id, name, repository, node, missing_contexts)
      provenance = @config.repository_rule_provenance(secret, source_id, name)
      explicit_rule = @config.secret_repository_rule(secret, source_id, name)
      legacy_exclusion = legacy_exclusion?(explicit_rule, secret, source_id, repository)
      assignment, reason = @config.secret_assignment(secret, source_id, repository)
      contexts = @config.contexts_for(secret, source_id)
      source_locked = Array(secret["exclude_sources"]).map(&:to_s).include?(source_id)
      crosses_scope = manual_include_crosses_scope?(explicit_rule, secret, source_id, repository)
      row = {
        "secret_name" => secret.fetch("name"),
        "rule_mode" => explicit_rule || (legacy_exclusion ? "exclude" : "default"),
        "rule_source" => provenance || (legacy_exclusion ? "exclusion" : nil),
        "legacy_exclusion" => legacy_exclusion,
        "source_locked" => source_locked,
        "crosses_scope" => crosses_scope
      }
      unless node && repository["selected"] == true
        detail = "source filters exclude this repository"
        return row.merge("not_assigned" => not_assigned(secret, "excluded_source", detail))
      end
      return row.merge("not_assigned" => not_assigned(secret, assignment, reason)) unless assignment.start_with?("assigned_")

      if contexts.empty?
        detail = "no target context is enabled for this provider"
        return row.merge("not_assigned" => not_assigned(secret, "excluded_default", detail))
      end

      row.merge("assigned" => assigned_secret(secret, assignment, source_id, name, repository, contexts, missing_contexts))
    end

    def not_assigned(secret, assignment, reason, detail = nil)
      {
        "name" => secret.fetch("name"),
        "category" => assignment_category(assignment),
        "reason" => detail || reason,
        "rule" => assignment
      }
    end

    def assignment_category(assignment)
      return "manual" if assignment == "excluded_manual"
      return "source" if assignment == "excluded_source"

      "default"
    end

    def assigned_secret(secret, assignment, source_id, repository_name, repository, contexts, missing_contexts)
      {
        "name" => secret.fetch("name"),
        "origin" => assignment == "assigned_manual" ? "manual" : "default",
        "contexts" => contexts.map do |context|
          status = if missing_contexts.include?(context)
                     { "action" => "not_refreshed", "detail" => "inventory does not cover this context" }
                   else
                     planned_status(source_id, repository_name, repository, context, secret.fetch("name"))
                   end
          { "name" => context, **status }
        end
      }
    end

    def planned_status(source_id, repository_name, repository, context, secret_name)
      item = plan_index[[source_id, repository_name, context, secret_name]]
      status = if item
                 { "action" => item.action, "detail" => item.detail }
               else
                 { "action" => "not_checked", "detail" => "no inventory is available" }
               end
      remote = @state.remote_secret(source_id, repository_name, context, secret_name)
      applied = @state.applied_record(source_id, repository, context, secret_name)
      status["remote_updated_at"] = remote["updated_at"] if remote
      status["applied_at"] = applied["applied_at"] if applied
      status
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

    def unexpected_items(source_id, repository_name)
      build_plan_items.filter_map do |item|
        next unless item.source == source_id && item.repository == repository_name && item.action == "unexpected"

        { "name" => item.secret, "context" => item.context, "detail" => item.detail }
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
