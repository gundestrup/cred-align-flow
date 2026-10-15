# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

class ConfigServerTest < Minitest::Test
  class FakeReleaseChecker
    attr_reader :requests

    def initialize(version)
      @version = version
      @requests = []
    end

    def newer_version(current_version:, minimum_age_days:)
      @requests << [current_version, minimum_age_days]
      @version
    end
  end

  def test_local_ui_uses_csrf_protection_and_never_serves_values
    with_rack_app do |app, config_path|
      page_status, page_headers, page_body = call(app, "GET", "/")
      token = page_body.join.match(/name="cred-align-csrf" content="([a-f0-9]+)"/)&.captures&.first
      data_status, _data_headers, data_body = call(app, "GET", "/api/data")
      data = JSON.parse(data_body.join)

      assert_equal 200, page_status
      assert_equal "text/html; charset=utf-8", page_headers.fetch("Content-Type")
      csp = page_headers.fetch("Content-Security-Policy")

      assert_includes csp, "default-src 'none'"
      assert_includes csp, "script-src 'self'"
      assert_includes csp, "style-src 'self'"
      refute_includes csp, "nonce"
      assert_includes page_body.join, "Cancel changes"
      assert_includes page_body.join, 'src="/ui.js"'
      assert_includes page_body.join, 'href="/ui.css"'

      css_status, css_headers, css_body = call(app, "GET", "/ui.css")
      js_status, js_headers, js_body = call(app, "GET", "/ui.js")

      assert_equal 200, css_status
      assert_equal "text/css; charset=utf-8", css_headers.fetch("Content-Type")
      assert_includes css_body.join, ":root"
      assert_equal 200, js_status
      assert_equal "text/javascript; charset=utf-8", js_headers.fetch("Content-Type")
      assert_includes js_body.join, "cred-align-csrf"
      %w[repositories tokens presets].each do |tab|
        assert_includes page_body.join, "id=\"tab-#{tab}\""
        assert_includes page_body.join, "for=\"tab-#{tab}\""
        assert_includes page_body.join, "data-panel=\"#{tab}\""
      end
      assert_equal 200, data_status
      refute data.fetch("check_for_updates")
      assert_equal({}, data.fetch("rules"))
      assert_equal({}, data.fetch("token_presets"))
      assert_equal({}, data.fetch("repo_presets"))
      assert_equal(
        { "repos" => "presets-repos.json", "tokens" => "presets-tokens.json" },
        data.fetch("preset_files").sort.to_h
      )
      refute_includes data_body.join, "very-secret-value-should-not-appear"
      refute_nil token

      payload = JSON.generate(
        "revision" => data.fetch("revision"),
        "rules" => { "github-main" => { "example/repo" => { "SAMPLE_TOKEN" => "include" } } },
        "token_defaults" => {},
        "token_presets" => {},
        "repo_presets" => {}
      )
      config_before = File.read(config_path)
      missing_token = call(app, "POST", "/api/preview", body: payload, origin: "http://127.0.0.1:8043")
      invalid_origin = call(
        app,
        "POST",
        "/api/preview",
        body: payload,
        origin: "http://example.com",
        token: token
      )

      assert_equal 403, missing_token.first
      assert_equal 403, invalid_origin.first

      preview = call(app, "POST", "/api/preview", body: payload, origin: "http://127.0.0.1:8043", token: token)

      assert_equal 200, preview.first
      assert_equal config_before, File.read(config_path)

      save = call(app, "POST", "/api/save", body: payload, origin: "http://127.0.0.1:8043", token: token)

      assert_equal 200, save.first
      assert_equal config_before, File.read(config_path)
      rules_path = CredAlignFlow::Rules.default_path_for(config_path)

      assert_equal "include", JSON.parse(File.read(rules_path)).dig("rules", "github-main", "example/repo", "SAMPLE_TOKEN")
    end
  end

  def test_release_check_endpoint_is_inert_when_disabled
    with_rack_app do |app, _config_path, checker|
      status, _headers, body = call(app, "GET", "/api/update")

      assert_equal 200, status
      assert_nil JSON.parse(body.join).fetch("update_version")
      assert_empty checker.requests
    end
  end

  def test_release_check_endpoint_returns_a_newer_version_when_enabled
    with_rack_app(check_for_updates: true) do |app, _config_path, checker|
      status, _headers, body = call(app, "GET", "/api/update")

      assert_equal 200, status
      assert_equal "v0.0.2", JSON.parse(body.join).fetch("update_version")
      assert_equal [[CredAlignFlow::VERSION, 7]], checker.requests
    end
  end

  def test_release_check_endpoint_uses_configured_minimum_age
    with_rack_app(check_for_updates: true, update_notice_min_age_days: 3) do |app, _config_path, checker|
      status, _headers, body = call(app, "GET", "/api/update")

      assert_equal 200, status
      assert_equal "v0.0.2", JSON.parse(body.join).fetch("update_version")
      assert_equal [[CredAlignFlow::VERSION, 3]], checker.requests
    end
  end

  def test_ui_skips_release_check_when_disabled
    stdout = run_ui_scenario(<<~JAVASCRIPT) { |script| assert_update_check_opt_in(script) }
      (async () => {
        pending[0](response("initial"));
        await new Promise((resolve) => setImmediate(resolve));
        process.stdout.write(requests.join(","));
      })().catch((error) => { console.error(error); process.exit(1); });
    JAVASCRIPT

    assert_equal "/api/data", stdout if stdout
  end

  def test_ui_shows_newer_release_when_update_check_is_enabled
    stdout = run_ui_scenario(<<~JAVASCRIPT) { |script| assert_update_check_opt_in(script) }
      (async () => {
        pending[0](response("initial", true));
        await new Promise((resolve) => setImmediate(resolve));
        if (requests.join(",") !== "/api/data,/api/update") throw new Error(`unexpected requests: ${requests}`);
        pending[1]({ ok: true, status: 200, json: async () => ({ update_version: "v0.0.2" }) });
        await new Promise((resolve) => setImmediate(resolve));
        const indicator = elements.get("update-indicator");
        if (indicator.hidden) throw new Error("release indicator stayed hidden");
        process.stdout.write(JSON.stringify({ version: elements.get("update-version").textContent, href: indicator.href }));
      })().catch((error) => { console.error(error); process.exit(1); });
    JAVASCRIPT

    result = JSON.parse(stdout) if stdout
    assert_equal "v0.0.2", result.fetch("version") if result
    assert_includes result.fetch("href"), "/releases/tag/v0.0.2" if result
  end

  def test_ui_ignores_an_older_poll_response_that_arrives_late
    stdout = run_ui_scenario(<<~JAVASCRIPT) { |script| assert_poll_sequence_guard(script) }
      (async () => {
        pending[0](response("initial"));
        await new Promise((resolve) => setImmediate(resolve));
        const olderPoll = sandbox.poll();
        const newerPoll = sandbox.poll();
        pending[2](response("newer"));
        await newerPoll;
        pending[1](response("older"));
        await olderPoll;
        process.stdout.write(elements.get("config-file").textContent);
      })().catch((error) => { console.error(error); process.exit(1); });
    JAVASCRIPT

    assert_includes stdout, "Config newer.yml" if stdout
  end

  def test_ui_keeps_edits_made_while_a_save_is_in_flight
    stdout = run_ui_scenario(<<~JAVASCRIPT) { |script| assert_save_preserves_newer_draft(script) }
      (async () => {
        pending[0](response("initial"));
        await new Promise((resolve) => setImmediate(resolve));
        const repo = { name: "example/repo", rule_sources: {}, legacy_exclusions: {} };
        sandbox.changeRepositoryRule("src", repo, "FIRST_TOKEN", "include");
        const save = elements.get("save")._handlers.click();
        // While the save request is in flight, the user edits again.
        sandbox.changeRepositoryRule("src", repo, "SECOND_TOKEN", "exclude");
        // Polling must not start another request while a save runs.
        sandbox.poll();
        if (pending.length !== 2) throw new Error(`poll issued a fetch during save (pending=${pending.length})`);
        const saved = view("saved");
        saved.rules = { src: { "example/repo": { FIRST_TOKEN: "include" } } };
        pending[1]({ ok: true, status: 200, json: async () => saved });
        await save;
        if (!sandbox.isDirty()) throw new Error("in-flight edit was discarded by the save response");
        process.stdout.write(elements.get("message").textContent);
      })().catch((error) => { console.error(error); process.exit(1); });
    JAVASCRIPT

    assert_includes stdout, "newer edits are kept" if stdout
  end

  def test_ui_ignores_an_older_preview_response_that_arrives_late
    stdout = run_ui_scenario(<<~JAVASCRIPT) { |script| assert_preview_sequence_guard(script) }
      (async () => {
        pending[0](response("initial"));
        await new Promise((resolve) => setImmediate(resolve));
        sandbox.markChanged();
        const older = sandbox.previewDraft(1);
        sandbox.markChanged();
        const newer = sandbox.previewDraft(2);
        pending[2]({ ok: true, status: 200, json: async () => view("newer") });
        await newer;
        pending[1]({ ok: true, status: 200, json: async () => view("stale") });
        await older;
        process.stdout.write(elements.get("config-file").textContent);
      })().catch((error) => { console.error(error); process.exit(1); });
    JAVASCRIPT

    assert_includes stdout, "Config newer.yml" if stdout
  end

  def test_ui_retries_mutations_with_a_fresh_csrf_token_after_restart
    stdout = run_ui_scenario(<<~JAVASCRIPT) { |script| assert_csrf_retry_path(script) }
      (async () => {
        pending[0](response("initial"));
        await new Promise((resolve) => setImmediate(resolve));
        const repo = { name: "example/repo", rule_sources: {}, legacy_exclusions: {} };
        sandbox.changeRepositoryRule("src", repo, "FIRST_TOKEN", "include");
        const save = elements.get("save")._handlers.click();
        // The server restarted: the token embedded in the page is stale.
        pending[1]({ ok: false, status: 403, json: async () => ({ error: "forbidden" }) });
        await new Promise((resolve) => setImmediate(resolve));
        // refreshCsrfToken fetches /api/data for a new token, then retries.
        if (pending.length < 3) throw new Error("no CSRF refresh request was issued");
        pending[2]({ ok: true, status: 200, json: async () => ({ csrf: "fresh-token" }) });
        await new Promise((resolve) => setImmediate(resolve));
        if (pending.length < 4) throw new Error("the mutation was not retried with the fresh token");
        pending[3]({ ok: true, status: 200, json: async () => view("saved") });
        await save;
        process.stdout.write(elements.get("message").textContent);
      })().catch((error) => { console.error(error); process.exit(1); });
    JAVASCRIPT

    assert_includes stdout, "Saved locally" if stdout
  end

  def test_ui_repo_preset_stamps_rules_with_catchall_and_lock_handling
    stdout = run_ui_scenario(<<~JAVASCRIPT) { |script| assert_repo_preset_stamping(script) }
      (async () => {
        const initial = view("initial");
        initial.secrets = [
          { config: { name: "A_TOKEN" } },
          { config: { name: "B_TOKEN" } },
          { config: { name: "C_TOKEN" } },
          { config: { name: "D_TOKEN" } },
          { config: { name: "E_TOKEN" } }
        ];
        initial.repo_presets = {
          lockdown: { A_TOKEN: "include", C_TOKEN: "default", D_TOKEN: "default", E_TOKEN: "exclude", "*": "exclude" }
        };
        pending[0]({ ok: true, status: 200, json: async () => initial });
        await new Promise((resolve) => setImmediate(resolve));
        const repo = {
          name: "example/repo",
          rule_sources: { C_TOKEN: "yaml" },
          legacy_exclusions: {},
          locked_sources: { E_TOKEN: true }
        };
        sandbox.applyRepoPreset("src", repo, "lockdown");
        const save = elements.get("save")._handlers.click();
        pending[1]({ ok: true, status: 200, json: async () => view("saved") });
        await save;
        const body = bodies[requests.indexOf("/api/save")];
        process.stdout.write(JSON.stringify(body.rules));
      })().catch((error) => { console.error(error); process.exit(1); });
    JAVASCRIPT

    skip unless stdout

    assert_equal(
      { "src" => { "example/repo" => { "A_TOKEN" => "include", "B_TOKEN" => "exclude", "C_TOKEN" => "default" } } },
      JSON.parse(stdout)
    )
  end

  def test_ui_repo_presets_accumulate_across_applications
    stdout = run_ui_scenario(<<~JAVASCRIPT)
      (async () => {
        const initial = view("initial");
        initial.secrets = [
          { config: { name: "A_TOKEN" } },
          { config: { name: "B_TOKEN" } },
          { config: { name: "C_TOKEN" } }
        ];
        initial.repo_presets = {
          first: { A_TOKEN: "include" },
          second: { B_TOKEN: "exclude", C_TOKEN: "include" }
        };
        pending[0]({ ok: true, status: 200, json: async () => initial });
        await new Promise((resolve) => setImmediate(resolve));
        const repo = { name: "example/repo", rule_modes: {}, rule_sources: {}, legacy_exclusions: {}, locked_sources: {} };
        // The second preset must not undo what the first stamped.
        sandbox.applyRepoPreset("src", repo, "first");
        sandbox.applyRepoPreset("src", repo, "second");
        const save = elements.get("save")._handlers.click();
        pending[1]({ ok: true, status: 200, json: async () => view("saved") });
        await save;
        process.stdout.write(JSON.stringify(bodies[requests.indexOf("/api/save")].rules));
      })().catch((error) => { console.error(error); process.exit(1); });
    JAVASCRIPT

    skip unless stdout

    assert_equal(
      { "src" => { "example/repo" => { "A_TOKEN" => "include", "B_TOKEN" => "exclude", "C_TOKEN" => "include" } } },
      JSON.parse(stdout)
    )
  end

  def test_ui_repo_preset_holds_conflicts_and_applies_safe_entries
    stdout = run_ui_scenario(<<~JAVASCRIPT)
      (async () => {
        const initial = view("initial");
        initial.secrets = [
          { config: { name: "A_TOKEN" } },
          { config: { name: "B_TOKEN" } },
          { config: { name: "C_TOKEN" } }
        ];
        initial.rules = { src: { "example/repo": { A_TOKEN: "include", B_TOKEN: "exclude" } } };
        initial.repo_presets = { tighten: { A_TOKEN: "exclude", B_TOKEN: "exclude", C_TOKEN: "include" } };
        pending[0]({ ok: true, status: 200, json: async () => initial });
        await new Promise((resolve) => setImmediate(resolve));
        const repo = {
          name: "example/repo",
          rule_modes: { A_TOKEN: "include", B_TOKEN: "exclude" },
          rule_sources: { A_TOKEN: "rules", B_TOKEN: "rules" },
          legacy_exclusions: {},
          locked_sources: {}
        };
        // A_TOKEN conflicts (include vs exclude); B_TOKEN already
        // matches; C_TOKEN has no rule and applies safely.
        sandbox.applyRepoPreset("src", repo, "tighten");
        const held = elements.get("message").textContent;
        const firstSave = elements.get("save")._handlers.click();
        const savedOnce = view("saved");
        savedOnce.secrets = initial.secrets;
        savedOnce.repo_presets = initial.repo_presets;
        savedOnce.rules = { src: { "example/repo": { A_TOKEN: "include", B_TOKEN: "exclude", C_TOKEN: "include" } } };
        pending[1]({ ok: true, status: 200, json: async () => savedOnce });
        await firstSave;
        const safeOnly = bodies[requests.lastIndexOf("/api/save")].rules;
        // Force apply overwrites the conflicting entry.
        sandbox.applyRepoPreset("src", repo, "tighten", true);
        const secondSave = elements.get("save")._handlers.click();
        pending[2]({ ok: true, status: 200, json: async () => view("saved-again") });
        await secondSave;
        const forced = bodies[requests.lastIndexOf("/api/save")].rules;
        process.stdout.write(JSON.stringify({ held: held, safeOnly: safeOnly, forced: forced }));
      })().catch((error) => { console.error(error); process.exit(1); });
    JAVASCRIPT

    skip unless stdout

    result = JSON.parse(stdout)

    assert_includes result.fetch("held"), "A_TOKEN"
    assert_equal(
      { "src" => { "example/repo" => { "A_TOKEN" => "include", "B_TOKEN" => "exclude", "C_TOKEN" => "include" } } },
      result.fetch("safeOnly")
    )
    assert_equal(
      { "src" => { "example/repo" => { "A_TOKEN" => "exclude", "B_TOKEN" => "exclude", "C_TOKEN" => "include" } } },
      result.fetch("forced")
    )
  end

  def test_ui_clear_repo_rules_removes_saved_rules_and_neutralizes_yaml
    stdout = run_ui_scenario(<<~JAVASCRIPT)
      (async () => {
        const initial = view("initial");
        initial.secrets = [
          { config: { name: "A_TOKEN" } },
          { config: { name: "B_TOKEN" } },
          { config: { name: "C_TOKEN" } },
          { config: { name: "D_TOKEN" } }
        ];
        initial.rules = { src: { "example/repo": { A_TOKEN: "include", B_TOKEN: "exclude" } } };
        pending[0]({ ok: true, status: 200, json: async () => initial });
        await new Promise((resolve) => setImmediate(resolve));
        const repo = {
          name: "example/repo",
          rule_modes: { A_TOKEN: "include", B_TOKEN: "exclude", C_TOKEN: "include" },
          rule_sources: { A_TOKEN: "rules", B_TOKEN: "rules", C_TOKEN: "yaml" },
          legacy_exclusions: {},
          locked_sources: { D_TOKEN: true }
        };
        sandbox.clearRepoRules("src", repo);
        const save = elements.get("save")._handlers.click();
        pending[1]({ ok: true, status: 200, json: async () => view("saved") });
        await save;
        const body = bodies[requests.indexOf("/api/save")];
        process.stdout.write(JSON.stringify(body.rules));
      })().catch((error) => { console.error(error); process.exit(1); });
    JAVASCRIPT

    skip unless stdout

    # Saved rules are deleted outright; the YAML rule needs an explicit
    # "default" to cancel it; the locked token is untouched.
    assert_equal(
      { "src" => { "example/repo" => { "C_TOKEN" => "default" } } },
      JSON.parse(stdout)
    )
  end

  def test_ui_clear_token_rules_spans_repositories
    stdout = run_ui_scenario(<<~JAVASCRIPT)
      (async () => {
        const initial = view("initial");
        initial.secrets = [{ config: { name: "A_TOKEN" } }, { config: { name: "B_TOKEN" } }];
        initial.rules = {
          src: { "example/one": { A_TOKEN: "include", B_TOKEN: "include" }, "example/two": { A_TOKEN: "include" } }
        };
        const repoFixture = (name) => ({
          name: name, anchor: name, visibility: "public", selected: true, admin: true,
          rule_modes: {}, rule_sources: { A_TOKEN: "rules", B_TOKEN: "rules" },
          legacy_exclusions: {}, locked_sources: {}, crosses_scope: {},
          assigned: [], not_assigned: [], unexpected: []
        });
        initial.sources = [{ id: "src", repositories: [repoFixture("example/one"), repoFixture("example/two")] }];
        pending[0]({ ok: true, status: 200, json: async () => initial });
        await new Promise((resolve) => setImmediate(resolve));
        sandbox.clearTokenRules("A_TOKEN");
        const save = elements.get("save")._handlers.click();
        pending[1]({ ok: true, status: 200, json: async () => view("saved") });
        await save;
        process.stdout.write(JSON.stringify(bodies[requests.indexOf("/api/save")].rules));
      })().catch((error) => { console.error(error); process.exit(1); });
    JAVASCRIPT

    skip unless stdout

    assert_equal(
      { "src" => { "example/one" => { "B_TOKEN" => "include" } } },
      JSON.parse(stdout)
    )
  end

  def test_ui_groups_tokens_by_shared_prefix_when_three_or_more
    stdout = run_ui_scenario(<<~JAVASCRIPT)
      (async () => {
        const units = sandbox.groupedTokens([
          { config: { name: "SONAR_TOKEN" } },
          { config: { name: "GH_TOKEN" } },
          { config: { name: "AWS_SECRET" } },
          { config: { name: "GH_USER" } },
          { config: { name: "AWS_KEY" } },
          { config: { name: "PLAIN" } },
          { config: { name: "AWS_REGION" } }
        ]);
        process.stdout.write(JSON.stringify(units.map((unit) => [unit.title, unit.entries.map((e) => e.config.name)])));
      })().catch((error) => { console.error(error); process.exit(1); });
    JAVASCRIPT

    skip unless stdout

    assert_equal(
      [
        ["AWS", %w[AWS_KEY AWS_REGION AWS_SECRET]],
        [nil, ["GH_TOKEN"]],
        [nil, ["GH_USER"]],
        [nil, ["PLAIN"]],
        [nil, ["SONAR_TOKEN"]]
      ],
      JSON.parse(stdout)
    )
  end

  def test_ui_lock_rejects_a_second_instance
    Dir.mktmpdir do |dir|
      editor = Struct.new(:config_path).new(File.join(dir, "config.yml"))
      held = CredAlignFlow::ConfigServer.new(editor: editor, port: 8043).send(:claim_ui_lock)
      other = CredAlignFlow::ConfigServer.new(editor: editor, port: 8043)

      error = assert_raises(CredAlignFlow::ConfigError) { other.send(:claim_ui_lock) }

      assert_includes error.message, "already holds"
      assert_includes error.message, "ui --stop"
      held.close
    end
  end

  def test_ui_stop_without_lock_fails_cleanly
    Dir.mktmpdir do |dir|
      editor = Struct.new(:config_path).new(File.join(dir, "config.yml"))
      server = CredAlignFlow::ConfigServer.new(editor: editor, port: 8043)

      error = assert_raises(CredAlignFlow::ConfigError) { server.stop }

      assert_includes error.message, "no config UI lock"
    end
  end

  def test_ui_stop_removes_stale_lock_for_a_non_ui_process
    Dir.mktmpdir do |dir|
      editor = Struct.new(:config_path).new(File.join(dir, "config.yml"))
      lock_path = File.join(dir, ".ui.lock")
      File.write(lock_path, Process.pid.to_s) # the test runner is not an itsi process
      server = CredAlignFlow::ConfigServer.new(editor: editor, port: 8043)

      error = assert_raises(CredAlignFlow::ConfigError) { server.stop }

      assert_includes error.message, "stale lock"
      refute_path_exists lock_path
    end
  end

  def test_rack_app_rejects_untrusted_host_and_remote_addresses
    with_rack_app do |app, _config_path|
      bad_host = call(app, "GET", "/api/data", host: "attacker.example:8043")
      remote_address = call(app, "GET", "/api/data", remote_address: "192.0.2.4")

      assert_equal 403, bad_host.first
      assert_equal 403, remote_address.first
    end
  end

  def test_ui_port_is_validated
    ["eighty", 0, 70_000, -1].each do |port|
      assert_raises(CredAlignFlow::ConfigError) do
        CredAlignFlow::ConfigServer.new(editor: nil, port: port)
      end
    end
  end

  def test_rack_app_maps_request_and_editor_errors_to_status_codes
    with_rack_app do |app, config_path, _checker|
      _status, _headers, data_body = call(app, "GET", "/api/data")
      view = JSON.parse(data_body.join)
      token = view.fetch("csrf")
      origin = "http://127.0.0.1:8043"

      status, _h, body = call(app, "GET", "/no-such-endpoint")

      assert_equal 404, status
      assert_includes body.join, "not found"

      status, _h, body = call(app, "POST", "/api/save", origin: origin, body: "{}")

      assert_equal 403, status
      assert_includes body.join, "request token"

      status, _h, body = call(app, "POST", "/api/save", origin: "https://attacker.example",
                                                        token: token, body: "{}")

      assert_equal 403, status
      assert_includes body.join, "must originate"

      status, _h, body = call(app, "POST", "/api/save", origin: origin, token: token,
                                                        content_type: "text/plain", body: "{}")

      assert_equal 400, status
      assert_includes body.join, "application/json"

      status, _h, body = call(app, "POST", "/api/save", origin: origin, token: token, body: "{ nope")

      assert_equal 400, status
      assert_includes body.join, "invalid request body"

      status, _h, body = call(
        app, "POST", "/api/save", origin: origin, token: token,
                                  content_length: (CredAlignFlow::ConfigRackApp::MAX_BODY_BYTES + 1).to_s, body: "{}"
      )

      assert_equal 413, status
      assert_includes body.join, "too large"

      status, _h, _body = call(app, "POST", "/api/save", origin: origin, token: token,
                                                         body: JSON.generate("revision" => "x", "rules" => {}))

      assert_equal 422, status

      # A rules file written after the view was loaded conflicts.
      rules_path = CredAlignFlow::Rules.default_path_for(config_path)
      File.write(rules_path, JSON.generate("version" => 1, "rules" => {}))
      save_payload = {
        "revision" => view.fetch("revision"),
        "rules" => {}, "token_defaults" => {}, "token_presets" => {}, "repo_presets" => {}
      }
      status, _h, _body = call(app, "POST", "/api/save", origin: origin, token: token,
                                                         body: JSON.generate(save_payload))

      assert_equal 409, status
    end
  end

  def test_rack_app_maps_provider_and_unexpected_failures
    [
      [CredAlignFlow::ProviderError.new("synthetic provider failure"), 422, "inventory refresh failed"],
      [RuntimeError.new("synthetic crash"), 500, "request failed"]
    ].each do |error, expected_status, expected_detail|
      provider = Class.new do
        define_method(:contexts) { %w[actions] }
        define_method(:owner_scoped_context?) { |_context| false }
        define_method(:validate_context!) { |_context| true }
        define_method(:repositories) { raise error }
      end.new
      with_rack_app(providers: { "github-main" => provider }) do |app, _config_path, _checker|
        _status, _h, data_body = call(app, "GET", "/api/data")
        view = JSON.parse(data_body.join)
        status, _h, body = call(
          app, "POST", "/api/inventory", origin: "http://127.0.0.1:8043",
                                         token: view.fetch("csrf"), body: JSON.generate("revision" => view.fetch("revision"))
        )

        assert_equal expected_status, status
        assert_includes body.join, expected_detail
      end
    end
  end

  private

  # Runs the page's real embedded script inside a Node `vm` sandbox with a
  # deferred-promise fetch queue, then executes the scenario JavaScript.
  # When Node.js is missing the shared static fallbacks still assert the
  # ordering guards exist in the source; NODE_REQUIRED=1 (CI) turns the
  # missing runtime into a failure instead of a static-only check.
  def run_ui_scenario(scenario)
    browser_script = extract_browser_script
    harness = <<~JAVASCRIPT
      const vm = require("vm");
      const pending = [];
      const requests = [];
      const bodies = [];
      const elements = new Map();
      const node = () => ({
        textContent: "", value: "", className: "", disabled: false, hidden: true, style: {},
        _handlers: {},
        classList: { add() {}, remove() {}, toggle() {}, contains() { return false; } },
        append() {}, replaceChildren() {}, setAttribute() {},
        addEventListener(type, fn) { this._handlers[type] = fn; }
      });
      const document = {
        getElementById(id) {
          if (!elements.has(id)) elements.set(id, node());
          return elements.get(id);
        },
        createElement() { return node(); },
        createTextNode(text) { return { textContent: String(text) }; },
        querySelector() { return { content: "test-csrf" }; },
        addEventListener() {},
        hidden: false
      };
      const window = { confirm() { return true; } };
      const sandbox = {
        document,
        window,
        fetch(path, options) {
          requests.push(path);
          bodies.push(options && options.body ? JSON.parse(options.body) : null);
          return new Promise((resolve) => pending.push(resolve));
        },
        setInterval(callback) { sandbox.poll = callback; return 1; },
        setTimeout() { return 1; },
        clearTimeout() {}
      };
      vm.runInNewContext(#{browser_script.to_json}, sandbox);
      const view = (name, checkForUpdates = false) => ({
        csrf: "test-csrf", config_file: `${name}.yml`, rules_file: "rules.json",
        revision: name, display_revision: name, generated_at: null, rules: {},
        token_defaults: {}, token_presets: {}, repo_presets: {},
        check_for_updates: checkForUpdates,
        secrets: [], sources: [], orphan_rules: [], unimported_env_names: [],
        ignored_env_names: [], action_summary: {}, provider_contexts: {},
        meta: { statuses: ["ok", "create"], status_help: {}, value_pills: {},
                field_help: [{ term: "T", text: "uses `code` spans" }] }
      });
      const response = (name, checkForUpdates = false) => ({
        ok: true,
        status: 200,
        json: async () => view(name, checkForUpdates)
      });
      #{scenario}
    JAVASCRIPT
    stdout, stderr, status = Open3.capture3("node", "-e", harness)

    assert_predicate status, :success?, stderr
    stdout
  rescue Errno::ENOENT
    raise "Node.js is required for the UI async-ordering tests (NODE_REQUIRED=1)" if ENV["NODE_REQUIRED"] == "1"

    yield browser_script
    nil
  end

  def extract_browser_script
    File.read(File.expand_path("../lib/cred_align_flow/config_ui.js", __dir__), encoding: "UTF-8")
  end

  def assert_update_check_opt_in(script)
    check = script[/async function checkForUpdate\(\) \{.*?\n    \}/m]

    assert(check)
    assert_includes check, "!view.check_for_updates"
    assert_includes check, "fetch(\"/api/update\""
  end

  def assert_poll_sequence_guard(script)
    poll = script[/async function pollData\(\) \{.*?\n    \}/m]

    assert(poll)
    assert_operator poll.index("const sequence = ++issuedSequence"), :<, poll.index("await fetch")
  end

  def assert_save_preserves_newer_draft(script)
    save = script[/async function saveChanges\(\) \{.*?\n    \}/m]

    assert(save)
    assert_includes save, "copy(draft)"
    assert_includes save, "applyRules: false"
    assert_match(/JSON\.stringify\(draft\)\s*={2,3}\s*JSON\.stringify\(submitted\)/, save)
  end

  def assert_preview_sequence_guard(script)
    preview = script[/async function previewDraft\(sequence\) \{.*?\n    \}/m]

    assert(preview)
    assert_includes preview, "sequence !== previewSequence"
  end

  def assert_csrf_retry_path(script)
    post = script[/async function post\(path, body\) \{.*?\n    \}/m]

    assert(post)
    assert_match(/status === 403/, post)
    assert_includes post, "refreshCsrfToken"
    assert_includes post, "return post(path, body)"
  end

  def assert_repo_preset_stamping(script)
    apply = script[/function applyRepoPreset\(sourceId, repo, presetName, force\) \{.*?\n    \}/m]

    assert(apply)
    assert_includes apply, 'fields["*"]'
    assert_includes apply, "locked_sources"
  end

  def call(app, method, path, body: nil, origin: nil, token: nil, host: "127.0.0.1:8043",
           remote_address: "127.0.0.1", content_type: nil, content_length: nil)
    app.call(
      "REQUEST_METHOD" => method,
      "PATH_INFO" => path,
      "QUERY_STRING" => "",
      "SERVER_NAME" => "127.0.0.1",
      "SERVER_PORT" => "8043",
      "REMOTE_ADDR" => remote_address,
      "HTTP_HOST" => host,
      "HTTP_ORIGIN" => origin,
      "HTTP_X_CRED_ALIGN_TOKEN" => token,
      "CONTENT_TYPE" => content_type || (body ? "application/json" : ""),
      "CONTENT_LENGTH" => content_length || (body ? body.bytesize.to_s : "0"),
      "rack.input" => StringIO.new(body.to_s)
    )
  end

  def with_rack_app(check_for_updates: false, update_notice_min_age_days: nil, providers: {})
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.yml")
      env_path = File.join(dir, ".env.local")
      state_path = File.join(dir, "inventory.json")
      config = {
        "version" => 1,
        "state_file" => state_path,
        "sources" => {
          "github-main" => { "type" => "github", "owner" => "example" }
        },
        "secrets" => [{ "name" => "SAMPLE_TOKEN", "value_env" => "SAMPLE_TOKEN_VALUE" }]
      }
      config["check_for_updates"] = true if check_for_updates
      config["update_notice_min_age_days"] = update_notice_min_age_days unless update_notice_min_age_days.nil?
      File.write(config_path, YAML.dump(config))
      File.write(env_path, "SAMPLE_TOKEN_VALUE=very-secret-value-should-not-appear\n")
      editor = CredAlignFlow::ConfigEditor.new(
        config_path: config_path,
        env_path: env_path,
        state_path: state_path,
        providers: providers
      )
      checker = FakeReleaseChecker.new("v0.0.2")
      app = CredAlignFlow::ConfigRackApp.new(editor: editor, port: 8043, release_checker: checker)
      yield app, config_path, checker
    end
  end
end
