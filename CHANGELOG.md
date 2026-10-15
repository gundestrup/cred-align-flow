# Changelog

All notable changes to `cred-align-flow` are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-10-15

### Added

- The config UI can now edit a token's default scope (`visibility`,
  `sources`, `targets`, `exclude_repositories`). Edits are written to the
  rules file as `token_defaults` overrides merged over the YAML entry —
  the hand-edited YAML config stays untouched, and token identity
  (`name`, `value_env`, digests, versions, `exclude_sources`,
  `repository_rules`) remains YAML-only.
- Named presets in two UI-managed library files derived from the rules
  file path (`*.presets-tokens.json` and `*.presets-repos.json`, or
  `presets-tokens.json`/`presets-repos.json` for a `rules.json`). Token
  presets are scope templates the UI stamps into `token_defaults`; repo
  presets are `token → include|exclude|default` bundles with a `*`
  catch-all that the UI stamps onto a repository's `rules` entries.
  Presets are inert — `plan`/`apply`/`check` never read the preset
  files; stamping copies values into the rules file. The preset files
  are gitignored like the rules file.
- Rules file schema `version: 2`. Files without `token_defaults` are
  still written as `version: 1`, so they stay readable by older builds;
  version 2 files fail closed on older builds instead of silently
  ignoring overrides that change the plan.
- `cred-align-flow ui --stop` stops a running local UI, and the server
  now holds a `.ui.lock` beside the config file so a second `ui` start
  fails fast instead of stacking listeners on the port.
- GitHub `agents` and `codespaces` secret stores join `actions` and
  `dependabot` as selectable target contexts. `agents` (the Copilot
  cloud agent store) requires a recent `gh` and does not exist on GHES.
- Repo presets now **merge** into a repository's rules instead of
  replacing them, so presets accumulate. An entry that would change an
  existing non-default rule is held as a conflict — the safe entries
  still apply, the repo card lists the held entries in an error, and a
  "Force apply" button overwrites them on retry.
- "Clear rules" buttons: per repository (clears every token rule on
  that repo) and per token card (clears the token's rules on every
  repository and source). YAML rules and repository exclusions are
  cancelled with an explicit `default`; `exclude_sources` locks are
  untouched.
- Built-in token presets provided by the adapters — e.g. *"GitHub:
  Actions + Dependabot"*, *"GitHub: all contexts"*, and the Forgejo
  pair — appear alongside the file-based presets in the config UI. They
  are read-only, stamp scope fields like any preset, and are shadowed
  by a custom preset of the same name.
- `scaffold_action:` top-level config option controls what `scaffold`
  does with unimported env names when no `--target` is given:
  `default` keeps list-only behaviour, `import` writes commented
  `# scaffold-draft:` blocks that stay inactive until uncommented, and
  `auto` writes minimal active entries — identity fields only — so the
  token defaults apply and scope is managed via the UI or by hand.
  `import` drafts and explicit `--target` imports render the full field
  set: every adapter-supported context is enumerated (unselected ones
  commented), and optional scope fields appear as comments to enable,
  delete, or change. The config UI's unimported-env notice reflects the
  configured action.
- Forgejo `user` target context: account-level secrets pushed blindly
  to `/user/actions/secrets`. The Forgejo API cannot list user secrets,
  so owner-scope targets never appear in inventory, carry no remote
  drift status, and plan solely from the applied journal. Writes
  require the per-source opt-in `user_secrets: true`; targeting `user`
  without it fails config validation. There is no user-scope delete.
- `test/consistency_test.rb` guards against option drift: every config
  key list must appear in `config.example.yml` and `README.config.md`,
  the generated scaffold must enumerate every adapter context and scope
  field, and the UI/editor/help plus CLI and usage docs must cover every
  editable field, rule action, and `scaffold_action` mode. Schema enums
  (`VISIBILITIES`, `SCAFFOLD_ACTIONS`, `FORGEJO_OWNER_TYPES`) are now
  `Config` constants so tests and validators share them.
- Coverage-hardening tests for the write path and validation surfaces:
  apply race guards (remote secrets disappearing or changing between
  plan and write, repository/source identity changes during a write,
  provider write failures, pull-only and write-time count-limit skips),
  the provider contract's malformed-adapter branches, fingerprint
  key-file fail-closed paths, GitHub source/argument validation before
  `gh` is invoked, the UI's HTTP error mapping, and the repository
  view's not-assigned and unexpected-remote rows.

### Changed

- The config UI is organized into three sections — Repositories, Tokens,
  and Presets — switched by pure CSS (`:has()` over hidden radio inputs,
  no script or URL state). Token cards sort alphabetically, group under
  a `PREFIX` heading when three or more share a `PREFIX_` prefix, and
  fold out the repositories each token is enabled on; repository cards
  fold their not-assigned token lists.
- The UI page assets moved out of the HTML template into `config_ui.css`
  and `config_ui.js`, served as same-origin files. The CSP switched from
  per-request nonces to `script-src 'self'`/`style-src 'self'` — no
  inline code is permitted at all — and the page carries its CSRF token
  in a meta tag.
- The UI save/preview payload now carries `rules`, `token_defaults`,
  `token_presets`, and `repo_presets` together; every save revalidates
  the merged configuration and the preset files' references.

## [0.0.4] - 2026-10-13

### Changed

- Documentation split for manageability: `README.md` is now a short landing
  page with a quick start and per-command summaries linking to the topic
  files — warnings/security model in `README.safety.md`, setup and the YAML
  configuration reference in `README.config.md`, the command reference, plan
  statuses, and rotation in `README.usage.md`, the local config UI in
  `README.ui.md`, and provider design plus the development workflow in
  `README.devel.md`.
- Development Ruby pin bumped to 3.4.11; the declared floor remains 3.4.10.
- RuboCop 1.92.0.
- CI pins: `ruby/setup-ruby` v1.329.0, `codecov/codecov-action` v7.1.1
  (node24-runner releases; input set unchanged), Semgrep CE 1.180.0.

## [0.0.3] - 2026-10-11

Patch release completing the opt-in update checker with a configurable
release-age threshold and daily result caching. Update checking remains
disabled unless `check_for_updates: true`.

### Added

- `update_notice_min_age_days` configuration (default `7`; `0` means
  immediate notices). Only published, non-draft numeric releases whose
  GitHub `published_at` is at least that old produce an update notice.

### Changed

- The opted-in release check caches its result — including no-update and
  error results — for 24 hours per running UI process, keyed by the current
  version and configured age threshold.

## [0.0.2] - 2026-10-11

Patch release. The CLI remains provider-safe by default; the new UI release
indicator is explicitly opt-in, and automated checks still use offline/fake
services rather than writing to production providers.

### Added

- An opt-in local UI update indicator, enabled only by `check_for_updates: true`.
  With the default/omitted setting there are no release-check requests; an
  enabled check contacts only this project's public GitHub releases endpoint.
- `bundle exec rake version:bump[patch|minor|major]` and a version/changelog
  consistency check wired into `rake check`.

### Changed

- CLI apply/plan, scaffold, and doctor workflows are split into focused methods;
  option registration, filtering, and force-aware actionability share policies.
- Planner and applier use one strict ISO8601 timestamp parser. Legacy local
  apply-time fallback remains for missing provider timestamps, while malformed
  provider timestamps fail closed.

### Fixed

- A malformed `applied_remote_at` can no longer fall back to a local timestamp
  and be mistaken for a trustworthy provider baseline.
- CLI option scanning now shares value-argument advancement, preserving option
  values that happen to look like commands or global flags.

## [0.0.1] - 2026-10-11

First public alpha release. The CLI is functional and covered by an offline
test suite, but no adapter has been certified against live GitHub or Forgejo
services — review every printed plan before approving a write.

### Added

- Provider-agnostic CLI (`bin/cred-align-flow`, standard-library-only Ruby
  3.4.10+ runtime) for synchronizing CI secrets and repository variables with
  inventory- and metadata-based drift detection.
- GitHub adapter driving the `gh` CLI for GitHub.com, GitHub Enterprise Cloud,
  and GitHub Enterprise Server Actions and Dependabot repository secrets, with
  per-source `auth_env` account isolation.
- Forgejo adapter (pull-only): repository discovery and Actions secret
  metadata reads; remote writes are disabled.
- Commands: `doctor`, `inventory`/`pull`, `plan`/`diff`, `check`, `apply`
  (interactive plan confirmation or noninteractive `--yes`, `--dry-run`,
  `--force`, and `--source`/`--repo`/`--secret`/`--context` filters),
  `scaffold` (`--only`/`--target`/`--ignore`/`--digests-only`), `ui`, `help`.
- Local configuration in YAML plus a strict-grammar dotenv value file; XDG
  defaults; `state_file`/`rules_file`/`env_file` paths resolve relative to the
  config file.
- HMAC-SHA256 value fingerprints keyed by an auto-generated private
  `.digest-key`; the CLI fails closed when keyed digests exist and the key is
  missing. Legacy `sha256:` digests remain readable.
- Inventory snapshots enforcing a 24-hour freshness limit plus
  source/selection/context coverage, truncation, and identity guards before
  `plan`/`check`/`apply` may run.
- Drift baselines recorded from the provider's own `updated_at`
  (`applied_remote_at`) so detection is immune to local clock skew; missing or
  invalid baselines are treated conservatively as `remote_newer`.
- Local configuration UI (Itsi, development-only dependency) that writes only
  per-repository token rules to `*.rules.json`, with CSRF checks, stale-save
  rejection, and HMAC-protected display-revision polling.
- Safety defaults: secret values are never printed, logged, or stored in the
  inventory; unknown remote secrets are report-only; writes are atomic; a
  pre-write remote recheck runs before every mutation.
- Offline test suite (Minitest fakes, loopback servers, Node VM UI scenarios),
  RuboCop, bundler-audit, flay/flog reports, Semgrep CE rules, and an env-gated
  disposable-Forgejo integration test.
- AGPL-3.0-only license and `DISCLAIMER.md`.

[0.1.0]: https://github.com/gundestrup/cred-align-flow/releases/tag/v0.1.0
[0.0.4]: https://github.com/gundestrup/cred-align-flow/releases/tag/v0.0.4
[0.0.3]: https://github.com/gundestrup/cred-align-flow/releases/tag/v0.0.3
[0.0.2]: https://github.com/gundestrup/cred-align-flow/releases/tag/v0.0.2
[0.0.1]: https://github.com/gundestrup/cred-align-flow/releases/tag/v0.0.1
