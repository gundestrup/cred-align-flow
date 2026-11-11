# cred-align-flow — development

Part of the [cred-align-flow](README.md) documentation.

## Provider design

Each source has a unique name, `type`, logical `host` or provider `url`/`api_url`, and provider-specific settings. A source ID represents one account/instance; the same adapter type may be configured multiple times. For GitHub, use the logical host (`github.com` or a GHES hostname); `api.github.com` is normalized to `github.com`. GitHub sources sharing a host need their own `auth_env` references to avoid using an ambiguous stored login. The single GitHub adapter maps GitHub.com/GitHub Enterprise Cloud hosts to `GH_TOKEN` and GHES hosts to `GH_ENTERPRISE_TOKEN`. Providers register under a source type through `CredAlignFlow::Providers`; every adapter subclasses `CredAlignFlow::Provider` and implements the small contract:

```text
CONTEXTS
repositories
repository(name)
secrets(repository, context)
set_secret(repository, context, name, value)
```

Shared contract tests in `test/provider_contract_test.rb` enumerate the provider registry, so a new adapter is tested automatically after registration. Registered source types are `github` and `forgejo`. The Forgejo adapter supports `repositories`, targeted `repository(name)` metadata reads, and `secrets` for the repository-level `actions` context. The `user` context is an owner-scope store (`OWNER_CONTEXTS`): it is write-only, never pulled into inventory, planned once per source under the `@owner` key, and gated behind the per-source `user_secrets: true` opt-in; `set_secret` pushes to `/user/actions/secrets` and raises `ProviderError` for repository contexts and non-opted sources. Adapters declare such contexts in `OWNER_CONTEXTS` (a subset of `CONTEXTS`); the planner, inventory, and UI treat them as blind, per-source writes with no remote drift signal. GitLab project/group variables fit the same model. Mercurial, Bazaar, and Perforce are version-control systems rather than repository-hosting secret APIs; they would only become valid source types if paired with a hosting service that exposes a compatible secret/variable API.

The single GitHub adapter uses `gh` for GitHub.com, GitHub Enterprise Server, and GitHub Enterprise Cloud. It routes by logical `host`, uses `GH_TOKEN` for GitHub.com and `*.ghe.com`, and `GH_ENTERPRISE_TOKEN` for GHES. Each source's `auth_env` is passed only for that source's commands, so multiple source IDs can use separate accounts. The official `octokit.rb` client supports the Actions and Dependabot secret endpoints, but secret writes still require the caller to encrypt values through RbNaCl/libsodium before passing `encrypted_value` and `key_id`; keeping `gh` avoids those runtime dependencies and preserves the project's standard-library-only policy.

## Development

Run the full quality gate on Ruby 3.4.10:

```bash
bundle exec rake check
```

The application version has one source of truth in `lib/cred_align_flow/version.rb`. Use the Rake task to bump it; patch increments `Z`, minor increments `Y` and resets `Z`, and major increments `X` and resets both lower components:

```bash
bundle exec rake 'version:bump[patch]'
bundle exec rake 'version:bump[minor]'
bundle exec rake 'version:bump[major]'
```

The bump task updates only the canonical version file so release notes remain human-written. `rake check` runs `version:check`, which requires the current version to have a dated changelog heading and matching GitHub release link. After editing the changelog, run the full gate, commit and push, wait for CI, then tag `vX.Y.Z` and create the GitHub release.

For focused local debugging, individual syntax/tests may also be run:

```bash
for file in lib/cred_align_flow.rb lib/cred_align_flow/*.rb lib/cred_align_flow/providers/*.rb bin/cred-align-flow; do ruby -c "$file"; done
for file in test/*_test.rb; do ruby -Ilib -Itest "$file"; done
```

The CLI runtime is Ruby-standard-library-only; tests use Minitest and the development tools in the `Gemfile`. They do not contact GitHub. `test/github_cli_test.rb` runs the CLI against a generated fake `gh` executable with isolated credentials and a socket guard. It covers command arguments, stdin-only value delivery, adoption, refresh/apply flow, and limits, but does not establish GitHub service-side compatibility. `test/forgejo_provider_test.rb` exercises the real HTTP adapter against a loopback `TCPServer`, not a Forgejo service. `test/config_server_test.rb` executes the embedded UI script in a Node VM for out-of-order poll/preview responses, in-flight saves, and CSRF retry; without Node.js it runs static ordering assertions instead, and CI sets `NODE_REQUIRED=1` so the dynamic paths always execute there. This is still not a full browser certification. `test/integration/forgejo_service_test.rb` (`bundle exec rake test:integration`, not part of `check`) runs the real adapter against the disposable Forgejo Compose service when `CRED_ALIGN_FLOW_FORGEJO_URL`/`CRED_ALIGN_FLOW_FORGEJO_TOKEN` point at a loopback service; GitHub writes are never part of automated tests.

### Demo screencasts

`docs/assets/demo/` holds the animated `cli-flow` and `ui-flow` demos
embedded in the READMEs. They are produced by the pure-Ruby CDP pipeline
in `scripts/e2e/` — no npm packages; Node is not needed. The pipeline
reuses the e2e fixture machinery (`test/support/fixtures.rb`: `FakeGh`,
`run_cli`), so the demos run the real binary and the real `ui` server
against a synthetic `demo-org` fixture; nothing contacts a provider and
no secret value ever reaches a frame.

```bash
# -> docs/assets/demo/cli-flow.mp4 + tmp/screencast-frames/cli/
ruby scripts/e2e/screencast_cli.rb
# -> docs/assets/demo/ui-flow.mp4 + tmp/screencast-frames/ui(-9fps)/
ruby scripts/e2e/screencast_ui.rb

ruby scripts/e2e/convert.rb tmp/screencast-frames/cli \
    --name cli-flow --fps 9 --scale 880
ruby scripts/e2e/convert.rb tmp/screencast-frames/ui-9fps \
    --name ui-flow --fps 9 --scale 880
```

Capture uses headless Chrome/Chromium (`CAF_DEMO_CHROME` or `CHROME_PATH`
overrides the lookup) driving `Page.startScreencast` over a hand-rolled
WebSocket; frames land as lossless PNGs under the gitignored
`tmp/screencast-frames/`. `recording.rb` resamples sparse repaint frames
at their real timestamps so static holds play at true duration.
`convert.rb` emits `.apng`, `.webp` (via `img2webp`), `.avif` (SVT-AV1,
CRF 35), and an `.svg` wrapper; `avifdec --info` verifies the sequence.
Tool requirements: Chrome, `ffmpeg`, `img2webp`, `webpinfo`, and `avifdec`
on the host. The scripts are development tooling only — none of it ships
in the CLI runtime and `rake check` does not run captures.
