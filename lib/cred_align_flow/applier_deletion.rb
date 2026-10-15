# frozen_string_literal: true

module CredAlignFlow
  # Remote-secret deletion for Applier, reached only through `prune`'s
  # per-item confirmation — `apply` never calls this. Each delete
  # re-verifies repository/source identity and remote presence against
  # the live provider before removing, and clears the local records so
  # the applied journal cannot masquerade as a live application. No
  # secret value is ever needed — deletion must work when the env entry
  # is already gone.
  #
  # Expects the including class to provide @config/@state, provider_for,
  # repo_entry, remote_secret_entries, repository_identity_current?, and
  # outcome.
  module ApplierDeletion
    def delete_item(item)
      provider = provider_for(item.source)
      unless provider.deletable?(item.context)
        return outcome(item, "skipped", "#{item.source} cannot delete remote secrets in context #{item.context}")
      end

      entry = {
        item: item,
        provider: provider,
        repo_identity: @state.repo_identity(repo_entry(item)),
        source_identity: @config.source_key(item.source)
      }
      guard = []
      return guard.first unless repository_identity_current?(entry, guard, {})

      remote = remote_secret_entries(entry).find { |secret| secret["name"] == item.secret }
      if remote.nil?
        record_deletion(entry)
        return outcome(item, "applied", "remote secret was already absent; cleared the local record")
      end

      provider.delete_secret(item.repository, item.context, item.secret)
      record_deletion(entry)
      outcome(item, "applied", "remote secret deleted")
    rescue ProviderError => e
      outcome(item, "failed", e.message)
    rescue StateError => e
      outcome(item, "failed",
              "remote delete may have succeeded, but local metadata could not be updated: #{e.message}")
    end

    def record_deletion(entry)
      item = entry[:item]
      @state.transaction! do |state|
        current_repo = state.repository(item.source, item.repository)
        unless current_repo && state.repo_identity(current_repo) == entry[:repo_identity] &&
               state.source_identity(item.source) == entry[:source_identity]
          raise StateError, "local repository/source identity changed while the provider delete was in progress"
        end

        state.unmark_remote_secret(item.source, item.repository, item.context, item.secret)
        state.forget_application(item.source, current_repo, item.context, item.secret)
      end
    end
  end
end
