# frozen_string_literal: true

require "time"

module CredAlignFlow
  # Pulls repository + remote-secret metadata from providers and commits
  # the result atomically. Provider calls happen before the state lock is
  # taken, so a slow provider never holds the lock; the read-modify-write
  # runs inside `transaction!` so concurrent writers merge instead of
  # clobbering each other's applied journal or other sources.
  class Inventory
    def initialize(config, state, env_values, providers: {})
      @config = config
      @state = state
      @env_values = env_values
      @providers = providers
    end

    def refresh!(source_filter: nil, context_filter: nil)
      refreshed_source_ids = []

      @config.source_ids.each do |source_id|
        next unless Selector.matches_filter?(source_filter, source_id)

        collect_source(source_id, context_filter: context_filter)
        refreshed_source_ids << source_id
      end

      refreshed_source_ids
    end

    private

    def collect_source(source_id, context_filter:)
      provider = provider_for(source_id)
      assert_valid_contexts(provider, source_id)

      repositories_config = @config.repositories_config(source_id)
      include_names = expand_include_names(repositories_config["include"], source_id)
      # Owner-scope stores are not enumerable, so they are never pulled;
      # they are planned blindly instead of contributing remote metadata.
      contexts = @config.contexts_for_source(source_id).reject do |context|
        provider.owner_scoped_context?(context)
      end
      refreshed = context_filter ? contexts.select { |context| Selector.matches_filter?(context_filter, context) } : contexts
      if context_filter && refreshed.empty? && !contexts.empty?
        raise ProviderError,
              "#{source_id}: context filter matched only non-enumerable owner-scope stores; nothing to pull"
      end

      # Build the replacement repository map entirely from provider data
      # before touching the state lock.
      entries = build_entries(provider, source_id, repositories_config, include_names)

      selected_names = entries.select { |_, repo| repo["selected"] }.keys
      secrets_by_repo = fetch_remote_secrets(provider, source_id, selected_names, refreshed, entries)
      truncated = provider.respond_to?(:truncated?) && provider.truncated?
      # The stored selection fingerprint lets InventoryCheck detect when
      # selection rules or the source identity changed after this snapshot.
      selection = InventoryCheck.selection_fingerprint(@config, source_id)
      refreshed_contexts = context_filter ? refreshed : nil

      @state.transaction! do
        merge_and_commit(source_id, entries, secrets_by_repo, refreshed_contexts, selection, truncated)
      end
    end

    def build_entries(provider, source_id, repositories_config, include_names)
      discovered =
        if Selector.discover?(repositories_config)
          provider.repositories
        else
          include_names.map { |name| fetch_repository_metadata(provider, source_id, name) }
        end

      entries = {}
      discovered.each do |repo|
        name = repo_name(repo)
        next if name.empty?

        entries[name] = repo.merge(
          "nameWithOwner" => name,
          "selected" => Selector.repository_selected?(repo, repositories_config),
          "explicit" => false
        )
      end
      include_names.each do |name|
        base = entries[name] ||
               fetch_repository_metadata(provider, source_id, name)
               .merge("nameWithOwner" => name)
        entries[name] = base.merge(
          "selected" => Selector.repository_selected?(base.merge("explicit" => true), repositories_config),
          "explicit" => true
        )
      end
      entries
    end

    # Inside the lock: merge anything the fresh pull did not cover (repos a
    # context filter never re-checked, include-targeted repos the provider
    # can no longer see) so a refresh never silently unplans them, then
    # replace the source snapshot atomically.
    def merge_and_commit(source_id, entries, secrets_by_repo, refreshed_contexts, selection, truncated)
      existing = @state.repositories(source_id)

      entries.each do |name, entry|
        prior = existing[name] || {}
        remote_secrets = prior["remote_secrets"] || {}
        secrets_by_repo.fetch(name, {}).each do |context, secrets|
          remote_secrets = remote_secrets.merge(context => secrets)
        end
        # Remote metadata for contexts this refresh did not touch stays as
        # it was; it is reported as not_refreshed downstream.
        entry["remote_secrets"] = remote_secrets
        entry["name_with_owner"] = name
        entry["admin"] = entry["viewerCanAdminister"] == true
      end

      existing.each do |name, prior|
        next if entries.key?(name)
        next unless prior["explicit"] == true || prior["selected"] == true

        # A previously selected repository the provider no longer reports
        # is preserved and marked stale rather than silently dropped:
        # applied records stay attributable and the planner/UI can show
        # that the inventory is incomplete instead of losing history.
        preserved = prior.merge("selected" => false, "stale" => true)
        entries[name] = preserved
      end

      @state.apply_refresh(
        source_id,
        repositories: entries,
        contexts: refreshed_contexts,
        selection: selection,
        discovered_at: Time.now.utc.iso8601,
        truncated: truncated
      )
    end

    # Unknown repository visibility fails closed before a single secret
    # list call: an undeterminable repo can never be safely scoped.
    def fetch_remote_secrets(provider, source_id, selected_names, contexts, entries)
      return {} if contexts.empty?

      secrets_by_repo = {}
      selected_names.each do |repo_name|
        visibility = entries.dig(repo_name, "visibility").to_s.downcase
        unless %w[public private internal].include?(visibility)
          raise ProviderError, "#{source_id}: cannot determine visibility for repository #{repo_name}"
        end

        contexts.each do |context|
          provider.validate_context!(context)
          secrets = provider.secrets(repo_name, context)
          (secrets_by_repo[repo_name] ||= {})[context] = secrets.to_h do |secret|
            [secret.fetch("name"), { "updated_at" => secret["updatedAt"] || secret["updated_at"] }]
          end
        end
      end
      secrets_by_repo
    end

    def fetch_repository_metadata(provider, source_id, name)
      repo = provider.repository(name)
      raise ProviderError, "#{source_id}: repository #{name} was not found" unless repo
      unless repo["viewerCanAdminister"] == true
        raise ProviderError, "#{source_id}: no admin permission on explicitly included repository #{name}"
      end

      repo
    end

    def assert_valid_contexts(provider, source_id)
      contexts = provider.respond_to?(:contexts) ? provider.contexts : []
      wanted = @config.contexts_for_source(source_id)
      unknown = wanted - contexts
      return if unknown.empty?

      raise ProviderError, "#{source_id}: unsupported context(s) #{unknown.join(', ')}"
    end

    def provider_for(source_id)
      @providers[source_id] ||= Providers.build(@config.source(source_id), @env_values)
    end

    def expand_include_names(include_names, source_id)
      include_names.each do |pattern|
        next unless pattern.match?(/[\[\]{}*?!]/)

        raise ConfigError, "repository include entries must be exact names when discovery is used: #{pattern}"
      end
      include_names.map { |name| qualified_name(source_id, name) }
    end

    def qualified_name(source_id, name)
      return name if name.include?("/")

      owner = @config.source(source_id)["owner"].to_s
      owner.empty? ? name : "#{owner}/#{name}"
    end

    def repo_name(repo)
      (repo["nameWithOwner"] || repo["name_with_owner"] || repo["name"]).to_s
    end
  end
end
