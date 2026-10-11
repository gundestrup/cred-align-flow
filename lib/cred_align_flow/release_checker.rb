# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "timeout"
require "time"
require "uri"

module CredAlignFlow
  class ReleaseChecker
    API_ENDPOINT = URI.parse("https://api.github.com/repos/gundestrup/cred-align-flow/releases?per_page=100").freeze
    OPEN_TIMEOUT = 2
    READ_TIMEOUT = 2
    CACHE_TTL_SECONDS = 24 * 60 * 60
    VERSION_PATTERN = /\Av?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\z/

    def initialize(endpoint: API_ENDPOINT, monotonic_clock: nil)
      @endpoint = URI.parse(endpoint.to_s)
      @monotonic_clock = monotonic_clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @cache = nil
    end

    def newer_version(current_version:, minimum_age_days: 7, now: Time.now.utc)
      current = version_parts(current_version)
      return nil unless valid_check?(current, minimum_age_days, now)

      cache_key = [current_version, minimum_age_days]
      checked_at = @monotonic_clock.call
      return @cache[:version] if cache_valid?(cache_key, checked_at)

      cutoff = now.utc - (minimum_age_days * 86_400)
      version = latest_mature_version(current, cutoff)
      @cache = { key: cache_key, checked_at: checked_at, version: version }
      version
    end

    private

    def valid_check?(current, minimum_age_days, now)
      current.is_a?(Array) && minimum_age_days.is_a?(Integer) && minimum_age_days >= 0 && now.is_a?(Time)
    end

    def cache_valid?(key, checked_at)
      @cache && @cache[:key] == key && checked_at - @cache[:checked_at] < CACHE_TTL_SECONDS
    end

    def latest_mature_version(current, cutoff)
      fetch_releases.filter_map { |release| mature_release(release, current, cutoff) }.max_by(&:first)&.last
    end

    def mature_release(release, current, cutoff)
      return unless release.is_a?(Hash) && release["draft"] != true

      parts = version_parts(release["tag_name"])
      published_at = release_published_at(release["published_at"])
      [parts, release["tag_name"]] if parts && (parts <=> current).positive? && published_at && published_at <= cutoff
    end

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

    def release_published_at(value)
      return unless value.is_a?(String) && !value.empty?

      Time.iso8601(value).utc
    rescue ArgumentError
      nil
    end

    def version_parts(value)
      match = VERSION_PATTERN.match(value.to_s)
      match&.captures&.map(&:to_i)
    end
  end
end
