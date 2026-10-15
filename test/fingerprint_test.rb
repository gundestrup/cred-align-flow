# frozen_string_literal: true

require_relative "test_helper"

class FingerprintTest < Minitest::Test
  TEST_KEY = "test-only fingerprint key"

  def teardown
    # configure!/reset! mutate the process-wide key; restore the shared
    # test key so other suites keep deterministic digests.
    CredAlignFlow::Fingerprint.key = TEST_KEY
  end

  def test_protected_records_present_detects_config_digests_and_applied_fingerprints
    digested_config = Struct.new(:secrets).new([{ "value_digest" => "hmac-sha256:abc" }])
    empty_state = Struct.new(:data).new({})

    assert CredAlignFlow::Fingerprint.protected_records_present?(digested_config, empty_state)

    plain_config = Struct.new(:secrets).new([{ "value_digest" => "plaintext-ref" }])
    applied_state = Struct.new(:data).new(
      { "applied" => { "s|r|c|n" => { "fingerprint" => "hmac-sha256:xyz" } } }
    )

    assert CredAlignFlow::Fingerprint.protected_records_present?(plain_config, applied_state)

    plain_state = Struct.new(:data).new(
      { "applied" => { "s|r|c|n" => { "fingerprint" => "unkeyed" } } }
    )

    refute CredAlignFlow::Fingerprint.protected_records_present?(plain_config, plain_state)
    refute CredAlignFlow::Fingerprint.protected_records_present?(
      plain_config, Struct.new(:data).new({ "applied" => "not-a-hash" })
    )
  end

  def test_configure_creates_a_restricted_key_file_and_reloads_it
    Dir.mktmpdir do |dir|
      path = File.join(dir, ".digest-key")
      CredAlignFlow::Fingerprint.reset!
      key = CredAlignFlow::Fingerprint.configure!(path)

      assert_match(/\A[0-9a-f]{64}\z/, key)
      assert_equal 0o600, File.stat(path).mode & 0o777

      CredAlignFlow::Fingerprint.reset!

      refute_predicate CredAlignFlow::Fingerprint, :configured?
      assert_equal key, CredAlignFlow::Fingerprint.configure!(path)
      assert_predicate CredAlignFlow::Fingerprint, :configured?
    end
  end

  def test_configure_fails_closed_on_missing_key_when_required
    Dir.mktmpdir do |dir|
      CredAlignFlow::Fingerprint.reset!
      error = assert_raises(CredAlignFlow::ConfigError) do
        CredAlignFlow::Fingerprint.configure!(File.join(dir, ".digest-key"), require_existing: true)
      end

      assert_includes error.message, "fingerprint key is missing"
    end
  end

  def test_malformed_permissive_and_symlinked_key_files_fail_closed
    Dir.mktmpdir do |dir|
      malformed = File.join(dir, "malformed")
      File.write(malformed, "not-hex-material")
      File.chmod(0o600, malformed)
      CredAlignFlow::Fingerprint.reset!
      error = assert_raises(CredAlignFlow::ConfigError) do
        CredAlignFlow::Fingerprint.configure!(malformed)
      end

      assert_includes error.message, "malformed"

      permissive = File.join(dir, "permissive")
      File.write(permissive, "a" * 64)
      File.chmod(0o644, permissive)
      CredAlignFlow::Fingerprint.reset!
      error = assert_raises(CredAlignFlow::ConfigError) do
        CredAlignFlow::Fingerprint.configure!(permissive)
      end

      assert_includes error.message, "too permissive"

      real = File.join(dir, "real")
      File.write(real, "b" * 64)
      File.chmod(0o600, real)
      link = File.join(dir, "link")
      File.symlink(real, link)
      CredAlignFlow::Fingerprint.reset!
      error = assert_raises(CredAlignFlow::ConfigError) do
        CredAlignFlow::Fingerprint.configure!(link)
      end

      assert_includes error.message, "symlink"
    end
  end

  def test_digest_fails_closed_without_a_configured_key
    CredAlignFlow::Fingerprint.reset!

    refute_predicate CredAlignFlow::Fingerprint, :configured?
    error = assert_raises(CredAlignFlow::ConfigError) do
      CredAlignFlow::Fingerprint.digest("SAMPLE_TOKEN", "value")
    end

    assert_includes error.message, "fingerprint key is not configured"
  end
end
