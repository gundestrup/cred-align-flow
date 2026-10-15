# frozen_string_literal: true

module CredAlignFlow
  class Provider
    REQUIRED_METHODS = %i[repositories repository secrets set_secret delete_secret].freeze
    WRITABLE = true
    MAX_SECRET_VALUE_BYTES = nil
    MAX_REPOSITORY_SECRETS = nil
    # Synthetic plan/state key for contexts that address an owner-level
    # store instead of a repository's (e.g. Forgejo user-scope secrets).
    # It is not a valid owner/name, so it can never collide with a real
    # repository in state or inventory data.
    OWNER_SCOPE_REPOSITORY = "@owner"

    def self.owner_scoped_contexts
      const_defined?(:OWNER_CONTEXTS, false) ? const_get(:OWNER_CONTEXTS) : []
    end

    def self.owner_scoped_context?(context)
      owner_scoped_contexts.include?(context.to_s)
    end

    # The repository-scoped context a generated default should use —
    # owner/account scopes are never a default.
    def self.default_context
      (self::CONTEXTS - owner_scoped_contexts).first
    end

    # Whether a source configuration permits writes to the owner-scope
    # store. Adapters with an owner-level context override this; the
    # default refuses.
    def self.owner_scope_writable?(_source)
      false
    end

    # Whether `prune` can remove a remote secret in this context.
    # Owner-scope stores can never be deleted (the API is write-only);
    # a pull-only adapter may still allow deletes — removal is not a
    # value write — so adapters override this separately from WRITABLE.
    def self.deletable?(context)
      self::WRITABLE && !owner_scoped_context?(context)
    end

    def self.assert_contract!(adapter_class)
      unless adapter_class.is_a?(Class) && adapter_class < self
        raise ProviderError, "Provider adapter must subclass CredAlignFlow::Provider"
      end

      missing = REQUIRED_METHODS.reject do |method_name|
        adapter_class.method_defined?(method_name) &&
          adapter_class.instance_method(method_name).owner != self
      end
      raise ProviderError, "#{adapter_class} is missing provider methods: #{missing.join(', ')}" unless missing.empty?

      contexts = adapter_class.const_defined?(:CONTEXTS, false) ? adapter_class::CONTEXTS : nil
      unless contexts.is_a?(Array) && contexts.all?(String) && !contexts.empty?
        raise ProviderError, "#{adapter_class} must define a nonempty CONTEXTS array"
      end

      assert_presets_contract!(adapter_class)
      assert_owner_contexts_contract!(adapter_class)
    end

    def self.assert_presets_contract!(adapter_class)
      return unless adapter_class.const_defined?(:TOKEN_PRESETS, false)

      presets = adapter_class::TOKEN_PRESETS
      return if presets.is_a?(Hash) && presets.keys.all?(String) && presets.values.all?(Hash)

      raise ProviderError, "#{adapter_class} TOKEN_PRESETS must map preset names to scope-field hashes"
    end
    private_class_method :assert_presets_contract!

    def self.assert_owner_contexts_contract!(adapter_class)
      owner_contexts = adapter_class.owner_scoped_contexts
      unless owner_contexts.is_a?(Array) && owner_contexts.all?(String)
        raise ProviderError, "#{adapter_class} OWNER_CONTEXTS must be an array of context names"
      end
      return if (owner_contexts - adapter_class::CONTEXTS).empty?

      raise ProviderError, "#{adapter_class} OWNER_CONTEXTS must be a subset of CONTEXTS"
    end
    private_class_method :assert_owner_contexts_contract!

    def repositories
      raise NotImplementedError, "#{self.class} must implement repositories"
    end

    def repository(_name)
      raise NotImplementedError, "#{self.class} must implement repository"
    end

    def secrets(_repository, _context)
      raise NotImplementedError, "#{self.class} must implement secrets"
    end

    def set_secret(_repository, _context, _name, _value)
      raise NotImplementedError, "#{self.class} must implement set_secret"
    end

    def delete_secret(_repository, _context, _name)
      raise NotImplementedError, "#{self.class} must implement delete_secret"
    end

    def contexts
      self.class.const_defined?(:CONTEXTS) ? self.class::CONTEXTS : []
    end

    def validate_context!(context)
      return if contexts.include?(context)

      raise ProviderError, "#{self.class} does not support context #{context.inspect}"
    end

    def owner_scoped_context?(context)
      self.class.owner_scoped_context?(context)
    end

    def owner_scope_writable?
      false
    end

    def writable?(context = nil)
      return owner_scope_writable? if context && owner_scoped_context?(context)

      self.class::WRITABLE
    end

    def deletable?(context)
      self.class.deletable?(context)
    end

    def cli_version
      nil
    end

    # Opt-in live readiness check used by `doctor --verify`; nil means the
    # adapter offers no lightweight authenticated probe.
    def readiness
      nil
    end

    private

    # Env values and the auth token are the only secret material an adapter
    # handles; redact them defensively from anything user-visible.
    def redact(text)
      scrubbed = text.to_s
      sensitive_strings.each { |secret| scrubbed = scrubbed.gsub(secret, "[redacted]") }
      scrubbed
    end

    def sensitive_strings
      env = defined?(@env_values) ? @env_values || {} : {}
      env.values.select { |value| value.is_a?(String) && value.length >= 8 }
    end
  end
end
