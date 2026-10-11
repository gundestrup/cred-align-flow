# Changelog

All notable changes to `cred-align-flow` are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.0.1]: https://github.com/gundestrup/cred-align-flow/releases/tag/v0.0.1
