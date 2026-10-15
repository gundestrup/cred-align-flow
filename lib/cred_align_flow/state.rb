# frozen_string_literal: true

require "json"
require "time"

module CredAlignFlow
  # Local inventory + applied-secret journal.
  #
  # "applied" records bind a write to the material actually sent:
  # source_id + stable repository identity + context + secret name →
  # version, applied_at, and the keyed fingerprint of the pushed value.
  # Repository names are display metadata; a replacement repository at the
  # same name never inherits an applied record for a different stable id.
  #
  # Use `transaction!` for read-modify-write cycles — it reloads under a
  # sibling lockfile so concurrent CLI/UI writers merge instead of losing
  # each other's updates. `save!` persists atomically.
  class State
    attr_reader :path, :data

    def initialize(path)
      @path = File.expand_path(path)
      @data = read_existing || empty_state
      normalize!
      @version_token = file_token
    end

    # Lock, reload, mutate, persist — the mutation block runs under the
    # lockfile and the resulting state is written atomically before the
    # lock is released. Unsaved in-memory data from before the transaction
    # is discarded (the file is authoritative).
    def transaction!
      AtomicFile.with_lock(@path) do
        @data = read_existing || empty_state
        normalize!
        @version_token = file_token
        yield self
        save!
      end
    end

    # Replaces one source's repository snapshot after a provider pull.
    # Other sources and the applied journal are untouched.
    def apply_refresh(source_id, repositories:, contexts:, selection:, discovered_at:, truncated: false)
      node = source_node(source_id)
      node["repositories"] = repositories
      node["discovered_at"] = discovered_at
      node["identity"] = selection["identity"]
      node["selection"] = selection
      node["truncated"] = truncated
      contexts.nil? ? node.delete("refreshed_contexts") : node["refreshed_contexts"] = contexts
    end

    def selected_repositories(source_id)
      source_repositories(source_id).select { |_name, repo| repo["selected"] }
    end

    def refreshed_contexts(source_id)
      @data.dig("sources", source_id, "refreshed_contexts")
    end

    def source_identity(source_id)
      @data.dig("sources", source_id, "identity")
    end

    def repositories(source_id)
      source_repositories(source_id)
    end

    def repository(source_id, repo_name)
      source_repositories(source_id)[repo_name]
    end

    def remote_secret(source_id, repo_name, context, secret_name)
      source_repositories(source_id).dig(repo_name, "remote_secrets", context, secret_name)
    end

    def mark_remote_secret(source_id, repo_name, context, secret_name, updated_at = Time.now.utc.iso8601)
      repository_node(source_id, repo_name)["remote_secrets"][context] ||= {}
      repository_node(source_id, repo_name)["remote_secrets"][context][secret_name] = {
        "updated_at" => updated_at
      }
    end

    # `repo` is the inventory repository hash (for its stable id) or a bare
    # name when no inventory metadata exists. Records written before stable
    # ids/identities were captured ("legacy" name-keyed entries) only apply
    # to repositories that still have no stable id.
    def applied_record(source_id, repo, context, secret_name)
      identity = repo_identity(repo)
      record = @data["applied"][application_key(source_id, identity, context, secret_name)]
      return record if record
      return nil unless identity.start_with?("name:")

      @data["applied"]["#{source_id}|#{identity.delete_prefix('name:')}|#{context}|#{secret_name}"]
    end

    def unmark_remote_secret(source_id, repo_name, context, secret_name)
      source_repositories(source_id).dig(repo_name, "remote_secrets", context)&.delete(secret_name)
    end

    # Drops the applied journal entry for a secret — used after a remote
    # delete so the record cannot masquerade as a live application. The
    # same legacy-name fallback applied_record consults is cleaned too.
    def forget_application(source_id, repo, context, secret_name)
      identity = repo_identity(repo)
      @data["applied"].delete(application_key(source_id, identity, context, secret_name))
      return unless identity.start_with?("name:")

      @data["applied"].delete("#{source_id}|#{identity.delete_prefix('name:')}|#{context}|#{secret_name}")
    end

    # `applied_remote_at` is the provider's own `updated_at` observed right
    # after the write — drift checks compare remote timestamps against it,
    # so local clock skew cannot hide an external remote change. Records
    # without it (legacy writes) fall back to local `applied_at`.
    def record_application(source_id, repo, context, secret_name, version, version_at = nil,
                           fingerprint: nil, source_identity: nil, applied_remote_at: nil, at: Time.now.utc)
      record = {
        "version" => version,
        "applied_at" => at.utc.iso8601,
        "repository" => repo_name(repo),
        "repo_id" => repo_id(repo),
        "context" => context
      }
      record["version_at"] = version_at.utc.iso8601 if version_at
      record["fingerprint"] = fingerprint if fingerprint
      record["source_identity"] = source_identity if source_identity
      record["applied_remote_at"] = applied_remote_at.utc.iso8601 if applied_remote_at
      @data["applied"][application_key(source_id, repo_identity(repo), context, secret_name)] = record
    end

    # Refuses to overwrite a file that changed since this instance last
    # read or wrote it — a stale snapshot must go through transaction! so
    # changes merge instead of silently reverting newer state.
    def save!
      current = file_token
      if current != @version_token
        raise StateError,
              "state file #{@path} changed since it was read; " \
              "reload with transaction! instead of overwriting newer state"
      end

      @data["generated_at"] = Time.now.utc.iso8601
      AtomicFile.write(@path, "#{JSON.pretty_generate(@data)}\n")
      @version_token = file_token
    end

    def repo_identity(repo)
      return "name:#{repo}" unless repo.is_a?(Hash)

      id = repo_id(repo)
      return "id:#{id}" unless id.empty?

      "name:#{repo_name(repo)}"
    end

    private

    def repo_id(repo)
      return "" unless repo.is_a?(Hash)

      (repo["id"] || repo["repo_id"]).to_s
    end

    def repo_name(repo)
      return repo.to_s unless repo.is_a?(Hash)

      (repo["name_with_owner"] || repo["nameWithOwner"] || repo["repository"] || repo["name"]).to_s
    end

    def normalize!
      @data["sources"] ||= {}
      @data["applied"] ||= {}
    end

    def read_existing
      return nil unless File.exist?(@path)

      parsed = JSON.parse(File.read(@path))
      raise StateError, "State file must contain a JSON object: #{@path}" unless parsed.is_a?(Hash)

      parsed
    rescue JSON::ParserError => e
      raise StateError, "Invalid state file #{@path}: #{e.message}"
    end

    def empty_state
      {
        "version" => 1,
        "generated_at" => nil,
        "sources" => {},
        "applied" => {}
      }
    end

    def file_token
      return nil unless File.exist?(@path)

      stat = File.stat(@path)
      "#{stat.ino}:#{stat.mtime.to_f}:#{stat.size}"
    end

    def source_node(source_id)
      @data["sources"][source_id] ||= { "discovered_at" => nil, "repositories" => {} }
    end

    def source_repositories(source_id)
      @data.dig("sources", source_id, "repositories") || {}
    end

    def repository_node(source_id, repo_name)
      source_node(source_id)["repositories"][repo_name] ||= { "remote_secrets" => {} }
    end

    def application_key(source_id, identity, context, secret_name)
      [source_id, identity, context, secret_name].join("|")
    end
  end
end
