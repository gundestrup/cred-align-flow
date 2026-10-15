# frozen_string_literal: true

module CredAlignFlow
  # Repository-row assembly for ConfigView: per-repository assignment
  # rows with per-context plan status, plus the not-assigned and
  # unexpected buckets. Expects the including class to provide
  # @config/@state/@env_values, plan_index, and build_plan_items.
  module ConfigViewRepositories
    private

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
      contexts = enumerable_contexts(secret, source_id)
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
        return row.merge("not_assigned" => not_assigned(secret, "excluded_default",
                                                        no_repo_context_detail(secret, source_id)))
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
      return "delete" if assignment == "deleted_manual"
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

    # Owner-scope contexts are account-level and never enumerable, so
    # they are excluded from per-repository rows and surfaced only in the
    # plan and the token's target selection.
    def enumerable_contexts(secret, source_id)
      type = @config.source(source_id)["type"]
      @config.contexts_for(secret, source_id).reject do |context|
        Providers.owner_scoped_context?(type, context)
      end
    end

    def no_repo_context_detail(secret, source_id)
      return "targeted only at the account scope, not repositories" unless @config.contexts_for(secret, source_id).empty?

      "no target context is enabled for this provider"
    end

    def unexpected_items(source_id, repository_name)
      build_plan_items.filter_map do |item|
        next unless item.source == source_id && item.repository == repository_name && item.action == "unexpected"

        { "name" => item.secret, "context" => item.context, "detail" => item.detail }
      end
    end
  end
end
