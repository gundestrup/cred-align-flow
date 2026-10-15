# frozen_string_literal: true

require_relative "provider"
require_relative "providers/forgejo"
require_relative "providers/github"

module CredAlignFlow
  module Providers
    @registry = {}

    def self.register(type, adapter_class)
      Provider.assert_contract!(adapter_class)
      @registry[type.to_s] = adapter_class
    end

    def self.supported_types
      @registry.keys.sort
    end

    def self.adapter_for(type)
      @registry[type.to_s]
    end

    # Read-only token presets contributed by adapters, keyed by preset
    # name across the given provider types.
    def self.builtin_token_presets(types)
      types.each_with_object({}) do |type, presets|
        adapter = adapter_for(type)
        next unless adapter&.const_defined?(:TOKEN_PRESETS, false)

        adapter::TOKEN_PRESETS.each { |name, fields| presets[name] = fields }
      end
    end

    # Whether `context` names an owner-level store for the provider type
    # (e.g. Forgejo `user` scope) rather than a per-repository store.
    def self.owner_scoped_context?(type, context)
      adapter = adapter_for(type)
      adapter ? adapter.owner_scoped_context?(context) : false
    end

    def self.build(source, env_values)
      type = source.fetch("type")
      adapter_class = adapter_for(type)
      return adapter_class.new(source, env_values) if adapter_class

      raise ProviderError,
            "Unsupported source type #{type.inspect}; supported types: #{supported_types.join(', ')}"
    end

    register "forgejo", Forgejo
    register "github", GitHub
  end
end
