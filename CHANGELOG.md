# Changelog

All notable changes to `cred-align-flow` are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.1] - 2026-10-31

### Changed

- Development Ruby pin bumped to 3.4.12 (`.ruby-version`, CI matrix,
  `Gemfile.lock`); the declared floor remains 3.4.10. `ruby/setup-ruby`
  bumped to v1.336.0.
- CI and development dependencies refreshed to latest: `semgrep`
  1.180.0 → 1.183.0, `sonarqube-scan-action` v8.3.0 → v8.4.0,
  `rubocop` 1.92.0 → 1.92.2, `parser` 3.3.12.0 → 3.3.13.0,
  `rack` 3.2.7 → 3.2.8, and Bundler 4.0.21 → 4.0.23. `json` and
  `prism` stay on their current majors, capped by `itsi-server`,
  `flay`, `minitest`, and `rubocop-ast`.
- The CI `sonar` job is restored — Automatic Analysis is disabled for
  the project on sonarcloud.io, so CI-based scanning carries the
  analysis (and the RuboCop/SimpleCov report imports it supports, which
  Automatic Analysis cannot). `sonar-project.properties` again
  documents keeping Automatic Analysis off; the scan step still
  self-skips while `SONAR_TOKEN` is absent.

### Fixed

- The SonarCloud quality gate turns green again on new code. The first
  CI-scanner analysis exposed two coverage defects: CLI subprocess
  fixtures ran uninstrumented because the stripped test environment
  dropped the bundler/gem lookup variables, leaving `require "simplecov"`
  to fail silently under `bundler-cache` — the variables now pass through
  when SimpleCov is loaded; and `config_ui.js` counted 856 executable
  lines at 0% even though the Node-VM suite exercises it — it is now in
  `sonar.coverage.exclusions`, keeping its issue/duplication analysis
  without demanding JS coverage tooling the project does not have.

## [0.2.0] - 2026-10-15

### Added

- A `delete` repository rule (per-repo rule dropdown in the config UI,
  `repository_rules` in YAML, and repo presets all accept it) that stops
  syncing a token on that repository and marks any existing remote
  secret for removal. Marks surface as `delete` plan items — never as
  `unexpected`, never touched by `apply` — and the new `prune` command
  walks them: it refreshes the inventory like `apply`, prints every
  marked remote still present, then asks for one keypress per item
  (`y` deletes, `n` skips, `c` or any other key including EOF stops the
  run); noninteractive use must pass `--yes`. Deletion needs no local
  secret value, re-verifies repository/source identity and remote
  presence against the live provider before removing, and clears the
  applied journal entry so a deleted secret cannot masquerade as a live
  application. Provider capability decides what is deletable: GitHub
  contexts via `gh secret delete` and Forgejo repository `actions`
  secrets via the API are deletable (pull-only refers to value writes),
  while Forgejo's write-only `user` scope reports the mark as
  undeletable. Secrets that merely stop being configured stay
  report-only `unexpected` — deletion always requires an explicit mark.

### Changed

- Rules-file entries that reference tokens or sources removed from the
  YAML config no longer fail the load — they are inert (a deleted token
  can never appear in a plan), so commands warn on stderr and carry on.
  The config UI reports them in the orphan notice with their reason and
  drops them from the draft on the next save, so a manually edited
  config cannot wedge `scaffold`, `plan`, or the UI behind a rules-file
  cleanup. The same treatment now applies to preset-library entries that
  name removed tokens (repo presets) or sources (token presets):
  previously every `/api/preview` and `/api/save` returned 422, leaving
  draft changes — like Clear repository rules — looking applied but
  unsavable. Reference validation stays strict on save: a draft naming
  an unknown token or source is still rejected.
- Bulk `scaffold` imports (`scaffold_action: import`/`auto`, or `--only`
  without `--target`) now warn and skip env names that can never be
  valid managed secrets — invalid charset, over 100 characters, or the
  reserved `GITHUB_` prefix — instead of aborting the whole batch on the
  first unimportable name. The default list-only output annotates such
  names, the config UI lists them separately under "Cannot be
  imported", and explicit `--target` imports of an invalid name still
  fail.
- The CI `sonar` job is removed: the project now uses SonarCloud
  Automatic Analysis, which conflicts with CI-based scanning.
  `sonar-project.properties` remains for manual/local scanner runs —
  Automatic Analysis does not import the external RuboCop/SimpleCov
  reports, so the SonarCloud coverage badge stops updating (Codecov
  coverage is unaffected).
- `scaffold_action: auto` now writes minimal **inactive** entries:
  identity fields plus an explicit empty `targets` list per configured
  provider type, so imported tokens are assigned nowhere and plan/apply
  nothing until scope is granted through the config UI
  (`token_defaults`, presets, or repository rules — the overlay wins
  over the empty YAML targets). Previously auto-imported tokens were
  live on all sources with each provider's implicit context, which
  pushed secrets to every selected repository by default. The scope
  editor's Targets field now notes when no context is selected
  ("enables nothing until at least one is checked") so an inactive
  token or preset is readable at a glance.

### Fixed

- The config UI no longer dies with `Cannot read properties of
  undefined (reading 'revision')` when the YAML config fails to load
  (e.g. a syntax error): action buttons surface the real load error and
  skip the request while the page is viewless, and the poll loop keeps
  retrying so the page recovers automatically once the config parses.
- Saving now stays enabled while dead orphan rules exist on disk —
  previously a clean draft disabled Save entirely, leaving no way to
  trigger the cleanup write that drops them.
- The status message now lives inside the sticky actions bar, so
  validation errors and action confirmations stay visible while
  scrolled to a token or repository far down the page — previously an
  invalid draft disabled Save with the reason rendered off-screen.
- The scope editor no longer offers owner-scope target checkboxes
  (e.g. `forgejo: user`) the draft could never satisfy: when the
  applicable sources of that provider type lack the account-scope
  opt-in (`user_secrets: true`), the box is disabled and names the
  sources that need it, instead of letting the preview reject the
  draft after the fact. Tokens targeting only account scope now say so
  in the assignment list rather than "Not assigned to any repository".
- The config UI's API now echoes 4xx/5xx request errors to stderr
  (`[config-ui] POST /api/preview -> 422: …`) so a stuck draft can be
  diagnosed from the terminal that launched `ui` — previously the
  error text only existed inside the HTTP response.
- Secret value, provider auth, and fingerprint-key resolution now read
  an injectable `CredAlignFlow.environment` (identical to `ENV` at
  runtime) which the in-process test suite replaces with an empty map —
  previously an ambient credential variable, like the `SONAR_TOKEN`
  exported to the SonarCloud CI job, leaked into test fixtures as a
  real secret value.

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

[0.2.1]: https://github.com/gundestrup/cred-align-flow/releases/tag/v0.2.1
[0.2.0]: https://github.com/gundestrup/cred-align-flow/releases/tag/v0.2.0
[0.1.0]: https://github.com/gundestrup/cred-align-flow/releases/tag/v0.1.0
[0.0.4]: https://github.com/gundestrup/cred-align-flow/releases/tag/v0.0.4
[0.0.3]: https://github.com/gundestrup/cred-align-flow/releases/tag/v0.0.3
[0.0.2]: https://github.com/gundestrup/cred-align-flow/releases/tag/v0.0.2
[0.0.1]: https://github.com/gundestrup/cred-align-flow/releases/tag/v0.0.1
