# frozen_string_literal: true

require_relative "test_helper"

class ProviderContractTest < Minitest::Test
  ADAPTERS = CredAlignFlow::Providers.supported_types.to_h do |type|
    [type, CredAlignFlow::Providers.adapter_for(type)]
  end.freeze

  def test_registered_adapters_satisfy_the_provider_contract
    ADAPTERS.each do |type, adapter_class|
      CredAlignFlow::Provider.assert_contract!(adapter_class)

      assert_includes CredAlignFlow::Providers.supported_types, type
      refute_empty adapter_class::CONTEXTS
    end
  end

  def test_builtin_token_presets_only_reference_own_contexts
    ADAPTERS.each_value do |adapter_class|
      next unless adapter_class.const_defined?(:TOKEN_PRESETS, false)

      adapter_class::TOKEN_PRESETS.each do |name, fields|
        assert_kind_of Hash, fields, "preset #{name}"
        (fields["targets"] || {}).each_value do |contexts|
          assert_empty Array(contexts) - adapter_class::CONTEXTS,
                       "preset #{name} names contexts outside the adapter"
        end
      end
    end
  end

  def test_owner_contexts_are_a_subset_of_contexts
    ADAPTERS.each_value do |adapter_class|
      assert_empty adapter_class.owner_scoped_contexts - adapter_class::CONTEXTS
    end
  end

  def test_registry_builds_adapter_by_source_type
    adapter = CredAlignFlow::Providers.build(
      { "type" => "github", "owner" => "example", "api_url" => "https://api.github.com" },
      {}
    )

    assert_instance_of CredAlignFlow::Providers::GitHub, adapter
    assert_equal %w[actions agents codespaces dependabot], adapter.contexts

    forgejo = CredAlignFlow::Providers.build(
      { "type" => "forgejo", "owner" => "example", "url" => "https://forgejo.example" },
      {}
    )

    assert_instance_of CredAlignFlow::Providers::Forgejo, forgejo
    assert_equal %w[actions user], forgejo.contexts
    refute_predicate forgejo, :writable?
    refute forgejo.writable?("user")
    # Pull-only for writes still allows explicit deletes at repo scope;
    # the write-only account scope can never be deleted.
    assert forgejo.deletable?("actions")
    refute forgejo.deletable?("user")
    assert adapter.deletable?("actions")
  end

  def test_forgejo_owner_scope_writes_require_the_source_opt_in
    forgejo = CredAlignFlow::Providers.build(
      { "type" => "forgejo", "owner" => "example", "url" => "https://forgejo.example",
        "user_secrets" => true },
      {}
    )

    assert forgejo.writable?("user")
    refute forgejo.writable?("actions")
    assert CredAlignFlow::Providers.owner_scoped_context?("forgejo", "user")
    refute CredAlignFlow::Providers.owner_scoped_context?("forgejo", "actions")
    refute CredAlignFlow::Providers.owner_scoped_context?("github", "actions")
  end

  def test_unknown_source_type_reports_supported_adapters
    error = assert_raises(CredAlignFlow::ProviderError) do
      CredAlignFlow::Providers.build({ "type" => "gitlab" }, {})
    end

    assert_includes error.message, "github"
  end

  def test_incomplete_adapter_fails_registration_contract
    incomplete = Class.new(CredAlignFlow::Provider) do
      def repositories
        []
      end
    end

    error = assert_raises(CredAlignFlow::ProviderError) do
      CredAlignFlow::Provider.assert_contract!(incomplete)
    end

    assert_includes error.message, "repository"
    assert_includes error.message, "secrets"
    assert_includes error.message, "set_secret"
    assert_includes error.message, "delete_secret"
  end

  def test_adapter_must_declare_supported_contexts
    no_contexts = Class.new(CredAlignFlow::Provider) do
      def repositories
        []
      end

      def repository(_name)
        {}
      end

      def secrets(_repository, _context)
        []
      end

      def set_secret(_repository, _context, _name, _value)
        true
      end

      def delete_secret(_repository, _context, _name)
        true
      end
    end

    error = assert_raises(CredAlignFlow::ProviderError) do
      CredAlignFlow::Provider.assert_contract!(no_contexts)
    end

    assert_includes error.message, "CONTEXTS"
  end

  def test_contract_rejects_non_provider_classes
    [String, "github", nil].each do |candidate|
      error = assert_raises(CredAlignFlow::ProviderError) do
        CredAlignFlow::Provider.assert_contract!(candidate)
      end

      assert_includes error.message, "must subclass CredAlignFlow::Provider"
    end
  end

  def test_contract_rejects_malformed_token_presets
    adapter = conforming_adapter
    adapter.const_set(:TOKEN_PRESETS, ["not-a-hash"])

    error = assert_raises(CredAlignFlow::ProviderError) do
      CredAlignFlow::Provider.assert_contract!(adapter)
    end

    assert_includes error.message, "TOKEN_PRESETS must map preset names to scope-field hashes"
  end

  def test_contract_rejects_malformed_owner_contexts
    bad_type = conforming_adapter
    bad_type.const_set(:OWNER_CONTEXTS, "user")

    error = assert_raises(CredAlignFlow::ProviderError) do
      CredAlignFlow::Provider.assert_contract!(bad_type)
    end

    assert_includes error.message, "OWNER_CONTEXTS must be an array of context names"

    outside = conforming_adapter
    outside.const_set(:OWNER_CONTEXTS, %w[external])

    error = assert_raises(CredAlignFlow::ProviderError) do
      CredAlignFlow::Provider.assert_contract!(outside)
    end

    assert_includes error.message, "OWNER_CONTEXTS must be a subset of CONTEXTS"
  end

  def test_base_provider_stubs_raise_not_implemented
    provider = CredAlignFlow::Provider.new

    assert_raises(NotImplementedError) { provider.repositories }
    assert_raises(NotImplementedError) { provider.repository("example/repo") }
    assert_raises(NotImplementedError) { provider.secrets("example/repo", "actions") }
    assert_raises(NotImplementedError) { provider.set_secret("example/repo", "actions", "TOKEN", "value") }
    assert_raises(NotImplementedError) { provider.delete_secret("example/repo", "actions", "TOKEN") }
  end

  def test_base_provider_defaults
    provider = CredAlignFlow::Provider.new

    assert_predicate provider, :writable?
    assert provider.deletable?("actions")
    refute_predicate provider, :owner_scope_writable?
    refute CredAlignFlow::Provider.owner_scope_writable?({})
    refute provider.owner_scoped_context?("user")
    assert_nil provider.cli_version
    assert_nil provider.readiness

    error = assert_raises(CredAlignFlow::ProviderError) { provider.validate_context!("actions") }

    assert_includes error.message, "does not support context"
  end

  def test_redact_scrubs_env_values_from_adapter_output
    provider = CredAlignFlow::Provider.new
    provider.instance_variable_set(
      :@env_values, { "TOKEN" => "super-secret-value", "SHORT" => "abc" }
    )

    # Values under 8 characters are not treated as sensitive material —
    # scrubbing short strings would mangle legitimate words in output.
    assert_equal "[redacted] and abc", provider.send(:redact, "super-secret-value and abc")
  end

  private

  def conforming_adapter
    Class.new(CredAlignFlow::Provider).tap do |adapter|
      adapter.const_set(:CONTEXTS, %w[actions])
      adapter.define_method(:repositories) { [] }
      adapter.define_method(:repository) { |_name| {} }
      adapter.define_method(:secrets) { |_repository, _context| [] }
      adapter.define_method(:set_secret) { |_repository, _context, _name, _value| true }
      adapter.define_method(:delete_secret) { |_repository, _context, _name| true }
    end
  end
end
