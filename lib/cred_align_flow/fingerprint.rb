# frozen_string_literal: true

require "digest"
require "fileutils"
require "openssl"
require "securerandom"

module CredAlignFlow
  # Keyed fingerprints of secret values. The HMAC key lives in a private
  # local key file next to the env file; fingerprints are credential-derived
  # metadata, never sent to the browser or remote providers. They compare
  # local desired material with the material recorded as applied — they do
  # not prove remote value equality. A lost key makes digests unverifiable
  # rather than silently current.
  module Fingerprint
    PREFIX = "hmac-sha256:"
    LEGACY_PREFIX = "sha256:"
    PATTERN = /\A(?:hmac-sha256|sha256):[0-9a-f]{64}\z/
    INPUT = "cred-align-flow"
    KEY_BYTES = 32
    KEY_FILE_NAME = ".digest-key"
    ENV_KEY = "CRED_ALIGN_FLOW_FINGERPRINT_KEY"

    class << self
      attr_writer :key

      # The environment variable wins over the key file — it lets the key
      # live in a password manager or be fixed deterministically in tests.
      def key
        env_key = ENV.fetch(ENV_KEY, nil)
        return env_key unless env_key.nil? || env_key.empty?

        @key
      end

      def configured?
        !key.nil?
      end

      def protected_records_present?(config, state)
        return true if config.secrets.any? { |secret| secret["value_digest"].to_s.start_with?(PREFIX) }

        applied = state.data.fetch("applied", {})
        return false unless applied.is_a?(Hash)

        applied.values.any? do |record|
          record.is_a?(Hash) && record["fingerprint"].to_s.start_with?(PREFIX)
        end
      end

      def reset!
        @key = nil
      end

      def default_key_file(env_path)
        File.join(File.dirname(File.expand_path(env_path)), KEY_FILE_NAME)
      end

      # Loads an existing private key file or creates one with restrictive
      # permissions. Concurrent creation uses O_EXCL so the loser reads the
      # winner's key instead of overwriting it.
      def configure!(key_file, require_existing: false)
        path = File.expand_path(key_file)
        raise ConfigError, "fingerprint key file must not be a symlink: #{path}" if File.symlink?(path)
        return load_key_file(path) if File.exist?(path)
        if require_existing
          raise ConfigError,
                "fingerprint key is missing at #{path}; restore the backup to avoid treating every applied value as rotated"
        end

        directory = File.dirname(path)
        directory_existed = File.directory?(directory)
        FileUtils.mkdir_p(directory)
        FileUtils.chmod(0o700, directory) unless directory_existed
        generated = SecureRandom.hex(KEY_BYTES)
        begin
          File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
            file.write("#{generated}\n")
          end
          FileUtils.chmod(0o600, path)
          @key = generated
        rescue Errno::EEXIST
          load_key_file(path)
        end
        @key
      rescue SystemCallError => e
        raise ConfigError, "could not load or create fingerprint key file #{path}: #{e.message}"
      end

      def load_key_file(path)
        raise ConfigError, "fingerprint key file must not be a symlink: #{path}" if File.symlink?(path)

        permissions_restricted = File.stat(path).mode.nobits?(0o077)
        raise ConfigError, "fingerprint key file permissions are too permissive: #{path}" unless permissions_restricted

        material = File.read(path).strip
        raise ConfigError, "fingerprint key file is malformed: #{path}" unless material.match?(/\A[0-9a-f]{#{KEY_BYTES * 2}}\z/)

        @key = material
      end

      def digest(name, value)
        material = key or raise ConfigError, "fingerprint key is not configured"
        "#{PREFIX}#{OpenSSL::HMAC.hexdigest('SHA256', material, "#{INPUT}\0#{name}\0#{value}")}"
      end

      # Legacy unkeyed digests remain readable so previously recorded
      # fingerprints still validate; new fingerprints are always keyed.
      def legacy_digest(name, value)
        "#{LEGACY_PREFIX}#{Digest::SHA256.hexdigest("#{INPUT}\0#{name}\0#{value}")}"
      end

      def valid_format?(recorded)
        recorded.is_a?(String) && recorded.match?(PATTERN)
      end

      def matches?(recorded, name, value)
        return false unless valid_format?(recorded)
        return recorded == legacy_digest(name, value) if recorded.start_with?(LEGACY_PREFIX)
        return false unless configured?

        OpenSSL.fixed_length_secure_compare(digest(name, value), recorded)
      end
    end
  end
end
