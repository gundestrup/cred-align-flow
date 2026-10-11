# frozen_string_literal: true

require "time"

module CredAlignFlow
  # Executes a reviewed plan item set. Every item is preflighted (secret
  # known, value present, provider writable, value within provider limits)
  # before the first remote write, so a blocked item never aborts a batch
  # after earlier writes landed. "create" items are re-checked against the
  # provider at write time because `gh secret set` also overwrites existing
  # secrets. Results are structured outcomes: applied / skipped / failed.
  class Applier
    Outcome = Struct.new(:item, :status, :detail, keyword_init: true)

    def initialize(config, state, env_values, providers: {})
      @config = config
      @state = state
      @env_values = env_values
      @providers = providers
    end

    def apply(items, force: false)
      prepared = prepare(items, force)
      outcomes = prepared[:blocked]
      return outcomes if prepared[:ready].empty?

      repository_metadata = {}
      prepared[:ready].each do |entry|
        write_item(entry, outcomes, repository_metadata, force)
      end
      outcomes
    end

    def write_item(entry, outcomes, repository_metadata, force)
      remote_written = false
      item = entry[:item]
      return unless repository_identity_current?(entry, outcomes, repository_metadata)

      remotes = remote_secret_entries(entry)
      remote = remotes.find { |secret| secret["name"] == item.secret }
      blocker = remote_write_blocker(entry, remotes, remote, force)
      return outcomes << blocker if blocker

      entry[:provider].set_secret(item.repository, item.context, item.secret, entry[:value])
      remote_written = true
      applied_remote_at = confirmed_remote_timestamp(entry)
      record_application(entry, applied_remote_at)
      detail = "secret written"
      detail += "; provider timestamp unavailable — drift baseline uses the local clock" unless applied_remote_at
      outcomes << outcome(item, "applied", detail)
    rescue ProviderError => e
      outcomes << outcome(item, "failed", e.message)
    rescue StateError => e
      detail = if remote_written
                 "remote write succeeded, but local application metadata could not be saved; refresh inventory before retrying"
               else
                 e.message
               end
      outcomes << outcome(item, "failed", detail)
    end

    # Re-reads the provider right after a write so the applied record
    # stores the remote `updated_at` the provider itself assigned. Local
    # clock comparisons can hide remote drift under clock skew; a
    # provider-side timestamp cannot. A missing timestamp degrades to the
    # local baseline rather than failing the write.
    def confirmed_remote_timestamp(entry)
      item = entry[:item]
      remote = remote_secret_entries(entry).find { |secret| secret["name"] == item.secret }
      timestamp(remote && (remote["updated_at"] || remote["updatedAt"]))
    rescue ProviderError
      nil
    end

    def remote_secret_entries(entry)
      item = entry[:item]
      secrets = entry[:provider].secrets(item.repository, item.context)
      secrets.select { |secret| secret.is_a?(Hash) && secret["name"].is_a?(String) }
    end

    def remote_write_blocker(entry, remotes, remote, force)
      item = entry[:item]
      if item.action == "create"
        return outcome(item, "skipped", "remote secret appeared after the plan was made") if remote

        limit = secret_count_limit(entry[:provider])
        if limit && remotes.length >= limit
          message = "repository already has the #{limit}-secret provider limit"
          return outcome(item, "skipped", message)
        end
      elsif !remote
        return outcome(item, "skipped", "remote secret disappeared after the plan was made; refresh the plan")
      elsif !force && remote_changed_since_apply?(remote, entry[:applied_record])
        return outcome(item, "skipped", "remote secret changed after the plan; refresh and review before applying")
      end
      nil
    end

    def record_application(entry, applied_remote_at)
      item = entry[:item]
      @state.transaction! do |state|
        current_repo = state.repository(item.source, item.repository)
        unless current_repo && state.repo_identity(current_repo) == entry[:repo_identity] &&
               state.source_identity(item.source) == entry[:source_identity]
          raise StateError, "local repository/source identity changed while the provider write was in progress"
        end

        if applied_remote_at
          state.mark_remote_secret(item.source, item.repository, item.context, item.secret,
                                   applied_remote_at.utc.iso8601)
        else
          state.mark_remote_secret(item.source, item.repository, item.context, item.secret)
        end
        state.record_application(
          item.source, current_repo, item.context, item.secret,
          @config.secret_version(entry[:secret]), @config.secret_version_time(entry[:secret]),
          fingerprint: entry[:fingerprint], source_identity: entry[:source_identity],
          applied_remote_at: applied_remote_at
        )
      end
    end

    def repository_identity_current?(entry, outcomes, repository_metadata)
      item = entry[:item]
      key = [item.source, item.repository]
      repository_metadata[key] = entry[:provider].repository(item.repository) unless repository_metadata.key?(key)
      current_repo = repository_metadata[key]
      identity_matches = @state.source_identity(item.source) == entry[:source_identity] && current_repo &&
                         current_repo["viewerCanAdminister"] == true &&
                         @state.repo_identity(current_repo) == entry[:repo_identity]
      unless identity_matches
        outcomes << outcome(
          item, "skipped", "repository identity or admin permission changed; refresh inventory and review the plan"
        )
        return false
      end

      true
    rescue ProviderError => e
      outcomes << outcome(item, "failed", e.message)
      false
    end

    private

    def prepare(items, force)
      ready = []
      blocked = []
      items.each do |item|
        entry = prepare_item(item, force)
        entry.is_a?(Outcome) ? blocked << entry : ready << entry
      end
      apply_secret_count_limits!(ready, blocked)
      { ready: ready, blocked: blocked }
    end

    def apply_secret_count_limits!(ready, blocked)
      creations = ready.select { |entry| entry[:item].action == "create" }
                       .group_by do |entry|
        item = entry[:item]
        [item.source, item.repository, item.context]
      end
      creations.each_value do |entries|
        limit = secret_count_limit(entries.first[:provider])
        next unless limit

        item = entries.first[:item]
        existing = @state.data.dig("sources", item.source, "repositories", item.repository,
                                   "remote_secrets", item.context)
        existing = {} unless existing.is_a?(Hash)
        next unless existing.length + entries.map { |entry| entry[:item].secret }.uniq.length > limit

        entries.each do |entry|
          ready.delete(entry)
          blocked << outcome(entry[:item], "skipped", "repository secret count would exceed the #{limit}-secret provider limit")
        end
      end
    end

    # Returns a ready entry, or an Outcome describing why the item is
    # blocked. All checks run before the first remote write.
    def prepare_item(item, force)
      return outcome(item, "skipped", "#{item.action} requires --force or is not actionable") unless apply_item?(item, force)

      provider = provider_for(item.source)
      return outcome(item, "skipped", "#{item.source} is pull-only; remote writes are disabled") unless provider.writable?

      secret = @config.secrets.find { |entry| entry.fetch("name") == item.secret }
      return outcome(item, "skipped", "unknown secret in plan") unless secret

      value = @config.value_for(secret, @env_values)
      return outcome(item, "skipped", "missing value for #{item.secret} (#{@config.value_ref(secret)})") unless value

      limit = provider_limit(provider)
      return outcome(item, "skipped", "value exceeds the #{limit}-byte provider limit") if limit && value.bytesize > limit

      repo = repo_entry(item)
      {
        item: item,
        secret: secret,
        value: value,
        provider: provider,
        fingerprint: Fingerprint.digest(item.secret, value),
        applied_record: @state.applied_record(item.source, repo, item.context, item.secret),
        repo: repo,
        repo_identity: @state.repo_identity(repo),
        source_identity: @config.source_key(item.source)
      }
    end

    # Prefers the provider-side apply timestamp: it shares the remote
    # clock's domain, so local clock skew cannot mask a remote change.
    def remote_changed_since_apply?(remote, applied_record)
      return true unless applied_record.is_a?(Hash)

      remote_time = timestamp(remote["updatedAt"] || remote["updated_at"])
      applied_time = timestamp(applied_record["applied_remote_at"]) || timestamp(applied_record["applied_at"])
      remote_time.nil? || applied_time.nil? || remote_time > applied_time
    end

    def timestamp(value)
      return nil if value.to_s.empty?

      Time.iso8601(value.to_s).utc
    rescue ArgumentError
      nil
    end

    def secret_count_limit(provider)
      provider.class.const_defined?(:MAX_REPOSITORY_SECRETS) ? provider.class::MAX_REPOSITORY_SECRETS : nil
    end

    def repo_entry(item)
      @state.data.dig("sources", item.source, "repositories", item.repository) || item.repository
    end

    def provider_limit(provider)
      provider.class.const_defined?(:MAX_SECRET_VALUE_BYTES) ? provider.class::MAX_SECRET_VALUE_BYTES : nil
    end

    def apply_item?(item, force)
      case item.action
      when "create", "update"
        true
      when "unverified_present", "remote_newer"
        force
      else
        false
      end
    end

    def outcome(item, status, detail)
      Outcome.new(item: item, status: status, detail: detail)
    end

    def provider_for(source_id)
      @providers[source_id] ||= Providers.build(@config.source(source_id), @env_values)
    end
  end
end
