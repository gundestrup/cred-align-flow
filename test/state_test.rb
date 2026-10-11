# frozen_string_literal: true

require_relative "test_helper"

class StateTest < Minitest::Test
  def test_state_is_metadata_only_and_private
    Dir.mktmpdir do |dir|
      path = File.join(dir, "nested", "inventory.json")
      state = CredAlignFlow::State.new(path)
      TestSupport.seed_source(
        state,
        "github-main",
        remote_secrets: {
          "example/repo" => { "actions" => { "SONAR_TOKEN" => { "updated_at" => "2026-01-01T00:00:00Z" } } }
        }
      )
      repo = state.repository("github-main", "example/repo")
      secret_value = "synthetic-state-secret-value"
      state.record_application("github-main", repo, "actions", "SONAR_TOKEN", "v1",
                               fingerprint: CredAlignFlow::Fingerprint.digest("SONAR_TOKEN", secret_value))
      state.save!

      data = JSON.parse(File.read(path))

      refute_includes File.read(path), secret_value
      assert_equal "4242", data.dig("sources", "github-main", "repositories", "example/repo", "id")
      assert_equal "2026-01-01T00:00:00Z",
                   data.dig("sources", "github-main", "repositories", "example/repo", "remote_secrets", "actions",
                            "SONAR_TOKEN", "updated_at")
      assert_equal "v1",
                   data.dig("applied", "github-main|id:4242|actions|SONAR_TOKEN", "version")
      assert_equal "100600", File.stat(path).mode.to_s(8)
    end
  end

  def test_applied_record_binds_to_stable_repository_id
    Dir.mktmpdir do |dir|
      state = CredAlignFlow::State.new(File.join(dir, "inventory.json"))
      repo = TestSupport.repository_metadata("id" => "111")
      state.record_application("github-main", repo, "actions", "SONAR_TOKEN", "v1")

      assert state.applied_record("github-main", repo, "actions", "SONAR_TOKEN")

      # A replacement repository reusing the name must not inherit the record.
      replacement = TestSupport.repository_metadata("id" => "222")

      assert_nil state.applied_record("github-main", replacement, "actions", "SONAR_TOKEN")
      assert_equal "id:111", state.repo_identity(repo)
      assert_equal "name:example/repo", state.repo_identity("example/repo")
    end
  end

  def test_concurrent_transactions_merge_independent_source_updates
    skip "process forking is unavailable" unless Process.respond_to?(:fork)

    Dir.mktmpdir do |dir|
      path = File.join(dir, "inventory.json")
      CredAlignFlow::State.new(path).save!
      children = 2.times.map do |index|
        fork do
          state = CredAlignFlow::State.new(path)
          state.transaction! do |snapshot|
            sleep 0.05
            snapshot.apply_refresh(
              "github-#{index}",
              repositories: {},
              contexts: [],
              selection: { "identity" => "test|#{index}" },
              discovered_at: Time.now.utc.iso8601
            )
          end
          exit! 0
        rescue StandardError
          exit! 1
        end
      end
      statuses = children.map { |pid| Process.wait2(pid).last }
      merged = CredAlignFlow::State.new(path)

      assert(statuses.all?(&:success?))
      assert_equal %w[github-0 github-1], merged.data.fetch("sources").keys.sort
    end
  end

  def test_save_is_atomic_and_survives_a_stale_writer
    Dir.mktmpdir do |dir|
      path = File.join(dir, "inventory.json")
      state = CredAlignFlow::State.new(path)
      TestSupport.seed_source(state, "github-main")
      state.save!
      first = File.read(path)

      # A writer holding a stale snapshot may not clobber newer state;
      # mutations must go through transaction!, which reloads under the lock.
      stale = CredAlignFlow::State.new(path)
      TestSupport.seed_source(state, "github-alt",
                              repositories: [TestSupport.repository_metadata("nameWithOwner" => "example/other")])
      state.save!
      assert_raises(CredAlignFlow::StateError) { stale.save! }

      merged = CredAlignFlow::State.new(path)

      assert_equal %w[github-alt github-main], merged.data["sources"].keys.sort
      refute_equal first, File.read(path)
    end
  end
end
