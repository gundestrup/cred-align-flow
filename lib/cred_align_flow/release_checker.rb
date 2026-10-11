# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "timeout"
require "uri"

module CredAlignFlow
  class ReleaseChecker
    API_ENDPOINT = URI.parse("https://api.github.com/repos/gundestrup/cred-align-flow/releases?per_page=100").freeze
    OPEN_TIMEOUT = 2
    READ_TIMEOUT = 2
    VERSION_PATTERN = /\Av?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\z/

    def initialize(endpoint: API_ENDPOINT)
      @endpoint = URI.parse(endpoint.to_s)
    end

    def newer_version(current_version:)
      current = version_parts(current_version)
      return nil unless current

      fetch_releases.filter_map do |release|
        next unless release.is_a?(Hash) && release["draft"] != true

        version = version_parts(release["tag_name"])
        [version, release["tag_name"]] if version && (version <=> current).positive?
      end.max_by(&:first)&.last
    end

    private

    def fetch_releases
      request = Net::HTTP::Get.new(@endpoint.request_uri)
      request["Accept"] = "application/vnd.github+json"
      request["User-Agent"] = "cred-align-flow"
      response = Net::HTTP.start(
        @endpoint.host,
        @endpoint.port,
        use_ssl: @endpoint.scheme == "https",
        open_timeout: OPEN_TIMEOUT,
        read_timeout: READ_TIMEOUT
      ) { |http| http.request(request) }
      return [] unless response.is_a?(Net::HTTPSuccess)

      releases = JSON.parse(response.body.to_s)
      releases.is_a?(Array) ? releases : []
    rescue JSON::ParserError, IOError, SystemCallError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError
      []
    end

    def version_parts(value)
      match = VERSION_PATTERN.match(value.to_s)
      match&.captures&.map(&:to_i)
    end
  end
end
