# frozen_string_literal: true

require_relative "test_helper"
require "socket"

class ReleaseCheckerTest < Minitest::Test
  def test_returns_highest_mature_release_and_caches_for_24_hours
    releases = [
      { "tag_name" => "v0.0.3", "draft" => false, "published_at" => "2026-10-10T12:00:00Z" },
      { "tag_name" => "v0.0.2", "draft" => false, "published_at" => "2026-10-01T12:00:00Z" },
      { "tag_name" => "v0.0.1", "draft" => false, "published_at" => "2026-09-01T12:00:00Z" },
      { "tag_name" => "v9.0.0", "draft" => true, "published_at" => "2026-10-01T12:00:00Z" },
      { "tag_name" => "v8.0.0", "draft" => false },
      { "tag_name" => "nightly", "draft" => false, "published_at" => "2026-10-01T12:00:00Z" }
    ]
    now = Time.utc(2026, 10, 11, 12)
    clock = 0

    with_api_response(releases, request_count: 2) do |endpoint, requests|
      checker = CredAlignFlow::ReleaseChecker.new(endpoint: endpoint, monotonic_clock: -> { clock })

      assert_equal "v0.0.2", checker.newer_version(current_version: "0.0.1", minimum_age_days: 7, now: now)
      clock = 86_399

      assert_equal "v0.0.2", checker.newer_version(current_version: "0.0.1", minimum_age_days: 7, now: now)
      assert_equal 1, requests.size
      clock = 86_400

      assert_equal "v0.0.2", checker.newer_version(current_version: "0.0.1", minimum_age_days: 7, now: now)
      assert_equal 2, requests.size
      request = requests.pop

      assert_equal "GET /releases?per_page=100 HTTP/1.1", request.fetch(:line)
      assert_equal "application/vnd.github+json", request.fetch(:headers).fetch("accept")
      assert_equal "cred-align-flow", request.fetch(:headers).fetch("user-agent")
    end
  end

  def test_release_waits_until_the_configured_minimum_age
    releases = [{ "tag_name" => "v0.0.2", "draft" => false, "published_at" => "2026-10-05T12:00:00Z" }]
    now = Time.utc(2026, 10, 11, 12)

    with_api_response(releases, request_count: 2) do |endpoint, _requests|
      checker = CredAlignFlow::ReleaseChecker.new(endpoint: endpoint)

      assert_nil checker.newer_version(current_version: "0.0.1", minimum_age_days: 7, now: now)
      assert_equal "v0.0.2", checker.newer_version(current_version: "0.0.1", minimum_age_days: 6, now: now)
    end
  end

  def test_returns_nil_when_no_release_is_newer
    releases = [{ "tag_name" => "v0.0.1", "draft" => false, "published_at" => "2026-09-01T12:00:00Z" }]

    with_api_response(releases) do |endpoint, _requests|
      checker = CredAlignFlow::ReleaseChecker.new(endpoint: endpoint)

      assert_nil checker.newer_version(current_version: "0.0.1", now: Time.utc(2026, 10, 11, 12))
    end
  end

  private

  def with_api_response(releases, request_count: 1)
    server = TCPServer.new("127.0.0.1", 0)
    requests = Queue.new
    proxy_variables = %w[HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy]
    previous_proxy = proxy_variables.to_h { |name| [name, ENV.fetch(name, nil)] }
    proxy_variables.each { |name| ENV.delete(name) }
    body = JSON.generate(releases)
    thread = Thread.new do
      socket = nil
      request_count.times do
        socket = server.accept
        request_line = socket.gets("\r\n")
        headers = {}
        while (line = socket.gets("\r\n")) && line != "\r\n"
          name, value = line.split(":", 2)
          headers[name.downcase] = value.to_s.strip
        end
        requests << { line: request_line.to_s.strip, headers: headers }
        response = [
          "HTTP/1.1 200 OK",
          "Content-Type: application/json",
          "Content-Length: #{body.bytesize}",
          "Connection: close",
          "",
          body
        ].join("\r\n")
        socket.write(response)
        socket.close
        socket = nil
      end
    rescue IOError, SystemCallError
      nil
    ensure
      socket.close if socket && !socket.closed?
    end

    yield "http://127.0.0.1:#{server.addr[1]}/releases?per_page=100", requests
  ensure
    server.close unless server.closed?
    thread.join(1)
    thread.kill if thread.alive?
    thread.join
    previous_proxy.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end
end
