# frozen_string_literal: true

require "time"
require_relative "timestamp"

module CredAlignFlow
  # Compares desired local material with the applied journal and observed
  # remote metadata:
  #
  #   desired   — the current env value (fingerprinted, never the value)
  #   applied   — the fingerprint/identity recorded after a successful push
  #   observed  — remote names and updated_at timestamps from inventory
  #
  # A changed value yields "update" even when version metadata is
  # unchanged, because the desired fingerprint no longer matches the
  # fingerprint recorded at the last successful apply.
  class Planner
    Item = Struct.new(:action, :source, :repository, :context, :secret, :detail, keyword_init: true) do
      def actionable?(force: false)
        case action
        when "create", "update"
          true
        when "unverified_present", "remote_newer"
          force
        else
          false
        end
      end
    end

    attr_reader :items

    def initialize(config, state, env_values, source_filter: nil, repo_filter: nil, secret_filter: nil, context_filter: nil)
      @config = config
      @state = state
      @env_values = env_values
      @source_filter = source_filter
      @repo_filter = repo_filter
      @secret_filter = secret_filter
      @context_filter = context_filter
      @items = nil
    end

    def plan
      return @items if @items

      expected_names = Hash.new { |hash, key| hash[key] = Set.new }
      @items = []

      @config.source_ids.each do |source_id|
        next unless Selector.matches_filter?(@source_filter, source_id)

        each_repository(source_id) do |repo_name, repo|
          @config.secrets.each do |secret|
            next unless secret_selected?(secret)
            next unless @config.secret_applies_to_source?(secret, source_id)

            visibility = repo["visibility"].to_s.downcase
            unless %w[public private internal].include?(visibility)
              raise ProviderError, "cannot determine visibility for repository #{repo_name}"
            end

            assignment, = @config.secret_assignment(secret, source_id, repo)
            next unless %w[assigned_default assigned_manual].include?(assignment)

            value_available = !@config.value_for(secret, @env_values).nil?
            @config.contexts_for(secret, source_id).each do |context|
              next if owner_scoped?(source_id, context)
              next unless Selector.matches_filter?(@context_filter, context)

              expected_names[[source_id, repo_name, context]] << secret.fetch("name")
              @items << item_for(source_id, repo_name, repo, context, secret, value_available)
            end
          end
        end

        plan_owner_scope(source_id)
        add_unexpected_items(source_id, expected_names) if @secret_filter.nil? && @context_filter.nil?
      end

      @items.sort_by! { |item| [item.source.to_s, item.repository.to_s, item.context.to_s, item.secret.to_s] }
      @items
    end

    def actionable_items(force: false)
      plan.select { |item| item.actionable?(force: force) }
    end

    def blocking_items(strict: false)
      plan.select do |item|
        %w[create update remote_newer unverified_present missing_value pull_only].include?(item.action) ||
          (strict && item.action == "unexpected")
      end
    end

    private

    def each_repository(source_id)
      repositories = @state.selected_repositories(source_id)
      repositories.each do |repo_name, repo|
        next if @repo_filter && !Selector.matches_any?([@repo_filter], repo)

        yield repo_name, repo
      end
    end

    def secret_selected?(secret)
      Selector.matches_filter?(@secret_filter, secret.fetch("name"))
    end

    def item_for(source_id, repo_name, repo, context, secret, value_available)
      name = secret.fetch("name")
      unless value_available
        return item(source_id, repo_name, context, name, "missing_value",
                    "#{@config.value_ref(secret)} is not set")
      end
      unless provider_writable?(source_id, context)
        return item(source_id, repo_name, context, name, "pull_only",
                    "provider is pull-only; remote writes are not possible")
      end

      remote = @state.remote_secret(source_id, repo_name, context, name)
      managed = @state.applied_record(source_id, repo, context, name)
      return item(source_id, repo_name, context, name, "create", "remote secret is missing") if remote.nil?

      if managed.nil?
        return item(source_id, repo_name, context, name, "unverified_present",
                    "remote secret exists but was not applied by this state file")
      end
      unless applied_identity_current?(managed, repo, source_id)
        return item(source_id, repo_name, context, name, "unverified_present",
                    "applied record belongs to a different repository or source identity; adopt with --force")
      end

      remote_time = Timestamp.parse(remote["updated_at"])
      if remote_time.nil?
        detail = remote["updated_at"].to_s.empty? ? "remote updated_at is missing" : "remote updated_at is invalid"
        return item(source_id, repo_name, context, name, "remote_newer", detail)
      end

      applied_time, baseline = applied_baseline(managed)
      if applied_time.nil?
        return item(source_id, repo_name, context, name, "remote_newer",
                    "applied record has no valid apply timestamp; remote ownership is unproven")
      end
      if remote_time > applied_time
        detail = "remote updated at #{remote['updated_at']}, after #{baseline} at #{applied_time.iso8601}"
        return item(source_id, repo_name, context, name, "remote_newer", detail)
      end

      fingerprint_action(source_id, repo_name, context, secret, managed, applied_time)
    end

    # `applied_remote_at` is the provider's own post-write timestamp, in the
    # same clock domain as remote `updated_at`; comparing those two is
    # immune to local clock skew. Records without it fall back to the
    # local `applied_at`, which is still safe but skew-limited.
    def applied_baseline(managed)
      remote_stamp = managed["applied_remote_at"].to_s
      unless remote_stamp.empty?
        confirmed = Timestamp.parse(remote_stamp)
        return [nil, nil] unless confirmed

        return [confirmed, "the provider-confirmed apply"]
      end
      [Timestamp.parse(managed["applied_at"]), "the last recorded apply"]
    end

    # The applied fingerprint is authoritative when present: it is the
    # keyed fingerprint of the exact value the provider received. Version
    # metadata is only a fallback for records written before fingerprints.
    def fingerprint_action(source_id, repo_name, context, secret, managed, applied_time)
      name = secret.fetch("name")
      desired = @config.desired_fingerprint(secret, @env_values)
      applied = managed["fingerprint"]
      if applied
        if applied != desired
          return item(source_id, repo_name, context, name, "update",
                      "applied value differs from the current local value")
        end

        return item(source_id, repo_name, context, name, "ok",
                    "applied fingerprint matches the desired value")
      end

      configured_version = @config.secret_version(secret)
      configured_time = @config.secret_version_time(secret)
      if managed["version"].to_s != configured_version || (configured_time && configured_time > applied_time)
        return item(source_id, repo_name, context, name, "update",
                    "configured version #{configured_version} has not been applied")
      end

      item(source_id, repo_name, context, name, "ok",
           "managed metadata is current (no applied fingerprint recorded)")
    end

    def applied_identity_current?(managed, repo, source_id)
      recorded_id = managed["repo_id"].to_s
      current_id = repo.is_a?(Hash) ? repo["id"].to_s : ""
      return false unless recorded_id.empty? == current_id.empty?
      return false if !recorded_id.empty? && recorded_id != current_id

      managed["source_identity"] == @config.source_key(source_id)
    end

    # Owner-scope stores cannot be listed, so items for them are emitted
    # once per source under the synthetic OWNER_SCOPE_REPOSITORY key and
    # decided against the applied journal alone — remote existence,
    # timestamps, and drift are unknowable by design.
    def plan_owner_scope(source_id)
      # --repo narrows intent to repository targets; an account-scope
      # write affects every repository, so it is excluded then.
      return if @repo_filter

      @config.secrets.each do |secret|
        next unless secret_selected?(secret)
        next unless @config.secret_applies_to_source?(secret, source_id)

        @config.contexts_for(secret, source_id).each do |context|
          next unless Selector.matches_filter?(@context_filter, context)
          next unless owner_scoped?(source_id, context)

          @items << owner_item_for(source_id, context, secret)
        end
      end
    end

    def owner_item_for(source_id, context, secret)
      name = secret.fetch("name")
      repo = Provider::OWNER_SCOPE_REPOSITORY
      unless @config.value_for(secret, @env_values)
        return item(source_id, repo, context, name, "missing_value", "#{@config.value_ref(secret)} is not set")
      end
      unless @state.source_identity(source_id)
        return item(source_id, repo, context, name, "not_checked",
                    "no inventory snapshot for this source; refresh first")
      end
      unless provider_writable?(source_id, context)
        return item(source_id, repo, context, name, "pull_only",
                    "owner-scope writes are not enabled for this source")
      end

      managed = @state.applied_record(source_id, repo, context, name)
      unless managed && applied_identity_current?(managed, repo, source_id)
        return item(source_id, repo, context, name, "create",
                    "owner-scope secrets cannot be listed; the write creates or overwrites blindly")
      end

      applied = managed["fingerprint"]
      desired = @config.desired_fingerprint(secret, @env_values)
      if applied && applied == desired
        return item(source_id, repo, context, name, "ok",
                    "applied fingerprint matches the desired value; remote state is not enumerable")
      end

      item(source_id, repo, context, name, "update",
           "desired value differs from the recorded apply; remote state is not enumerable")
    end

    def owner_scoped?(source_id, context)
      adapter = Providers.adapter_for(@config.source(source_id)["type"])
      adapter&.owner_scoped_context?(context)
    end

    def provider_writable?(source_id, context)
      source = @config.source(source_id)
      adapter = Providers.adapter_for(source["type"])
      return true if adapter.nil?
      return adapter.owner_scope_writable?(source) if adapter.owner_scoped_context?(context)

      adapter::WRITABLE
    end

    def add_unexpected_items(source_id, expected_names)
      each_repository(source_id) do |repo_name, repo|
        repo.fetch("remote_secrets", {}).each do |context, remote_secrets|
          remote_secrets.each_key do |secret_name|
            next if expected_names[[source_id, repo_name, context]].include?(secret_name)

            @items << item(
              source_id,
              repo_name,
              context,
              secret_name,
              "unexpected",
              "remote secret is outside the configured target scope"
            )
          end
        end
      end
    end

    def item(source_id, repo_name, context, secret, action, detail)
      Item.new(
        action: action,
        source: source_id,
        repository: repo_name,
        context: context,
        secret: secret,
        detail: detail
      )
    end
  end
end
