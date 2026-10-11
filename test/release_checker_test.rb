# frozen_string_literal: true

require_relative "test_helper"
require "socket"

class ReleaseCheckerTest < Minitest::Test
  def test_returns_the_highest_numeric_release_newer_than_current
    releases = [
      { "tag_name" => "v0.0.2", "draft" => false },
      { "tag_name" => "v0.0.1", "draft" => false },
      { "tag_name" => "v9.0.0", "draft" => true },
      { "tag_name" => "nightly", "draft" => false }
    ]

    with_api_response(releases) do |endpoint, requests|
      checker = CredAlignFlow::ReleaseChecker.new(endpoint: endpoint)

      assert_equal "v0.0.2", checker.newer_version(current_version: "0.0.1")
      request = requests.pop

      assert_equal "GET /releases?per_page=100 HTTP/1.1", request.fetch(:line)
      assert_equal "application/vnd.github+json", request.fetch(:headers).fetch("accept")
      assert_equal "cred-align-flow", request.fetch(:headers).fetch("user-agent")
    end
  end

  def test_returns_nil_when_no_release_is_newer
    releases = [{ "tag_name" => "v0.0.1", "draft" => false }]

    with_api_response(releases) do |endpoint, _requests|
      checker = CredAlignFlow::ReleaseChecker.new(endpoint: endpoint)

      assert_nil checker.newer_version(current_version: "0.0.1")
    end
  end

  private

  def with_api_response(releases)
    server = TCPServer.new("127.0.0.1", 0)
    requests = Queue.new
    proxy_variables = %w[HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy]
    previous_proxy = proxy_variables.to_h { |name| [name, ENV.fetch(name, nil)] }
    proxy_variables.each { |name| ENV.delete(name) }
    body = JSON.generate(releases)
    thread = Thread.new do
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
