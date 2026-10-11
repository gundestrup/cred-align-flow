# frozen_string_literal: true

module CredAlignFlow
  class Provider
    REQUIRED_METHODS = %i[repositories repository secrets set_secret].freeze
    WRITABLE = true
    MAX_SECRET_VALUE_BYTES = nil
    MAX_REPOSITORY_SECRETS = nil

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
      return if contexts.is_a?(Array) && contexts.all?(String) && !contexts.empty?

      raise ProviderError, "#{adapter_class} must define a nonempty CONTEXTS array"
    end

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

    def contexts
      self.class.const_defined?(:CONTEXTS) ? self.class::CONTEXTS : []
    end

    def validate_context!(context)
      return if contexts.include?(context)

      raise ProviderError, "#{self.class} does not support context #{context.inspect}"
    end

    def writable?
      self.class::WRITABLE
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
