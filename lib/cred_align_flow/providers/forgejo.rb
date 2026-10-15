# frozen_string_literal: true

require "ipaddr"
require "json"
require "net/http"
require "timeout"
require "uri"

module CredAlignFlow
  module Providers
    class Forgejo < Provider
      CONTEXTS = %w[actions user].freeze
      # Owner-scope contexts address the authenticated account's store
      # rather than a repository's. Forgejo user secrets at
      # /user/actions/secrets are write-only (no list endpoint), so this
      # context never participates in inventory or drift detection and is
      # pushed blindly — deletion is intentionally not offered.
      OWNER_CONTEXTS = %w[user].freeze
      WRITABLE = false
      USER_SECRET_NAME_PATTERN = /\A[A-Za-z_][A-Za-z0-9_]*\z/

      TOKEN_PRESETS = {
        "Forgejo: repository Actions" => { "targets" => { "forgejo" => %w[actions] } },
        "Forgejo: user scope" => { "targets" => { "forgejo" => %w[user] } }
      }.freeze
      PAGE_SIZE = 100
      MAX_PAGES = 50
      OPEN_TIMEOUT = 10
      READ_TIMEOUT = 30

      # Normalized API base used for requests and source identity. Auth
      # travels in a header, so the endpoint must be TLS for any remote
      # host; plain http is only allowed for loopback test/disposable
      # services. Embedded credentials are never accepted.
      def self.api_base_for(source)
        raw_url = source["api_url"] || source["url"]
        raise ConfigError, "Forgejo source is missing api_url/url" if raw_url.to_s.empty?

        uri = URI.parse(raw_url)
        unless %w[http https].include?(uri.scheme) && uri.host
          raise ConfigError, "Forgejo source api_url/url must be an http(s) URL"
        end
        raise ConfigError, "Forgejo source api_url/url must not contain embedded credentials" unless uri.userinfo.to_s.empty?
        if uri.scheme == "http" && !loopback_host?(uri.host)
          raise ConfigError, "Forgejo source api_url/url must use https for non-local hosts"
        end

        path = uri.path.to_s.sub(%r{/+\z}, "")
        path = "#{path}/api/v1" unless path.end_with?("/api/v1")
        uri.path = path
        uri.query = nil
        uri.fragment = nil
        uri.to_s
      rescue URI::InvalidURIError => e
        raise ConfigError, "Invalid Forgejo source api_url/url: #{e.message}"
      end

      def self.loopback_host?(host)
        name = host.to_s.downcase
        return true if name == "localhost" || name.end_with?(".localhost")

        IPAddr.new(name).loopback?
      rescue IPAddr::InvalidAddressError
        false
      end

      # Repository secret removal is supported even though value writes
      # stay pull-only: `prune` deletes are explicit per-item user intent,
      # and the API exposes DELETE on the repo actions-secrets path.
      # The write-only user scope is never deletable.
      def self.deletable?(context)
        context.to_s == "actions"
      end

      # Opt-in gate: `user_secrets: true` on the source enables blind
      # pushes to the account-level user-secret store. Since the API
      # cannot list them, applies are unverifiable by design.
      def self.owner_scope_writable?(source)
        source.is_a?(Hash) && source["user_secrets"] == true
      end

      def initialize(source, env_values)
        super()
        @source = source
        @owner = source["owner"].to_s
        @owner_type = source.fetch("owner_type", "user").to_s
        @env_values = env_values
        @api_base = self.class.api_base_for(source)
      end

      def repositories
        paged_get(repositories_path).map { |repo| normalize_repository(repo) }
      end

      def repository(name)
        owner, repo = repository_parts(name)
        response, = request_json("/repos/#{escape(owner)}/#{escape(repo)}")
        normalize_repository(response)
      end

      def owner_scope_writable?
        self.class.owner_scope_writable?(@source)
      end

      def secrets(repository, context)
        validate_context!(context)
        if owner_scoped_context?(context)
          raise ProviderError, "Forgejo user-scope secrets cannot be listed; the API is write-only"
        end

        owner, repo = repository_parts(repository)
        paged_get("/repos/#{escape(owner)}/#{escape(repo)}/actions/secrets").map do |secret|
          unless secret.is_a?(Hash) && secret["name"].is_a?(String) && !secret["name"].empty?
            raise ProviderError, "Forgejo returned a malformed secret entry for #{repository}"
          end

          {
            "name" => secret["name"],
            "updatedAt" => secret["updated_at"] || secret["updatedAt"] || secret["created_at"]
          }
        end
      end

      def set_secret(_repository, context, name, value)
        unless owner_scoped_context?(context)
          raise ProviderError, "Forgejo provider is pull-only for repository secrets; remote writes are not enabled"
        end
        raise ProviderError, "Forgejo user-scope writes require `user_secrets: true` on the source" unless owner_scope_writable?
        unless name.is_a?(String) && name.match?(USER_SECRET_NAME_PATTERN)
          raise ProviderError, "invalid Forgejo secret name #{name.to_s[0, 40].inspect}"
        end

        put_secret("/user/actions/secrets/#{escape(name)}", value)
      end

      def delete_secret(repository, context, name)
        validate_context!(context)
        if owner_scoped_context?(context)
          raise ProviderError, "Forgejo user-scope secrets cannot be deleted; the API is write-only"
        end
        unless name.is_a?(String) && name.match?(USER_SECRET_NAME_PATTERN)
          raise ProviderError, "invalid Forgejo secret name #{name.to_s[0, 40].inspect}"
        end

        owner, repo = repository_parts(repository)
        path = "/repos/#{escape(owner)}/#{escape(repo)}/actions/secrets/#{escape(name)}"
        http_request(Net::HTTP::Delete.new(api_uri(path)), path)
        nil
      end

      def cli_version
        "Forgejo API #{@api_base}"
      end

      def readiness
        request_json("/version")
        "Forgejo API reachable"
      end

      private

      def repositories_path
        return "/user/repos" if @owner.empty?

        case @owner_type
        when "user"
          "/users/#{escape(@owner)}/repos"
        when "org", "organization"
          "/orgs/#{escape(@owner)}/repos"
        else
          raise ConfigError, "Forgejo owner_type must be user or organization"
        end
      end

      def paged_get(path)
        page = 1
        results = []

        loop do
          raise ProviderError, "Forgejo #{path} pagination exceeded #{MAX_PAGES} pages" if page > MAX_PAGES

          response, headers = request_json(path, "page" => page, "limit" => PAGE_SIZE)
          raise ProviderError, "Forgejo #{path} returned #{response.class}, expected an array" unless response.is_a?(Array)

          results.concat(response)
          total_header = headers["x-total-count"] || headers["X-Total-Count"]
          if total_header && !total_header.match?(/\A\d+\z/)
            raise ProviderError, "Forgejo #{path} returned an invalid total-count header"
          end

          total = total_header.to_i
          if total.positive?
            break if results.length >= total

            raise ProviderError, "Forgejo #{path} pagination ended before the reported total of #{total}" if response.empty?
          elsif response.empty? || response.length < PAGE_SIZE
            break
          end

          page += 1
        end

        results
      end

      def request_json(path, query = {})
        uri = api_uri(path)
        uri.query = URI.encode_www_form(query) unless query.empty?
        response = http_request(Net::HTTP::Get.new(uri), path)
        [JSON.parse(response.body.to_s), response.each_header.to_h]
      rescue JSON::ParserError
        raise ProviderError, "Invalid Forgejo JSON response for #{path}"
      end

      # The write body carries the secret value; nothing from the request
      # or response is surfaced in errors beyond the status code.
      def put_secret(path, value)
        request = Net::HTTP::Put.new(api_uri(path))
        request["Content-Type"] = "application/json"
        request.body = JSON.generate("data" => value)
        http_request(request, path)
        nil
      end

      def api_uri(path)
        URI.parse("#{@api_base}#{path}")
      end

      def http_request(request, path)
        uri = request.uri
        request["Accept"] = "application/json"
        request["Authorization"] = "token #{auth_token}" unless auth_token.to_s.empty?

        response = Net::HTTP.start(
          uri.host,
          uri.port,
          use_ssl: uri.scheme == "https",
          open_timeout: OPEN_TIMEOUT,
          read_timeout: READ_TIMEOUT
        ) do |http|
          http.request(request)
        end

        # Response bodies are never surfaced: a proxy or misconfigured
        # service could reflect the Authorization token back in an error.
        unless response.is_a?(Net::HTTPSuccess)
          raise ProviderError, "Forgejo #{request.method} #{path} returned HTTP #{response.code}"
        end

        response
      rescue OpenSSL::SSL::SSLError => e
        raise ProviderError, "Forgejo TLS error for #{@api_base}: #{e.message}"
      rescue SystemCallError, SocketError, Timeout::Error => e
        raise ProviderError, "Unable to reach Forgejo API #{@api_base}: #{redact(e.message)}"
      end

      def auth_token
        auth_ref = @source["auth_env"]
        return nil if auth_ref.to_s.empty?

        token = @env_values[auth_ref] || ENV.fetch(auth_ref, nil)
        raise ProviderError, "Forgejo auth_env #{auth_ref} is not set" if token.to_s.empty?

        token
      end

      def normalize_repository(repo)
        raise ProviderError, "Forgejo repository metadata must be an object" unless repo.is_a?(Hash)

        name = repo["name"].to_s
        full_name = repo["full_name"].to_s
        full_name = "#{@owner}/#{name}" if full_name.empty? && !@owner.empty?
        raise ProviderError, "Forgejo repository metadata is missing name/full_name" if name.empty? || full_name.empty?

        private_repo = boolean_field!(repo, "private")
        internal = boolean_field!(repo, "internal")
        archived = boolean_field!(repo, "archived")
        fork = boolean_field!(repo, "fork")
        permissions = repo["permissions"]
        admin = permissions["admin"] if permissions.is_a?(Hash)
        unless admin.nil? || admin == true || admin == false
          raise ProviderError, "Forgejo repository metadata has invalid admin permission"
        end

        {
          "id" => repo["id"].to_s,
          "name" => name,
          "nameWithOwner" => full_name,
          "isPrivate" => private_repo || internal,
          "isArchived" => archived,
          "isFork" => fork,
          "visibility" => visibility(private_repo, internal),
          "viewerCanAdminister" => admin
        }
      end

      def boolean_field!(repository, field)
        value = repository[field]
        return value if [true, false].include?(value)

        raise ProviderError, "Forgejo repository metadata is missing #{field} status"
      end

      def visibility(private_repo, internal)
        return "INTERNAL" if internal
        return "PRIVATE" if private_repo

        "PUBLIC"
      end

      def repository_parts(repository)
        owner, repo = repository.to_s.split("/", 2)
        raise ProviderError, "Forgejo repository must be owner/name" if owner.to_s.empty? || repo.to_s.empty?

        [owner, repo]
      end

      def escape(value)
        URI::RFC2396_PARSER.escape(value.to_s)
      end
    end
  end
end
