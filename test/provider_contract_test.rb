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

  def test_registry_builds_adapter_by_source_type
    adapter = CredAlignFlow::Providers.build(
      { "type" => "github", "owner" => "example", "api_url" => "https://api.github.com" },
      {}
    )

    assert_instance_of CredAlignFlow::Providers::GitHub, adapter
    assert_equal %w[actions dependabot], adapter.contexts

    forgejo = CredAlignFlow::Providers.build(
      { "type" => "forgejo", "owner" => "example", "url" => "https://forgejo.example" },
      {}
    )

    assert_instance_of CredAlignFlow::Providers::Forgejo, forgejo
    assert_equal %w[actions], forgejo.contexts
    refute_predicate forgejo, :writable?
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
    end

    error = assert_raises(CredAlignFlow::ProviderError) do
      CredAlignFlow::Provider.assert_contract!(no_contexts)
    end

    assert_includes error.message, "CONTEXTS"
  end
end
