# frozen_string_literal: true

require "ipaddr"
require "json"
require "securerandom"
require "socket"
require_relative "release_checker"

module CredAlignFlow
  class ConfigRackApp
    MAX_BODY_BYTES = 1_048_576

    class RequestError < StandardError
      attr_reader :status

      def initialize(message, status: 403)
        @status = status
        super(message)
      end
    end

    def initialize(editor:, port:, release_checker: ReleaseChecker.new)
      @editor = editor
      @port = Integer(port)
      @release_checker = release_checker
      @csrf_token = SecureRandom.hex(32)
    end

    def call(env)
      raise RequestError, "request must use the local UI host" unless local_request?(env)

      dispatch_request(env)
    rescue RequestError => e
      json_response({ "error" => e.message }, status: e.status)
    rescue ConfigEditor::RevisionConflict => e
      json_response({ "error" => e.message }, status: 409)
    rescue ConfigError, StateError => e
      json_response({ "error" => e.message }, status: 422)
    rescue ProviderError
      json_response({ "error" => "inventory refresh failed; check provider authentication and retry" }, status: 422)
    rescue JSON::ParserError, KeyError
      json_response({ "error" => "invalid request body" }, status: 400)
    rescue StandardError
      json_response({ "error" => "request failed" }, status: 500)
    end

    private

    def dispatch_request(env)
      case [env["REQUEST_METHOD"], env["PATH_INFO"]]
      when ["GET", "/"]
        html_response
      when ["GET", "/api/data"]
        json_response(with_csrf(@editor.data))
      when ["GET", "/api/update"]
        json_response(update_status)
      when ["POST", "/api/preview"]
        authorize_mutation!(env)
        json_response(with_csrf(@editor.preview(json_body(env))))
      when ["POST", "/api/save"]
        authorize_mutation!(env)
        json_response(with_csrf(@editor.save(json_body(env))))
      when ["POST", "/api/inventory"]
        authorize_mutation!(env)
        json_response(with_csrf(@editor.refresh_inventory(json_body(env))))
      else
        json_response({ "error" => "not found" }, status: 404)
      end
    end

    def update_status
      return { "update_version" => nil } unless @editor.update_check_enabled?

      { "update_version" => @release_checker.newer_version(current_version: VERSION) }
    end

    # Every payload carries the live CSRF token so a page that outlived a
    # server restart can pick up the new token from a data poll and retry
    # a failed mutation without a manual reload.
    def with_csrf(data)
      data.merge("csrf" => @csrf_token)
    end

    def local_request?(env)
      host = env["HTTP_HOST"].to_s.downcase
      valid_host = ["127.0.0.1:#{@port}", "localhost:#{@port}"].include?(host)
      valid_host && IPAddr.new(env["REMOTE_ADDR"].to_s).loopback?
    rescue SocketError, IPAddr::InvalidAddressError
      false
    end

    def authorize_mutation!(env)
      host = env["HTTP_HOST"].to_s.downcase
      raise RequestError, "mutation must originate from this config UI" unless env["HTTP_ORIGIN"] == "http://#{host}"
      return if secure_token?(env["HTTP_X_CRED_ALIGN_TOKEN"])

      raise RequestError, "missing or invalid config UI request token"
    end

    def secure_token?(value)
      value.is_a?(String) && value.bytesize == @csrf_token.bytesize && value == @csrf_token
    end

    def json_body(env)
      raise RequestError.new("request body is too large", status: 413) if env.fetch("CONTENT_LENGTH", "0").to_i > MAX_BODY_BYTES

      content_type = env["CONTENT_TYPE"].to_s
      raise RequestError.new("request must use application/json", status: 400) unless content_type.start_with?("application/json")

      body = env.fetch("rack.input").read(MAX_BODY_BYTES + 1).to_s
      raise RequestError.new("request body is too large", status: 413) if body.bytesize > MAX_BODY_BYTES

      JSON.parse(body)
    end

    def html_response
      nonce = SecureRandom.hex(16)
      template = File.read(File.join(__dir__, "config_ui.html"), encoding: "UTF-8")
      headers = security_headers.merge(
        "Content-Type" => "text/html; charset=utf-8",
        "Content-Security-Policy" => [
          "default-src 'none'",
          "script-src 'nonce-#{nonce}'",
          "style-src 'nonce-#{nonce}'",
          "connect-src 'self'",
          "base-uri 'none'",
          "form-action 'self'",
          "frame-ancestors 'none'"
        ].join("; ")
      )
      [200, headers, [template.gsub("__CSP_NONCE__", nonce).gsub("__CSRF_TOKEN__", @csrf_token)]]
    end

    def json_response(data, status: 200)
      [status, security_headers.merge("Content-Type" => "application/json; charset=utf-8"), [JSON.generate(data)]]
    end

    def security_headers
      {
        "X-Content-Type-Options" => "nosniff",
        "X-Frame-Options" => "DENY",
        "Referrer-Policy" => "no-referrer",
        "Cache-Control" => "no-store"
      }
    end
  end
end
