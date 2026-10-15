# frozen_string_literal: true

require "json"
require "open3"
require "uri"

module CredAlignFlow
  module Providers
    class GitHub < Provider
      CONTEXTS = %w[actions dependabot].freeze
      MAX_DISCOVERY = 1_000
      MAX_REPOSITORY_SECRETS = 100
      MAX_SECRET_VALUE_BYTES = 48 * 1024
      COMMAND_TIMEOUT = 120
      # `gh repo list` does not expose databaseId; `id` is the stable GraphQL
      # node id available on both repo list and repo view.
      REPOSITORY_FIELDS = %w[
        name
        nameWithOwner
        id
        isPrivate
        isArchived
        isFork
        visibility
        viewerCanAdminister
      ].freeze

      def self.host_for(source)
        configured = source["host"]
        return normalize_host(configured) unless configured.to_s.empty?

        url = source["api_url"] || source["url"]
        return "github.com" if url.to_s.empty?

        uri = URI.parse(url)
        unless %w[http https].include?(uri.scheme) && uri.host
          raise ConfigError, "GitHub source api_url/url must be an http(s) URL"
        end

        normalize_host(uri.host)
      rescue URI::InvalidURIError => e
        raise ConfigError, "Invalid GitHub source api_url/url: #{e.message}"
      end

      def self.normalize_host(host)
        hostname = host.to_s.downcase
        # Hostnames are limited to DNS characters; a leading "-" would be
        # parsed as a flag when the host reaches a gh command line.
        raise ConfigError, "Invalid GitHub host #{host.to_s[0, 60].inspect}" unless hostname.match?(HOST_PATTERN)

        return "github.com" if hostname == "api.github.com"
        return hostname.delete_prefix("api.") if hostname.start_with?("api.") && hostname.end_with?(".ghe.com")

        hostname
      end

      def initialize(source, env_values)
        super()
        @source = source
        @owner = source.fetch("owner") { raise ConfigError, "GitHub source is missing owner" }
        unless @owner.is_a?(String) && @owner.match?(GH_NAME_PATTERN)
          raise ConfigError, "invalid GitHub owner #{@owner.to_s[0, 40].inspect}"
        end

        @host = self.class.host_for(source)
        @env_values = env_values
        @truncated = false
      end

      # `gh repo list --limit` is a cap, not a page cursor: hitting it means
      # discovery may be truncated and the inventory must be marked.
      def repositories
        result = run_json([
                            "repo", "list", @owner,
                            "--limit", MAX_DISCOVERY.to_s,
                            "--json", REPOSITORY_FIELDS.join(",")
                          ])
        raise ProviderError, "gh repo list returned malformed data" unless result.is_a?(Array) && result.all?(Hash)

        @truncated = result.length >= MAX_DISCOVERY
        result.map { |repo| normalize_repository_id(repo) }
      end

      def truncated?
        @truncated
      end

      def repository(name)
        validate_name_arg!(name)
        result = run_json(["repo", "view", name, "--json", REPOSITORY_FIELDS.join(",")])
        raise ProviderError, "gh repo view returned malformed data for #{name}" unless result.is_a?(Hash)

        normalize_repository_id(result)
      end

      def secrets(repository, context)
        validate_context!(context)
        validate_name_arg!(repository)
        validate_secret_entries!(run_json([
                                            "secret", "list",
                                            "--repo", repository,
                                            "--app", context,
                                            "--json", "name,updatedAt"
                                          ]), repository)
      end

      # GitHub secret names: letters, digits, underscores; may not start
      # with a number or the reserved GITHUB_ prefix; max 100 characters.
      SECRET_NAME_PATTERN = /\A[A-Za-z_][A-Za-z0-9_]{0,99}\z/

      # gh argv hygiene: owner and owner/repo values must look like GitHub
      # names — no leading "-" (would parse as a flag) and no whitespace
      # or shell characters. Checked before a value reaches a command line.
      GH_NAME_PATTERN = %r{\A[A-Za-z0-9_.][A-Za-z0-9_.-]*(/[A-Za-z0-9_.][A-Za-z0-9_.-]*)?\z}
      HOST_PATTERN = /\A[a-z0-9][a-z0-9.-]*\z/

      def set_secret(repository, context, name, value)
        validate_context!(context)
        validate_name_arg!(repository)
        unless name.is_a?(String) && name.match?(SECRET_NAME_PATTERN) && !name.start_with?("GITHUB_")
          raise ProviderError, "invalid GitHub secret name #{name.to_s[0, 40].inspect}"
        end
        if value.bytesize > MAX_SECRET_VALUE_BYTES
          raise ProviderError, "secret value exceeds the #{MAX_SECRET_VALUE_BYTES}-byte GitHub limit"
        end

        run([
              "secret", "set", name,
              "--repo", repository,
              "--app", context
            ], stdin_data: value)
      end

      def cli_version
        stdout, = run(["--version"], require_auth: false, include_auth: false)
        version = stdout.lines.first.to_s.match(/\Agh version (\d+(?:\.\d+){1,2})\b/)
        version ? "gh version #{version[1]}" : nil
      rescue ProviderError
        nil
      end

      def readiness
        run(["auth", "status", "--hostname", @host])
        "authenticated"
      rescue ProviderError => e
        "not authenticated: #{e.message}"
      end

      private

      def validate_name_arg!(value)
        return if value.is_a?(String) && value.match?(GH_NAME_PATTERN)

        raise ProviderError, "invalid GitHub repository or owner #{value.to_s[0, 40].inspect}"
      end

      def validate_secret_entries!(list, repository)
        valid = list.is_a?(Array) && list.all? do |entry|
          entry.is_a?(Hash) && entry["name"].is_a?(String) && entry["name"].match?(SECRET_NAME_PATTERN)
        end
        unless valid && list.map { |entry| entry["name"].upcase }.uniq.length == list.length
          raise ProviderError, "gh secret list returned malformed or duplicate data for #{repository}"
        end

        list
      end

      def normalize_repository_id(repo)
        repo["id"] = (repo["id"] || repo.delete("databaseId")).to_s
        repo
      end

      def command_env(require_auth: true, include_auth: true)
        env = { "GH_HOST" => @host, "GH_PROMPT_DISABLED" => "1", "GH_NO_UPDATE_NOTIFIER" => "1" }
        unless include_auth
          return env.merge(
            "GH_TOKEN" => nil,
            "GITHUB_TOKEN" => nil,
            "GH_ENTERPRISE_TOKEN" => nil,
            "GITHUB_ENTERPRISE_TOKEN" => nil
          )
        end

        auth_ref = @source["auth_env"]
        return env if auth_ref.to_s.empty?

        token = @env_values[auth_ref] || ENV.fetch(auth_ref, nil)
        if token.to_s.empty?
          raise ProviderError, "GitHub auth_env #{auth_ref} is not set" if require_auth

          return env.merge(
            "GH_TOKEN" => nil,
            "GITHUB_TOKEN" => nil,
            "GH_ENTERPRISE_TOKEN" => nil,
            "GITHUB_ENTERPRISE_TOKEN" => nil
          )
        end

        env.merge!(
          "GH_TOKEN" => nil,
          "GITHUB_TOKEN" => nil,
          "GH_ENTERPRISE_TOKEN" => nil,
          "GITHUB_ENTERPRISE_TOKEN" => nil
        )
        env[github_cloud_host? ? "GH_TOKEN" : "GH_ENTERPRISE_TOKEN"] = token
        env
      end

      def github_cloud_host?
        @host == "github.com" || @host == "github.localhost" || @host.end_with?(".ghe.com")
      end

      def run_json(arguments, stdin_data: nil)
        stdout, _stderr = run(arguments, stdin_data: stdin_data)
        JSON.parse(stdout)
      rescue JSON::ParserError
        raise ProviderError, "Invalid gh JSON output for #{arguments.join(' ')}"
      end

      # Bounded subprocess: values travel via stdin only, stderr is drained but
      # never surfaced, and a hung gh is killed after the timeout.
      def run(arguments, stdin_data: nil, require_auth: true, include_auth: true)
        # argv-form exec (no shell): every non-static argument is a
        # validated GitHub name or a static flag, and secret values
        # travel via stdin only.
        stdin, stdout, stderr, wait_thr = Open3.popen3( # NOSONAR nosemgrep: dangerous-exec
          command_env(require_auth: require_auth, include_auth: include_auth), "gh", *arguments
        )
        stdout_reader = Thread.new { stdout.read }
        stderr_reader = Thread.new { stderr.read }
        stdin_writer = write_stdin(stdin, stdin_data)
        workers = [stdin_writer, stdout_reader, stderr_reader]
        status = wait_for_command(wait_thr, arguments, workers)
        stdin_writer.join
        out = stdout_reader.value
        stderr_reader.value
        raise ProviderError, "gh #{arguments.join(' ')} failed with exit #{status.exitstatus}" unless status.success?

        [out, ""]
      rescue SystemCallError => e
        raise ProviderError, "Unable to run gh: #{e.message}"
      ensure
        [stdin, stdout, stderr].compact.each { |io| io.close unless io.closed? }
      end

      def write_stdin(stdin, value)
        Thread.new do
          stdin.write(value) if value
        rescue Errno::EPIPE, IOError
          nil
        ensure
          stdin.close unless stdin.closed?
        end
      end

      def wait_for_command(wait_thr, arguments, workers)
        return wait_thr.value if wait_thr.join(COMMAND_TIMEOUT)

        kill_process(wait_thr.pid)
        wait_thr.join
        workers.each(&:join)
        raise ProviderError, "gh #{arguments.join(' ')} timed out after #{COMMAND_TIMEOUT}s"
      end

      def kill_process(pid)
        Process.kill("KILL", pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end
    end
  end
end
