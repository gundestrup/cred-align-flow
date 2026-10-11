# frozen_string_literal: true

module CredAlignFlow
  module ReleaseVersion
    VERSION_LINE = /^  VERSION = "([^"]+)"$/
    VERSION_PATTERN = /\A(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\z/

    module_function

    def bump(version, part)
      components = version.to_s.match(VERSION_PATTERN)
      raise ArgumentError, "current version must be numeric X.Y.Z" unless components

      major, minor, patch = components.captures.map(&:to_i)
      case part
      when "patch"
        patch += 1
      when "minor"
        minor += 1
        patch = 0
      when "major"
        major += 1
        minor = 0
        patch = 0
      else
        raise ArgumentError, "version bump must be patch, minor, or major"
      end
      [major, minor, patch].join(".")
    end

    def current(path)
      matches = File.readlines(path, chomp: true).filter_map do |line|
        VERSION_LINE.match(line)&.captures&.first
      end
      raise ArgumentError, "expected exactly one VERSION assignment in #{path}" unless matches.length == 1
      raise ArgumentError, "VERSION must be numeric X.Y.Z" unless VERSION_PATTERN.match?(matches.first)

      matches.first
    end

    def bump_file!(path, part)
      content = File.read(path)
      current_version = current(path)
      next_version = bump(current_version, part)
      replacement = "  VERSION = \"#{next_version}\""
      updated = content.sub(VERSION_LINE, replacement)
      raise ArgumentError, "could not replace VERSION in #{path}" if updated == content

      File.write(path, updated)
      next_version
    end

    def check_consistency(version_path:, changelog_path:)
      version = current(version_path)
      changelog = File.read(changelog_path)
      escaped = Regexp.escape(version)
      heading = /^## \[#{escaped}\] - \d{4}-\d{2}-\d{2}$/
      reference = %r{^\[#{escaped}\]: https://github\.com/gundestrup/cred-align-flow/releases/tag/v#{escaped}$}
      has_heading = changelog.lines.any? { |line| heading.match?(line.chomp) }
      has_reference = changelog.lines.any? { |line| reference.match?(line.chomp) }
      raise ArgumentError, "CHANGELOG.md is missing a dated heading for #{version}" unless has_heading
      raise ArgumentError, "CHANGELOG.md is missing the GitHub release reference for #{version}" unless has_reference

      version
    end
  end
end
