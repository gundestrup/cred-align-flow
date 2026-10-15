# frozen_string_literal: true

require "time"

module CredAlignFlow
  # Single inventory-validity model shared by the CLI offline checks and
  # the UI. A snapshot is only "current" when the source identity, the
  # repository selection settings, and the required context coverage all
  # match the present configuration.
  module InventoryCheck
    MAX_AGE_SECONDS = 24 * 60 * 60
    CLOCK_SKEW_SECONDS = 300

    module_function

    def source_status(config, state, source_id)
      node = state.data.dig("sources", source_id)
      return status("missing", "no inventory has been recorded for this source") unless node

      missing = missing_contexts(config, state, source_id)
      reasons = stale_reasons(config, state, source_id, node)
      return status("stale", *reasons, missing_contexts: missing) unless reasons.empty?
      unless missing.empty?
        return status("partial", "provider contexts not refreshed: #{missing.join(', ')}",
                      missing_contexts: missing)
      end

      status("current")
    end

    def missing_contexts(config, state, source_id)
      # Owner-scope contexts are write-only and never pulled, so they can
      # never be missing from a refresh — only enumerable contexts count.
      type = config.source(source_id)["type"]
      needed = config.contexts_for_source(source_id).reject do |context|
        Providers.owner_scoped_context?(type, context)
      end
      node = state.data.dig("sources", source_id)
      return needed unless node

      marked = state.refreshed_contexts(source_id)
      repositories = node.fetch("repositories", {}).values.select { |repo| repo["selected"] == true }
      needed.select do |context|
        (marked && !marked.include?(context)) ||
          repositories.any? { |repo| !repo.fetch("remote_secrets", {}).key?(context) }
      end
    end

    def stale_reasons(config, state, source_id, node = nil)
      node ||= state.data.dig("sources", source_id)
      reasons = []
      identity = state.source_identity(source_id)
      if identity.nil? || identity.empty?
        reasons << "source identity was not recorded for this snapshot"
      elsif identity != config.source_key(source_id)
        reasons << "the source endpoint or account changed since this snapshot"
      end
      selection = node && node["selection"]
      if selection.nil?
        reasons << "repository selection settings were not recorded for this snapshot"
      elsif selection != selection_fingerprint(config, source_id)
        reasons << "repository selection settings changed since this snapshot"
      end
      reasons.concat(discovery_age_reasons(node))
      reasons << "repository discovery may be truncated at the provider limit" if node && node["truncated"]
      reasons
    end

    def discovery_age_reasons(node)
      value = node && node["discovered_at"]
      return ["inventory refresh time was not recorded"] if value.to_s.empty?

      discovered_at = Time.iso8601(value.to_s).utc
      age = Time.now.utc - discovered_at
      return ["inventory refresh time is in the future"] if age < -CLOCK_SKEW_SECONDS
      return ["inventory is older than #{MAX_AGE_SECONDS / 3600} hours"] if age > MAX_AGE_SECONDS

      []
    rescue ArgumentError
      ["inventory refresh time is invalid"]
    end

    def selection_fingerprint(config, source_id)
      config.repositories_config(source_id).merge("identity" => config.source_key(source_id))
    end

    def status(state, *reasons, missing_contexts: [])
      { "state" => state, "reasons" => reasons, "missing_contexts" => missing_contexts }
    end
  end
end
