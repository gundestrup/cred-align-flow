# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "net/http"
require "securerandom"
require "uri"

# Exercises the real Forgejo adapter against the disposable Compose
# service in this directory. It runs only when the service is up and the
# environment opts in — see README.md next to this file for provisioning:
#
#   CRED_ALIGN_FLOW_FORGEJO_URL=http://127.0.0.1:3300
#   CRED_ALIGN_FLOW_FORGEJO_TOKEN=<access token>
#
# The base URL must resolve to a loopback host so this test can never
# contact a real hosted Forgejo. The test creates one repository with a
# generated name, exercises the adapter's read paths, verifies writes are
# refused, and deletes the repository again. `docker compose down -v`
# remains the full teardown.
class ForgejoServiceTest < Minitest::Test
  BASE_URL = ENV.fetch("CRED_ALIGN_FLOW_FORGEJO_URL", nil)
  TOKEN = ENV.fetch("CRED_ALIGN_FLOW_FORGEJO_TOKEN", nil)

  def setup
    if BASE_URL.nil? || TOKEN.nil?
      skip "set CRED_ALIGN_FLOW_FORGEJO_URL and CRED_ALIGN_FLOW_FORGEJO_TOKEN to run against the disposable Forgejo service"
    end
    uri = URI.parse(BASE_URL)
    return if CredAlignFlow::Providers::Forgejo.loopback_host?(uri.host)

    skip "CRED_ALIGN_FLOW_FORGEJO_URL must resolve to a loopback host (the disposable Compose service)"
  end

  def test_adapter_against_disposable_service
    source = {
      "type" => "forgejo",
      "url" => BASE_URL,
      "owner_type" => "user",
      "auth_env" => "FORGEJO_SERVICE_TOKEN"
    }
    env_values = { "FORGEJO_SERVICE_TOKEN" => TOKEN }
    adapter = CredAlignFlow::Providers::Forgejo.new(source, env_values)

    assert adapter.readiness
    assert_equal %w[actions], adapter.contexts
    refute_predicate adapter, :writable?

    owner = api_get("/user").fetch("login")
    source["owner"] = owner
    adapter = CredAlignFlow::Providers::Forgejo.new(source, env_values)

    repo_name = "cred-align-it-#{SecureRandom.hex(4)}"
    api_post("/user/repos", "name" => repo_name, "private" => true, "auto_init" => true)
    full_name = "#{owner}/#{repo_name}"

    repositories = adapter.repositories
    found = repositories.find { |repo| repo["nameWithOwner"] == full_name }

    refute_nil found, "adapter did not list the repository the test created"
    assert_equal repo_name, found["name"]
    assert_equal "PRIVATE", found["visibility"]
    assert found["viewerCanAdminister"]

    targeted = adapter.repository(full_name)

    assert_equal found["id"], targeted["id"]

    secrets = adapter.secrets(full_name, "actions")

    assert_kind_of Array, secrets

    error = assert_raises(CredAlignFlow::ProviderError) do
      adapter.set_secret(full_name, "actions", "SHOULD_NOT_WRITE", "synthetic")
    end
    assert_includes error.message, "pull-only"
  ensure
    api_delete("/repos/#{full_name}") if full_name
  end

  private

  def api_get(path)
    api_request(Net::HTTP::Get, path)
  end

  def api_post(path, body)
    api_request(Net::HTTP::Post, path, body)
  end

  def api_delete(path)
    api_request(Net::HTTP::Delete, path)
  end

  def api_request(klass, path, body = nil)
    uri = URI.parse("#{BASE_URL}/api/v1#{path}")
    request = klass.new(uri)
    request["Authorization"] = "token #{TOKEN}"
    request["Accept"] = "application/json"
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(body) if body

    response = Net::HTTP.start(uri.host, uri.port, open_timeout: 10, read_timeout: 30) do |http|
      http.request(request)
    end
    unless response.is_a?(Net::HTTPSuccess)
      raise "Forgejo service #{klass::METHOD} #{path} returned HTTP #{response.code} — is the disposable Compose service running?"
    end

    JSON.parse(response.body.to_s)
  rescue JSON::ParserError
    {}
  end
end
