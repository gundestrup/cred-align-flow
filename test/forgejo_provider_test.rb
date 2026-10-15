# frozen_string_literal: true

require_relative "test_helper"
require "socket"

class ForgejoProviderTest < Minitest::Test
  TEST_AUTH_TOKEN = "synthetic-forgejo-test-token"
  PROXY_ENV = %w[HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy].freeze

  def test_normalizes_repositories_and_uses_user_endpoint
    response = {
      "id" => 42,
      "name" => "repo",
      "full_name" => "example/repo",
      "private" => false,
      "internal" => false,
      "archived" => false,
      "fork" => true,
      "permissions" => { "admin" => true }
    }

    with_http_server([{ body: [response] }]) do |adapter, requests|
      repositories = adapter.repositories
      request = requests.pop

      assert_equal "42", repositories.first.fetch("id")
      assert_equal "example/repo", repositories.first.fetch("nameWithOwner")
      assert_equal "PUBLIC", repositories.first.fetch("visibility")
      assert_equal true, repositories.first.fetch("isFork")
      assert_equal true, repositories.first.fetch("viewerCanAdminister")
      assert_equal "GET", request.fetch("method")
      assert_equal "/api/v1/users/example/repos?page=1&limit=100", request.fetch("target")
      assert_equal "token #{TEST_AUTH_TOKEN}", request.fetch("headers").fetch("authorization")
      assert_equal "application/json", request.fetch("headers").fetch("accept")
    end
  end

  def test_organization_sources_use_org_repository_endpoint
    with_http_server([{ body: [] }], "owner_type" => "organization") do |adapter, requests|
      assert_empty adapter.repositories
      assert_equal "/api/v1/orgs/example/repos?page=1&limit=100", requests.pop.fetch("target")
    end
  end

  def test_fetches_metadata_for_only_the_explicit_repository
    response = {
      "id" => 42,
      "name" => "repo",
      "full_name" => "example/repo",
      "private" => true,
      "internal" => false,
      "archived" => false,
      "fork" => false,
      "permissions" => { "admin" => true }
    }

    with_http_server([{ body: response }]) do |adapter, requests|
      repository = adapter.repository("example/repo")
      request = requests.pop

      assert_equal "PRIVATE", repository.fetch("visibility")
      assert_equal true, repository.fetch("viewerCanAdminister")
      assert_equal "/api/v1/repos/example/repo", request.fetch("target")
      assert_equal "token #{TEST_AUTH_TOKEN}", request.fetch("headers").fetch("authorization")
    end
  end

  def test_repository_metadata_keeps_missing_admin_permission_unknown
    response = {
      "id" => 42,
      "name" => "repo",
      "full_name" => "example/repo",
      "private" => false,
      "internal" => false,
      "archived" => false,
      "fork" => false
    }

    with_http_server([{ body: response }]) do |adapter, _requests|
      assert_nil adapter.repository("example/repo").fetch("viewerCanAdminister")
    end
  end

  def test_normalizes_secret_metadata_without_values
    response = [{ "name" => "SONAR_TOKEN", "created_at" => "2026-01-02T03:04:05Z" }]

    with_http_server([{ body: response }]) do |adapter, requests|
      secrets = adapter.secrets("example/repo", "actions")
      request = requests.pop

      assert_equal [{ "name" => "SONAR_TOKEN", "updatedAt" => "2026-01-02T03:04:05Z" }], secrets
      assert_equal "GET", request.fetch("method")
      assert_equal "/api/v1/repos/example/repo/actions/secrets?page=1&limit=100", request.fetch("target")
      assert_equal "token #{TEST_AUTH_TOKEN}", request.fetch("headers").fetch("authorization")
      assert_equal "application/json", request.fetch("headers").fetch("accept")
      refute secrets.first.key?("value")
    end
  end

  def test_uses_total_count_header_for_secret_pagination
    first_page = Array.new(100) do |index|
      { "name" => "SECRET_#{index}", "created_at" => "2026-01-02T03:04:05Z" }
    end
    last_page = [{ "name" => "SECRET_100", "created_at" => "2026-01-02T03:04:05Z" }]

    with_http_server([
                       { body: first_page, headers: { "X-Total-Count" => "101" } },
                       { body: last_page }
                     ]) do |adapter, requests|
      secrets = adapter.secrets("example/repo", "actions")
      first_request = requests.pop
      second_request = requests.pop

      assert_equal 101, secrets.length
      assert_equal "/api/v1/repos/example/repo/actions/secrets?page=1&limit=100", first_request.fetch("target")
      assert_equal "/api/v1/repos/example/repo/actions/secrets?page=2&limit=100", second_request.fetch("target")
    end
  end

  def test_continues_after_a_short_page_when_total_count_reports_more_records
    first_page = Array.new(20) do |index|
      { "name" => "SECRET_#{index}", "created_at" => "2026-01-02T03:04:05Z" }
    end
    last_page = [{ "name" => "SECRET_20", "created_at" => "2026-01-02T03:04:05Z" }]

    with_http_server([
                       { body: first_page, headers: { "X-Total-Count" => "21" } },
                       { body: last_page }
                     ]) do |adapter, requests|
      secrets = adapter.secrets("example/repo", "actions")
      pages = [requests.pop.fetch("target"), requests.pop.fetch("target")]

      assert_equal 21, secrets.length
      assert_equal ["/api/v1/repos/example/repo/actions/secrets?page=1&limit=100",
                    "/api/v1/repos/example/repo/actions/secrets?page=2&limit=100"], pages
    end
  end

  def test_rejects_malformed_pagination_total_count
    with_http_server([
                       { body: [{ "name" => "TOKEN" }], headers: { "X-Total-Count" => "many" } }
                     ]) do |adapter, _requests|
      error = assert_raises(CredAlignFlow::ProviderError) do
        adapter.secrets("example/repo", "actions")
      end

      assert_includes error.message, "invalid total-count header"
    end
  end

  def test_maps_http_errors_to_provider_errors
    with_http_server([{ status: 401, body: { "message" => TEST_AUTH_TOKEN } }]) do |adapter, requests|
      error = assert_raises(CredAlignFlow::ProviderError) do
        adapter.secrets("example/repo", "actions")
      end

      assert_includes error.message, "HTTP 401"
      assert_equal "token #{TEST_AUTH_TOKEN}", requests.pop.fetch("headers").fetch("authorization")
      refute_includes error.message, TEST_AUTH_TOKEN
    end
  end

  def test_accepts_base_url_without_api_path
    adapter = CredAlignFlow::Providers::Forgejo.new(
      {
        "type" => "forgejo",
        "owner" => "example",
        "url" => "https://forgejo.example/",
        "auth_env" => "FORGEJO_TOKEN"
      },
      {}
    )

    assert_equal "Forgejo API https://forgejo.example/api/v1", adapter.cli_version
  end

  def test_readiness_does_not_echo_provider_response_fields
    with_http_server([{ body: { "version" => TEST_AUTH_TOKEN } }]) do |adapter, _requests|
      message = adapter.readiness

      assert_equal "Forgejo API reachable", message
      refute_includes message, TEST_AUTH_TOKEN
    end
  end

  def test_rejects_unknown_contexts_without_an_http_request
    adapter = build_adapter

    error = assert_raises(CredAlignFlow::ProviderError) do
      adapter.secrets("example/repo", "dependabot")
    end
    assert_includes error.message, "dependabot"
  end

  def test_writes_are_disabled_until_sandboxed_integration_exists
    adapter = build_adapter

    refute_predicate adapter, :writable?
    error = assert_raises(CredAlignFlow::ProviderError) do
      adapter.set_secret("example/repo", "actions", "SONAR_TOKEN", "synthetic-test-value")
    end
    assert_includes error.message, "pull-only"
  end

  def test_user_scope_cannot_be_listed
    adapter = build_adapter

    error = assert_raises(CredAlignFlow::ProviderError) do
      adapter.secrets("example/repo", "user")
    end
    assert_includes error.message, "write-only"
  end

  def test_user_scope_writes_require_the_source_opt_in
    adapter = build_adapter

    refute adapter.writable?("user")
    error = assert_raises(CredAlignFlow::ProviderError) do
      adapter.set_secret("example/repo", "user", "SONAR_TOKEN", "synthetic-test-value")
    end
    assert_includes error.message, "user_secrets"
  end

  def test_user_scope_write_puts_the_secret_to_the_user_endpoint
    with_http_server([{ body: { "name" => "SONAR_TOKEN" } }], "user_secrets" => true) do |adapter, requests|
      assert adapter.writable?("user")
      assert_nil adapter.set_secret("@owner", "user", "SONAR_TOKEN", "synthetic-test-value")

      request = requests.pop

      assert_equal "PUT", request.fetch("method")
      assert_equal "/api/v1/user/actions/secrets/SONAR_TOKEN", request.fetch("target")
      assert_equal "token #{TEST_AUTH_TOKEN}", request.fetch("headers").fetch("authorization")
      assert_equal({ "data" => "synthetic-test-value" }, JSON.parse(request.fetch("body")))
    end
  end

  def test_user_scope_write_maps_http_errors_to_provider_errors
    with_http_server([{ status: 403, body: { "message" => "denied" } }],
                     "user_secrets" => true) do |adapter, _requests|
      error = assert_raises(CredAlignFlow::ProviderError) do
        adapter.set_secret("@owner", "user", "SONAR_TOKEN", "synthetic-test-value")
      end
      assert_includes error.message, "HTTP 403"
    end
  end

  def test_user_scope_write_rejects_malformed_secret_names
    with_http_server([], "user_secrets" => true) do |adapter, _requests|
      error = assert_raises(CredAlignFlow::ProviderError) do
        adapter.set_secret("@owner", "user", "../bad", "synthetic-test-value")
      end
      assert_includes error.message, "invalid Forgejo secret name"
    end
  end

  private

  def build_adapter(overrides = {})
    source = {
      "type" => "forgejo",
      "owner" => "example",
      "api_url" => "http://127.0.0.1:1/api/v1",
      "auth_env" => "FORGEJO_TEST_TOKEN"
    }.merge(overrides)

    CredAlignFlow::Providers::Forgejo.new(source, { "FORGEJO_TEST_TOKEN" => TEST_AUTH_TOKEN })
  end

  def with_http_server(responses, source_overrides = {})
    server = TCPServer.new("127.0.0.1", 0)
    requests = Queue.new
    failures = Queue.new
    response_specs = responses.dup
    thread = Thread.new do
      socket = nil
      response_specs.each do |spec|
        socket = server.accept
        requests << read_request(socket)
        status = spec.fetch(:status, 200)
        payload = JSON.generate(spec.fetch(:body))
        headers = {
          "Content-Type" => "application/json",
          "Content-Length" => payload.bytesize.to_s,
          "Connection" => "close"
        }.merge(spec.fetch(:headers, {}))
        reason = { 200 => "OK", 401 => "Unauthorized", 403 => "Forbidden" }.fetch(status, "Error")
        response = "HTTP/1.1 #{status} #{reason}\r\n"
        headers.each { |name, value| response << "#{name}: #{value}\r\n" }
        socket.write("#{response}\r\n#{payload}")
        socket.close
        socket = nil
      end
    rescue IOError => e
      failures << e unless server.closed?
    rescue StandardError => e
      failures << e
    ensure
      socket.close if socket && !socket.closed?
    end

    saved_proxy_env = PROXY_ENV.to_h { |name| [name, ENV.fetch(name, nil)] }
    PROXY_ENV.each { |name| ENV.delete(name) }
    begin
      source = {
        "type" => "forgejo",
        "owner" => "example",
        "api_url" => "http://127.0.0.1:#{server.addr[1]}/api/v1",
        "auth_env" => "FORGEJO_TEST_TOKEN"
      }.merge(source_overrides)
      adapter = CredAlignFlow::Providers::Forgejo.new(source, { "FORGEJO_TEST_TOKEN" => TEST_AUTH_TOKEN })
      yield adapter, requests
    ensure
      server.close unless server.closed?
      thread.join(1)
      thread.kill if thread.alive?
      thread.join
      saved_proxy_env.each do |name, value|
        value.nil? ? ENV.delete(name) : ENV[name] = value
      end
    end
    raise failures.pop unless failures.empty?
  end

  def read_request(socket)
    request_line = socket.gets("\r\n")
    raise "missing HTTP request line" if request_line.nil?

    method, target, = request_line.split(" ", 3)
    headers = {}
    while (line = socket.gets("\r\n")) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.downcase] = value.to_s.strip
    end
    length = headers["content-length"].to_i
    body = length.positive? ? socket.read(length) : ""

    { "method" => method, "target" => target, "headers" => headers, "body" => body }
  end
end
