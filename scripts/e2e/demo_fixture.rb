# frozen_string_literal: true

# Shared demo fixture for the screencast scripts — reuses the e2e suite's
# own machinery (test/support/fixtures.rb: FakeGh, repository_metadata,
# run_cli) so the demos exercise exactly what the tests exercise: the real
# CLI binary, the real provider argv, and the real config UI server.
#
# Everything lands in a fresh tmpdir: the hand-edited YAML, the env file,
# the seeded preset libraries, the fake-gh state, and (after the
# inventory seed) the state file. Fictional names only — no real owner,
# repository, host, or value appears in the demo output.

require "fileutils"
require "json"
require "tmpdir"

require_relative "../../test/support/fixtures"

module DemoFixture
  OWNER = "demo-org"
  # One shared demo value: FakeGh asserts every pushed secret equals its
  # FAKE_GH_EXPECTED_SECRET, and identical values keep the fixture simple.
  SECRET_VALUE = "demo-rotated-2026-11"

  REPOSITORIES = [
    { "name" => "alpha-web", "isPrivate" => false, "isArchived" => false, "isFork" => false },
    { "name" => "beta-api", "isPrivate" => false, "isArchived" => false, "isFork" => false },
    { "name" => "gamma-docs", "isPrivate" => true, "isArchived" => false, "isFork" => false },
    { "name" => "legacy-mirror", "isPrivate" => false, "isArchived" => true, "isFork" => false },
    { "name" => "forked-template", "isPrivate" => false, "isArchived" => false, "isFork" => true }
  ].freeze

  # Six tokens; the three DEPLOY_* names share a prefix so the Tokens tab
  # shows its grouped-fold layout.
  TOKENS = [
    { "name" => "SONAR_TOKEN", "contexts" => %w[actions dependabot] },
    { "name" => "SEMGREP_APP_TOKEN", "contexts" => %w[actions dependabot] },
    { "name" => "NPM_PUBLISH_TOKEN", "contexts" => %w[actions] },
    { "name" => "DEPLOY_HOST", "contexts" => %w[actions] },
    { "name" => "DEPLOY_SSH_KEY", "contexts" => %w[actions] },
    { "name" => "DEPLOY_TARGET", "contexts" => %w[actions] }
  ].freeze

  # Remote secrets present before the demo starts: one managed token
  # already on the remote (unverified_present) and one remote-only
  # secret (unexpected) so the plan shows every status family.
  REMOTE_SECRETS = {
    "#{OWNER}/beta-api|actions" => [
      { "name" => "SONAR_TOKEN", "updatedAt" => "2026-09-14T08:30:00Z" },
      { "name" => "LEGACY_DEPLOY_KEY", "updatedAt" => "2025-11-02T10:12:00Z" }
    ],
    "#{OWNER}/alpha-web|dependabot" => [
      { "name" => "SONAR_TOKEN", "updatedAt" => "2026-09-14T08:31:00Z" }
    ]
  }.freeze

  Fixture = Struct.new(:dir, :fake_gh, :config_path, :env_path, :state_path)

  module_function

  def repository_metadata(repo, index)
    TestSupport.repository_metadata(
      "id" => (7000 + index).to_s,
      "name" => repo["name"],
      "nameWithOwner" => "#{OWNER}/#{repo['name']}",
      "visibility" => repo["isPrivate"] ? "PRIVATE" : "PUBLIC",
      "isPrivate" => repo["isPrivate"],
      "isArchived" => repo["isArchived"],
      "isFork" => repo["isFork"]
    )
  end

  def token_yaml(token)
    contexts = token["contexts"].map { |context| "        - #{context}" }.join("\n")
    <<~YAML
        - name: #{token['name']}
          value_env: #{token['name']}_VALUE
          version: "2026-11-01"
          version_at: "2026-11-01T09:00:00Z"
          visibility: public
          sources:
            - github-demo
          targets:
            github:
      #{contexts}
    YAML
  end

  def config_yaml
    tokens = TOKENS.map { |token| token_yaml(token) }
    <<~YAML
      version: 1
      check_for_updates: false
      state_file: inventory.json
      env_file: secrets.env

      ignored_env_names:
        - LOCAL_HELPER_VAR

      sources:
        github-demo:
          type: github
          owner: #{OWNER}
          host: github.com
          auth_env: GITHUB_SYNC_TOKEN
          repositories:
            visibility: public
            include_archived: false
            include_forks: false

      secrets:
      #{tokens.join}
    YAML
  end

  # Writes the demo fixture into dir and returns the Fixture struct.
  def build(dir = Dir.mktmpdir("caf-demo-"))
    config_path = File.join(dir, "cred-align.local.yml")
    env_path = File.join(dir, "secrets.env")
    state_path = File.join(dir, "inventory.json")
    File.write(config_path, config_yaml)
    File.write(env_path, env_lines.join("\n"))
    FileUtils.chmod(0o600, env_path)
    write_presets(dir)

    fake_gh = TestSupport::FakeGh.new(
      dir,
      repositories: REPOSITORIES.map.with_index { |repo, index| repository_metadata(repo, index) },
      secrets: REMOTE_SECRETS,
      expected_secret: SECRET_VALUE
    )
    Fixture.new(dir, fake_gh, config_path, env_path, state_path)
  end

  # One token preset + one repo preset so the Presets tab and the
  # repo-card "Apply preset" controls have content.
  def write_presets(dir)
    File.write(
      File.join(dir, "cred-align.presets-tokens.json"),
      JSON.pretty_generate(
        "presets" => {
          "ci-readonly" => { "visibility" => "public", "targets" => { "github" => %w[actions] } }
        }
      )
    )
    File.write(
      File.join(dir, "cred-align.presets-repos.json"),
      JSON.pretty_generate(
        "presets" => { "sonar-only" => { "SONAR_TOKEN" => "include", "*" => "exclude" } }
      )
    )
  end

  def env_lines
    [
      "GITHUB_SYNC_TOKEN=demo-gh-token-not-real",
      *TOKENS.map { |token| "#{token['name']}_VALUE=#{SECRET_VALUE}" },
      "LOCAL_HELPER_VAR=not-a-ci-secret",
      ""
    ]
  end

  # Environment for the real `cred-align-flow ui` subprocess: the fake-gh
  # variables plus the ambient shell — the ui command execs `bundle exec
  # itsi`, so bundler lookup needs the real PATH and HOME.
  def ui_env(fixture)
    fixture.fake_gh.environment.merge(
      "PATH" => "#{fixture.fake_gh.bin_dir}:#{ENV.fetch('PATH', '')}",
      "HOME" => ENV.fetch("HOME", fixture.dir)
    )
  end

  # Seeds the state file through the real `inventory` command — the same
  # refresh the tests and the UI button exercise.
  def seed_inventory(fixture)
    stdout, stderr, status = TestSupport.run_cli(
      fixture.fake_gh, "--config", fixture.config_path, "inventory"
    )
    raise "demo inventory failed: #{stderr}#{stdout}" unless status.success?

    stdout
  end
end
