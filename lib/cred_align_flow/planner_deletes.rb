# frozen_string_literal: true

module CredAlignFlow
  # Delete-rule planning for Planner: a "delete" repository rule
  # suppresses the assignment and instead plans removal. Every context
  # where inventory still sees the remote secret gets a delete item, so
  # a mark cleans all copies of the name on that repository. The names
  # count as expected here — otherwise a pending deletion would
  # double-report as an unexpected remote. `apply` never executes these
  # items; `prune` walks them with per-item confirmation.
  #
  # Expects the including class to provide @config/@items, filters,
  # each_repository, secret_selected?, and item.
  module PlannerDeletes
    private

    def plan_deletes(source_id, expected_names)
      adapter = Providers.adapter_for(@config.source(source_id)["type"])
      each_repository(source_id) do |repo_name, repo|
        @config.secrets.each do |secret|
          name = secret.fetch("name")
          next unless secret_selected?(secret)
          next unless @config.secret_applies_to_source?(secret, source_id)
          next unless @config.secret_repository_rule(secret, source_id, repo_name) == "delete"

          repo.fetch("remote_secrets", {}).each do |context, remotes|
            next unless Selector.matches_filter?(@context_filter, context)
            next unless remotes.key?(name)

            expected_names[[source_id, repo_name, context]] << name
            @items << item(source_id, repo_name, context, name, "delete", delete_detail(adapter, context))
          end
        end
      end
    end

    def delete_detail(adapter, context)
      if adapter && !adapter.deletable?(context)
        return "marked for deletion, but the provider cannot delete secrets in this context"
      end

      "marked for deletion; `prune` removes the remote secret"
    end
  end
end
