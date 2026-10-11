# frozen_string_literal: true

require_relative "test_helper"
require "cred_align_flow/release_version"

class ReleaseVersionTest < Minitest::Test
  def test_bumps_patch_minor_and_major_levels
    assert_equal "0.0.2", CredAlignFlow::ReleaseVersion.bump("0.0.1", "patch")
    assert_equal "0.1.0", CredAlignFlow::ReleaseVersion.bump("0.0.1", "minor")
    assert_equal "1.0.0", CredAlignFlow::ReleaseVersion.bump("0.0.1", "major")
  end

  def test_rejects_invalid_version_and_bump_level
    assert_raises(ArgumentError) { CredAlignFlow::ReleaseVersion.bump("0.0", "patch") }
    assert_raises(ArgumentError) { CredAlignFlow::ReleaseVersion.bump("0.0.1", "prerelease") }
  end

  def test_bump_file_updates_only_the_canonical_version_assignment
    Dir.mktmpdir do |dir|
      path = File.join(dir, "version.rb")
      File.write(path, "# frozen_string_literal: true\n\nmodule CredAlignFlow\n  VERSION = \"0.0.1\"\nend\n")

      assert_equal "0.0.2", CredAlignFlow::ReleaseVersion.bump_file!(path, "patch")
      assert_includes File.read(path), "VERSION = \"0.0.2\""
    end
  end

  def test_consistency_requires_dated_changelog_heading_and_release_link
    Dir.mktmpdir do |dir|
      version_path = File.join(dir, "version.rb")
      changelog_path = File.join(dir, "CHANGELOG.md")
      File.write(version_path, "  VERSION = \"0.0.2\"\n")
      File.write(changelog_path, <<~MARKDOWN)
        ## [0.0.2] - 2026-10-11
        [0.0.2]: https://github.com/gundestrup/cred-align-flow/releases/tag/v0.0.2
      MARKDOWN

      assert_equal "0.0.2", CredAlignFlow::ReleaseVersion.check_consistency(
        version_path: version_path,
        changelog_path: changelog_path
      )
    end
  end
end
