# cred-align-flow

[![CI](https://github.com/gundestrup/cred-align-flow/actions/workflows/ci.yml/badge.svg)](https://github.com/gundestrup/cred-align-flow/actions/workflows/ci.yml)
[![Quality Gate](https://sonarcloud.io/api/project_badges/measure?project=gundestrup_cred-align-flow&metric=alert_status)](https://sonarcloud.io/summary/new_code?id=gundestrup_cred-align-flow)
[![Coverage](https://sonarcloud.io/api/project_badges/measure?project=gundestrup_cred-align-flow&metric=coverage)](https://sonarcloud.io/summary/new_code?id=gundestrup_cred-align-flow)
[![codecov](https://codecov.io/gh/gundestrup/cred-align-flow/graph/badge.svg)](https://codecov.io/gh/gundestrup/cred-align-flow)
[![CodeFactor](https://www.codefactor.io/repository/github/gundestrup/cred-align-flow/badge)](https://www.codefactor.io/repository/github/gundestrup/cred-align-flow)
[![DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/gundestrup/cred-align-flow)
[![Ruby >= 3.4.10](https://img.shields.io/badge/ruby-%3E%3D_3.4.10-cc342d?logo=ruby&logoColor=white)](https://www.ruby-lang.org/)
[![License: AGPL-3.0-only](https://img.shields.io/badge/license-AGPL--3.0--only-blue.svg)](LICENSE)
[![Semgrep CE](https://img.shields.io/badge/security-Semgrep%20CE-informational)](.semgrep.yml)

Provider-agnostic secret and CI variable synchronization with drift detection across repository hosting platforms.

The current implementation supports GitHub Actions/Dependabot repository secrets and pull-only Forgejo Actions secrets. The internal source/target model is intended to support GitLab CI variables and additional Forgejo/Gitea operations later.

## Warnings

**Use this tool at your own risk.** It is provided as-is, without warranty of any kind; the authors and contributors are not liable for data loss, broken CI/CD pipelines, leaked credentials, or any other damage resulting from its use or misuse. See [DISCLAIMER.md](DISCLAIMER.md) for the full standard disclaimer and the license disclaimer below.

Before relying on it, understand what it cannot undo:

- **Remote writes are irreversible.** Providers do not reveal existing secret values, so an overwritten secret cannot be rolled back — the old value is unrecoverable from the API. A wrong or stale value pushed by `apply` breaks whatever consumes that secret until you fix it manually at the provider.
- **`--force` overwrites secrets the tool did not apply.** `unverified_present` and `remote_newer` exist precisely because the remote may hold a value set by someone else. Only use `--force` after reviewing the refreshed plan and confirming you own the remote value; prefer narrow `--repo`/`--secret`/`--context` filters.
- **Non-interactive `--yes` skips the human review step.** It approves whatever plan is generated at that moment. Do not wire `apply --yes` into unattended automation until you have run several reviewed interactive applies.
- **Try it on a disposable repository first.** Create a throwaway repo and secret, run `inventory`, `plan`, `apply --dry-run`, and one real `apply` there before pointing the tool at repositories that matter.
- **Back up your local data before and between runs.** Keep copies of the whole config directory — `cred-align.local.yml`, `secrets.env`, `.digest-key`, `inventory.json`, and `cred-align.rules.json`. Losing `.digest-key` makes recorded fingerprints incomparable: the CLI fails closed when keyed digests already exist rather than silently regenerating, and otherwise every applied target looks changed. Losing `inventory.json` discards the applied baseline and forces `--force` adoption review.
- **The tool is not certified.** The test suite uses fakes, loopback servers, and a Node VM — not a real browser, and no automated write ever touches github.com. Provider API behavior, timestamp precision, and rate limits are tested against fixtures, not the live services.
- **No compare-and-swap exists.** If someone else changes a remote secret between the plan and the write, the last write wins. The pre-write recheck narrows but does not eliminate that race.
- **Guard the env file and `.digest-key`.** Anyone who obtains both can compute the same fingerprints as your installation; anyone with your `gh` credentials can write secrets as you.

## Security model

`cred-align-flow` is designed so that the repository can remain public while operational data remains local:

- Secret values are read from an ignored env file (`config/secrets.env`, `.env.local`, or the XDG path) or process environment variables.
- The private `.digest-key` beside the env file is also ignored; never commit it, and back it up securely with the env file.
- Secret values are never printed, logged, or written to the inventory.
- Configuration lives in an ignored `config/` directory, flat ignored root files, or outside the repository at `~/.config/cred-align-flow/config.yml`.
- Inventory defaults to `~/.local/state/cred-align-flow/inventory.json`; set `state_file: inventory.json` to keep it inside `config/` — relative paths resolve against the config file's directory.
- Repository exclusions and private repository names belong in the local config, not committed files.
- Remote secrets that are not managed by the configuration are report-only.
- `plan` and `check` do not change remote secrets.
- Existing secrets are not overwritten during initial adoption unless `apply --force` is used.

GitHub does not expose existing secret values. The tool can therefore report missing names, unexpected names, target mismatches, timestamps, and locally recorded versions, but it cannot prove that an existing GitHub secret contains the expected value.

## Requirements

- Ruby 3.4.10 or newer
- GitHub CLI (`gh`) installed and authenticated
- A GitHub token or `gh` login with permission to administer the selected repositories

## Local setup

Copy the examples into an ignored `config/` directory (keeps every local file in one place — handy for backups or a Docker bind mount):

```bash
mkdir -m 700 config
cp config.example.yml config/cred-align.local.yml
cp secrets.env.example config/secrets.env
chmod 600 config/cred-align.local.yml config/secrets.env
```

On the first CLI/UI run without `CRED_ALIGN_FLOW_FINGERPRINT_KEY`, the program creates a private `.digest-key` beside the resolved env file. Keep it out of version control and back it up securely alongside that file; if keyed digests exist and the key is missing, the CLI refuses to generate a replacement because that would make every applied fingerprint look different.

Edit `config/cred-align.local.yml` for the source owner, repository selection, secret names, target contexts, and version labels. Edit `config/secrets.env` for the actual values. Set `state_file: inventory.json` in the config to keep the inventory inside the same directory — relative `state_file`/`rules_file` paths resolve against the config file's directory.

Flat files at the repository root work too (`cred-align.local.yml` + `.env.local`), as do files outside the repository:

```text
~/.config/cred-align-flow/config.yml
~/.config/cred-align-flow/secrets.env
~/.local/state/cred-align-flow/inventory.json
```

Explicit paths are also supported:

```bash
bin/cred-align-flow plan --config /private/path/config.yml --env-file /private/path/secrets.env
```

## Configuration

```yaml
version: 1
check_for_updates: false
update_notice_min_age_days: 7
# All three file paths are optional; relative values resolve against
# this file's directory. Defaults: XDG inventory, derived rules file,
# env-file discovery (.env.local -> config/.env.local -> config/secrets.env
# -> ~/.config/cred-align-flow/secrets.env).
state_file: ~/.local/state/cred-align-flow/inventory.json
# rules_file: cred-align.rules.json
# env_file: secrets.env

sources:
  github-main:
    type: github
    owner: your-github-owner
    host: github.com
    auth_env: GITHUB_SYNC_TOKEN
    repositories:
      visibility: public
      include_archived: false
      include_forks: false
      include: []
      exclude: []

  forgejo-main:
    type: forgejo
    owner: your-forgejo-owner
    owner_type: user # or organization
    url: https://forgejo.example
    auth_env: FORGEJO_TOKEN
    repositories:
      visibility: public
      include_archived: false
      include_forks: false

secrets:
  - name: SONAR_TOKEN
    value_env: SONAR_TOKEN_VALUE
    version: "2026-10-07"
    version_at: "2026-10-07T00:00:00Z"
    visibility: public
    sources:
      - github-main
    targets:
      github:
        - actions
        - dependabot
```

Configuration is validated before any provider request. Unknown keys, unsupported source/context types, unknown source references, non-boolean repository switches, invalid visibility values, and malformed version timestamps are errors rather than ignored settings.

Source repository selection supports:

- `visibility`: `public`, `private`, or `all`
- `include_archived`: include archived repositories
- `include_forks`: include forks
- `include`: exact repository names or `owner/name` pairs; when non-empty it disables account-wide discovery and fetches metadata only for those names. It overrides the source-level visibility/archived/fork filters, but does not bypass per-secret visibility or admin-permission checks.
- `exclude`: exact names or glob patterns applied after discovery or explicit includes

Each entry under `sources` is a distinct provider instance; multiple entries may use the same `type` for different accounts or hosts. Give each account its own source ID, owner, logical host, and `auth_env`. GitHub.com and GitHub Enterprise use the same adapter: `host` is the logical GitHub hostname (for example `github.com` or a GHES hostname), not the REST API hostname. Sources sharing a GitHub host must declare `auth_env` so `gh` cannot silently use an ambiguous stored account. One secret definition has one `value_env`; the same value is shared across the source IDs listed under `sources`.

Secret selection supports:

- `visibility`: `public` by default, or `private`/`all`
- `sources`: all configured sources by default, a list, or `all`
- `exclude_sources`: source names to skip
- `exclude_repositories`: a flat list or a mapping by source name
- `repository_rules`: exact per-source `owner/repository` overrides with `include`, `exclude`, or `default`; `include`/`exclude` override the token's default source/visibility scope for that repository, but `exclude_sources` always wins. `default` restores the normal scope and can cancel a `exclude_repositories` match.
- `targets.github`: `actions`, `dependabot`, or both
- `targets.forgejo`: `actions` only; Forgejo is currently pull-only
- `value_env`: environment variable containing the value; defaults to the secret name
- `value_digest`: optional `hmac-sha256:<hex>` keyed fingerprint of `HMAC-SHA256(key, "cred-align-flow\0" + name + "\0" + value)`; the private `.digest-key` file is created next to the env file and is gitignored. Back it up securely with that env file. If it is missing while keyed digests exist, the CLI stops instead of silently generating a replacement. Replacing a key intentionally makes prior fingerprints incomparable and can schedule updates for every applied target; do not rotate it casually. Legacy `sha256:<hex>` digests remain readable. `doctor` reports value drift and `plan` schedules an `update` from the per-target applied fingerprint; `scaffold` can record the current local digest without changing the applied baseline. `scaffold` never prints or stores the value itself.
- `version`: desired local revision label; change it when rotating a value
- `version_at`: UTC timestamp for that revision; a newer remote timestamp blocks overwrite unless `--force` is used

GitHub repository secrets are limited to 48 KB and 100 secrets per repository. The plan/apply preflight enforces the value-size and known secret-count limits; a count that changed remotely after refresh is rechecked before creation.

Do not commit real values, private repository names, rules files, local inventory files, or `.digest-key` files. For private or explicitly managed repositories, prefer a local config containing an `include` list. This prevents the account-wide repository-list call; the adapter makes a targeted metadata lookup for each listed repository to verify visibility and admin status, then retrieves secret metadata only for selected targets. Unknown status or permissions stop the inventory/apply flow.

### Repository rules file

Per-repository token overrides live in a JSON file that the config UI manages; it is the only file the UI writes. The default path is derived from the config file name — `cred-align.local.yml` uses `cred-align.rules.json` beside it, and a config named `config.yml` uses `rules.json` in the same directory — or set `rules_file:` explicitly in the YAML config.

```json
{
  "version": 1,
  "rules": {
    "github-main": {
      "owner/repo": { "SONAR_TOKEN": "exclude" }
    }
  }
}
```

Each entry maps `source → owner/repository → secret name → include`, `exclude`, or `default`. `include`/`exclude` override the secret's default `sources`/`visibility` scope for that repository; `default` restores it and cancels a `exclude_repositories` or `repository_rules` match. `exclude_sources` always wins. Rules file entries take precedence over a hand-authored `repository_rules` key for the same repository and token; both CLI commands and the UI resolve the merged result.

## Configuration UI

Start the local browser editor with Bundler (Itsi is a development-only dependency):

```bash
bundle exec bin/cred-align-flow ui
```

Open the printed `http://127.0.0.1:8043/` address. Use `--config`, `--env-file`, and `--state` to select local files, or `--port` to choose another local port. Sources and token definitions are read-only in the UI — edit the YAML config by hand. The only editable controls are the per-repository token rule dropdowns, which Save writes to the rules file. The UI shows the inventory and plan statuses, including whether a token is assigned by defaults or a repository rule, and the remote/applied timestamps available in local state. “Refresh repository inventory” makes provider read requests only. “Cancel changes” reloads the saved rules. Actual env-file values are never returned to the browser.

The new-release indicator is opt-in: set `check_for_updates: true` in the YAML config. `update_notice_min_age_days` defaults to `7`; set it to `0` for immediate notices. The local UI makes one same-origin request per page session, and the local server checks this repository's public GitHub releases. It shows a notice only for a published, non-draft numeric release whose GitHub `published_at` is at least the configured age. Results (including no-update/error results) are cached for 24 hours per current version and age setting in the running UI process, so a release may be noticed up to a day after it reaches the age threshold. No configuration, repository names, or secret values are sent; GitHub can see the server's outbound IP. When `check_for_updates` is absent or false, the browser does not request update status and the server makes no outbound release-check request. If the check is unavailable, the indicator stays hidden.

Every save revalidates the draft rules (shape plus source/token references), requires the page's per-run CSRF token, and rejects stale saves if the config, rules, or inventory changed while the page was open. The UI also polls an HMAC-protected display revision that includes env-file bytes, so availability/value status refreshes when only the env file changes; an env-only update does not invalidate a rules-only save. Rules for repositories no longer in inventory are kept and flagged so they can be removed deliberately. Unimported env names are shown with the explicit `scaffold --only ... --target ...` workflow.

## Commands

Validate local configuration and value references:

```bash
bin/cred-align-flow doctor
```

Refresh repository and remote secret metadata (`pull` is an alias); `--source` limits the pull to matching configured sources:

```bash
bin/cred-align-flow inventory
bin/cred-align-flow pull --source github-main
bin/cred-align-flow pull --source forgejo-main
```

Refresh inventory and show all managed target states without writing remote secrets:

```bash
bin/cred-align-flow plan
bin/cred-align-flow diff
```

Use cached inventory for a local-only report:

```bash
bin/cred-align-flow plan --offline
```

Fail when expected secrets are missing, unverified, stale, or remotely newer:

```bash
bin/cred-align-flow check
bin/cred-align-flow check --strict
```

Apply missing or stale secrets. In a terminal, the CLI prints the exact refreshed plan and asks for confirmation before writing. It aborts if config, rules, env/key inputs, or inventory change while the plan is being reviewed. For non-interactive use, `--yes` explicitly approves that invocation's freshly generated plan:

```bash
bin/cred-align-flow apply
bin/cred-align-flow apply --yes
```

Overwrite only unverified or remotely newer secrets after reviewing the plan; `--force` does not bypass the non-interactive `--yes` approval, repository identity check, or the pre-write remote recheck. `ok` secrets are not rewritten by `--force`. Use source/repository/secret/context filters to keep the override scope narrow:

```bash
bin/cred-align-flow apply --source github-main --repo owner/repo --secret SONAR_TOKEN --context actions --force --yes
```

Limit a plan, check, or apply operation by source, repository, secret, or context:

```bash
bin/cred-align-flow plan --repo 'jekyll-*'
bin/cred-align-flow apply --repo jekyll-client-search --secret SONAR_TOKEN
bin/cred-align-flow apply --context actions
```

A `--context` filter also narrows the inventory refresh itself: only matching provider contexts are queried, and the snapshot is marked as covering just those contexts. Both online and offline `plan`/`check`/`apply` fail closed when required coverage is missing, discovery is truncated, source/selection identity is unknown, or the snapshot is older than 24 hours. A full `inventory`/`pull` or unfiltered refresh clears the context-coverage marker.

Run the apply flow without writing remote secrets:

```bash
bin/cred-align-flow apply --dry-run
```

`scaffold` refreshes existing value digests and lists unimported env names; it does not import names unless `--only` is supplied. Imports remain active entries, but require an exact destination tuple for every reviewed target:

```bash
bin/cred-align-flow scaffold
bin/cred-align-flow scaffold --only NEW_SECRET --target 'github-main|actions|owner/repo'
bin/cred-align-flow scaffold --only DEPLOY_KEY --target 'github-main|actions|owner/app' --target 'github-main|actions|owner/deploy'
bin/cred-align-flow scaffold --ignore LOCAL_HELPER_VAR
bin/cred-align-flow scaffold --digests-only
```

Each `--target` is one argument in the form `SOURCE|CONTEXT|OWNER/REPO`; quote it so the shell does not interpret `|`. `--only` is required to import, and the command prints the selected names and exact destinations before editing YAML. A scaffolded definition is active only for those repositories and contexts; other repositories for that source are excluded by default. The current config schema applies target contexts per provider type, so all selected repositories for a source must use the same context set and sources of the same provider type must use the same context set. Unsupported combinations are rejected instead of broadened. `--ignore` persists names in `ignored_env_names:` and excludes them immediately, including in the same invocation. Active definitions, not provenance comments, determine whether a name is already managed. The generated YAML is parsed and validated while holding a lock before atomic replacement; unsupported layouts fail without replacing the original. `--digests-only` never imports new names.

## Plan statuses

- `create`: expected remote secret is missing.
- `unverified_present`: remote secret exists, but this state file has not recorded an apply. Use `apply --force` to overwrite it after review.
- `remote_newer`: remote `updated_at` is newer than the recorded local `applied_at` — the remote changed after our last write. Use `apply --force` to overwrite it.
- `update`: the desired value fingerprint differs from the fingerprint recorded at the last apply (a rotated value), or — for older records without a fingerprint — the configured `version` differs from the recorded one.
- `ok`: the target is managed and the recorded fingerprint (or version, for legacy records) is current.
- `pull_only`: the target's source is read-only (Forgejo); the state is reported but never written.
- `unexpected`: a remote secret exists outside the configured target scope. It is report-only.
- `missing_value`: the configured `value_env` is not set.

## Rotation

To rotate a value:

1. Update the value in the env file (`config/secrets.env` or `.env.local`).
2. Change the secret's `version` and `version_at` in the YAML config (recommended bookkeeping; the fingerprint check below does not depend on it).
3. Run `bin/cred-align-flow scaffold` to record the new `value_digest` — this accepts the rotated value locally (`doctor` flags a stale digest until you do). Even without this step, `plan` compares the env value's fingerprint against the per-target applied fingerprint and schedules an `update`.
4. Run `bin/cred-align-flow plan` or `bin/cred-align-flow apply --dry-run`.
5. Run `bin/cred-align-flow apply`, optionally limited by `--source`, `--repo`, `--secret`, or `--context`.
6. Run `bin/cred-align-flow check`.

If a remote timestamp is newer than the recorded apply baseline, the tool reports `remote_newer` and requires `--force` to replace it — configured `version_at` is never treated as proof that we own the remote value. After each successful write the applier re-reads the provider's own `updated_at` and records it as `applied_remote_at`, so drift detection compares two provider timestamps and is immune to local clock skew. Records written before that existed (or when the post-write re-read could not confirm a timestamp) fall back to local `applied_at`; a missing or invalid baseline is treated conservatively as `remote_newer`. Provider timestamps can still have coarse precision, so changes within the same second cannot always be distinguished. `version_at` should be UTC ISO8601 or include a numeric timezone offset. Forgejo may expose only `created_at` for a secret; the adapter uses `updated_at` when available and otherwise treats `created_at` as the remote timestamp.

## Provider design

Each source has a unique name, `type`, logical `host` or provider `url`/`api_url`, and provider-specific settings. A source ID represents one account/instance; the same adapter type may be configured multiple times. For GitHub, use the logical host (`github.com` or a GHES hostname); `api.github.com` is normalized to `github.com`. GitHub sources sharing a host need their own `auth_env` references to avoid using an ambiguous stored login. The single GitHub adapter maps GitHub.com/GitHub Enterprise Cloud hosts to `GH_TOKEN` and GHES hosts to `GH_ENTERPRISE_TOKEN`. Providers register under a source type through `CredAlignFlow::Providers`; every adapter subclasses `CredAlignFlow::Provider` and implements the small contract:

```text
CONTEXTS
repositories
repository(name)
secrets(repository, context)
set_secret(repository, context, name, value)
```

Shared contract tests in `test/provider_contract_test.rb` enumerate the provider registry, so a new adapter is tested automatically after registration. Registered source types are `github` and `forgejo`. The Forgejo adapter currently supports `repositories`, targeted `repository(name)` metadata reads, and `secrets`; `set_secret` raises `ProviderError`, so `plan`, `check`, `pull`, and `apply --dry-run` are valid while actual Forgejo writes remain disabled. GitLab project/group variables fit the same model. Mercurial, Bazaar, and Perforce are version-control systems rather than repository-hosting secret APIs; they would only become valid source types if paired with a hosting service that exposes a compatible secret/variable API.

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

## License

This project is licensed under the GNU Affero General Public License, version 3 only (`AGPL-3.0-only`). See [LICENSE](LICENSE) and [DISCLAIMER.md](DISCLAIMER.md).

Per AGPL §15–16:

> THERE IS NO WARRANTY FOR THE PROGRAM, TO THE EXTENT PERMITTED BY APPLICABLE LAW. EXCEPT WHEN OTHERWISE STATED IN WRITING THE COPYRIGHT HOLDERS AND/OR OTHER PARTIES PROVIDE THE PROGRAM "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED OR IMPLIED, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE. THE ENTIRE RISK AS TO THE QUALITY AND PERFORMANCE OF THE PROGRAM IS WITH YOU. SHOULD THE PROGRAM PROVE DEFECTIVE, YOU ASSUME THE COST OF ALL NECESSARY SERVICING, REPAIR OR CORRECTION.
>
> IN NO EVENT UNLESS REQUIRED BY APPLICABLE LAW OR AGREED TO IN WRITING WILL ANY COPYRIGHT HOLDER, OR ANY OTHER PARTY WHO MODIFIES AND/OR CONVEYS THE PROGRAM AS PERMITTED ABOVE, BE LIABLE TO YOU FOR DAMAGES, INCLUDING ANY GENERAL, SPECIAL, INCIDENTAL OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE USE OR INABILITY TO USE THE PROGRAM (INCLUDING BUT NOT LIMITED TO LOSS OF DATA OR DATA BEING RENDERED INACCURATE OR LOSSES SUSTAINED BY YOU OR THIRD PARTIES OR A FAILURE OF THE PROGRAM TO OPERATE WITH ANY OTHER PROGRAMS), EVEN IF SUCH HOLDER OR OTHER PARTY HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGES.
>
> **USE AT YOUR OWN RISK.**
