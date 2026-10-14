# AGENTS.md — cred-align-flow

## Project scope

`cred-align-flow` is a provider-agnostic CLI for synchronizing CI secrets and repository variables, with inventory and metadata-based drift detection. The current providers are GitHub Actions/Dependabot secrets through `gh` and pull-only Forgejo Actions secrets through the Forgejo API.

## Security rules

- Never commit secret values or fingerprint key files such as `.digest-key`; keep the key private and back it up securely beside the env file.
- Never commit private repository names or generated inventory/state.
- Local values belong in `config/secrets.env`, `.env.local`, or `~/.config/cred-align-flow/secrets.env` (or an `env_file:` path set in the config).
- Local configuration belongs in `config/cred-align.local.yml`, `cred-align.local.yml`, or `~/.config/cred-align-flow/config.yml`. The `config/` directory is gitignored and holds every local file — config, `secrets.env`, rules, and optionally the inventory — so it can be backed up or bind-mounted (e.g. into Docker) as one unit. The YAML file is hand-edited only; the config UI never writes it.
- UI-authored state belongs in `*.rules.json` next to the config file (or `rules_file:`; a config named `config.yml` derives `rules.json`): per-repository token overrides (`rules`) and per-token default-scope overrides (`token_defaults`, limited to `visibility`/`sources`/`targets`/`exclude_repositories`). The UI also writes the sibling preset libraries derived from the rules file name (`<stem>.presets-tokens.json`/`<stem>.presets-repos.json`, or `presets-*.json` for `rules.json`): stamp-only templates — token presets stamp scope fields into `token_defaults`, repo presets stamp `token → rule` bundles (with a `*` catch-all) into `rules`. These files are the only things the config UI writes; `plan`/`apply`/`check` load only the rules file via `Config`, which merges `token_defaults` into the effective secret entries. Token identity (`name`, `value_env`, digests, versions, `exclude_sources`, `repository_rules`) stays YAML-only.
- Inventory belongs in `~/.local/state/cred-align-flow/inventory.json` or an explicitly ignored local path such as `config/inventory.json` (relative `state_file` resolves against the config file's directory).
- Do not print secret values in output, tests, logs, or error messages.
- Unknown remote secrets are report-only; do not add deletion behavior by default.
- Remote writes belong behind the explicit `apply` command; interactive runs confirm the printed plan, noninteractive runs require `--yes`, and changed local plan inputs must abort before writes.
- Scaffolded secrets are active only for explicit `--only` names and exact `--target SOURCE|CONTEXT|OWNER/REPO` tuples. Never restore account-wide import defaults.
- Inventory older than 24 hours, incomplete, identity-unknown, or truncated must not drive a plan/apply.
- Adapter write paths may be exercised offline with a fake local command/API double only when the test isolates credentials and blocks network access; this does not count as a remote provider write. Tests that actually write a provider must target only disposable Docker-managed services, never production repositories or github.com.

## Coding conventions

- Ruby 3.4.10+ (`.ruby-version` pins the development Ruby; the CI matrix covers the declared floor).
- The CLI runtime uses only the Ruby standard library — no runtime dependencies. Development/test tools (Minitest, RuboCop, flay, bundler-audit) are managed through the `Gemfile` development/test group and run via `bundle exec`. The optional local config UI uses Itsi from the development group; ordinary CLI commands do not load it.
- All Ruby files use frozen string literals.
- Use double-quoted Ruby strings.
- Prefer explicit errors and safe defaults.
- Pin GitHub Actions to full 40-character commit SHAs with version comments.

## Validation

```bash
bundle install
bundle exec rake check
```

`rake check` runs version/changelog consistency, tests, RuboCop, bundler-audit, non-blocking flay/flog reports, and Semgrep CE (which self-skips when the binary is absent; rules live in `.semgrep.yml`). `rake flay` prints the structural duplication report on its own — it is informational, not a quality gate. `rake test:integration` runs the env-gated disposable-service tests under `test/integration/` and is deliberately outside `check` — it skips cleanly without `CRED_ALIGN_FLOW_FORGEJO_URL`/`CRED_ALIGN_FLOW_FORGEJO_TOKEN` pointing at a loopback service.

The tests must not contact GitHub or require real credentials. See `test/integration/README.md` before adding any pull or push integration test. `test/config_server_test.rb` runs the embedded UI script in a Node VM when Node.js is present (CI sets `NODE_REQUIRED=1`) and falls back to static ordering assertions without it.

## Release process

- `lib/cred_align_flow/version.rb` is the single source of truth for the application version. Use `bundle exec rake 'version:bump[patch]'`, `bundle exec rake 'version:bump[minor]'`, or `bundle exec rake 'version:bump[major]'`; the task updates only this file. Keep the dated release heading and GitHub release link in `CHANGELOG.md` in sync; `version:check` is part of `rake check`.
- This CLI app has no gemspec and is not published to RubyGems. Release tags use `vX.Y.Z`; create a GitHub Release object for each shipped version.
- Run the full gate after updating the version and changelog. Commit the complete release tree, push `main`, verify `origin/main` and its CI run, then tag and push the tag and create the GitHub Release. The tag must point at the checked, pushed commit; do not force-move a published tag.
- UI release checks are opt-in only (`check_for_updates: true`). The missing/default setting must cause zero outbound release-check requests. When enabled, notifications wait until the release's `published_at` is at least `update_notice_min_age_days` old (default 7; 0 means immediate); the checker caches each current-version/age setting for 24 hours per UI process. Tests use a loopback API double and the Node VM; never call GitHub from the test suite.
