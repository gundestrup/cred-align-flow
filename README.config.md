# cred-align-flow — setup and configuration

Part of the [cred-align-flow](README.md) documentation.

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
# env names that scaffold should never offer to import:
# ignored_env_names:
#   - LOCAL_HELPER_VAR
# What `scaffold` does with unimported env names when no --target is
# given: default lists them only, import writes commented full-field
# draft entries, auto writes minimal inactive entries — assigned
# nowhere until the UI grants scope via token defaults or rules.
# Explicit --target tuples always win.
# scaffold_action: default

sources:
  github-main:
    type: github
    owner: your-github-owner
    host: github.com
    # api_url: https://api.github.com  # API endpoint; alternative to host (e.g. GHES)
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
    # Opt-in: allow blind pushes to the account-level user secret store
    # (targets.forgejo: [user]). The API cannot list user secrets, so
    # writes are unverifiable and there is no delete.
    # user_secrets: true
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
- `repository_rules`: exact per-source `owner/repository` overrides with `include`, `exclude`, `delete`, or `default`; `include`/`exclude` override the token's default source/visibility scope for that repository, but `exclude_sources` always wins. `delete` stops syncing the token there and marks any existing remote secret for removal — `prune` walks each marked item for confirmation before deleting. `default` restores the normal scope and can cancel a `exclude_repositories` match.
- `targets.github`: any subset of `actions`, `agents`, `codespaces`, `dependabot`; defaults to `actions` when unset. `agents` is the Copilot cloud agent store and needs a recent `gh`; it does not exist on GHES.
- `targets.forgejo`: `actions` (repository secrets; pull-only) and `user` (account-level secrets shared across the token owner's repositories). `user` is push-only: the Forgejo API cannot list user secrets, so the plan decides from the applied journal alone and writes blindly — enable it per source with `user_secrets: true`. There is no user-scope delete.
- `value_env`: environment variable containing the value; defaults to the secret name
- `value_digest`: optional `hmac-sha256:<hex>` keyed fingerprint of `HMAC-SHA256(key, "cred-align-flow\0" + name + "\0" + value)`; the private `.digest-key` file is created next to the env file and is gitignored. Back it up securely with that env file. If it is missing while keyed digests exist, the CLI stops instead of silently generating a replacement. Replacing a key intentionally makes prior fingerprints incomparable and can schedule updates for every applied target; do not rotate it casually. Legacy `sha256:<hex>` digests remain readable. `doctor` reports value drift and `plan` schedules an `update` from the per-target applied fingerprint; `scaffold` can record the current local digest without changing the applied baseline. `scaffold` never prints or stores the value itself.
- `version`: desired local revision label; change it when rotating a value
- `version_at`: UTC timestamp for that revision; a newer remote timestamp blocks overwrite unless `--force` is used. `updated_at` is an accepted alias — an entry must use only one of the two.

GitHub repository secrets are limited to 48 KB and 100 secrets per repository. The plan/apply preflight enforces the value-size and known secret-count limits; a count that changed remotely after refresh is rechecked before creation.

Do not commit real values, private repository names, rules files, local inventory files, or `.digest-key` files. For private or explicitly managed repositories, prefer a local config containing an `include` list. This prevents the account-wide repository-list call; the adapter makes a targeted metadata lookup for each listed repository to verify visibility and admin status, then retrieves secret metadata only for selected targets. Unknown status or permissions stop the inventory/apply flow.

### Repository rules file

UI-managed effective state lives in a JSON file next to the config. The default path is derived from the config file name — `cred-align.local.yml` uses `cred-align.rules.json` beside it, and a config named `config.yml` uses `rules.json` in the same directory — or set `rules_file:` explicitly in the YAML config.

```json
{
  "version": 2,
  "rules": {
    "github-main": {
      "owner/repo": { "SONAR_TOKEN": "exclude" }
    }
  },
  "token_defaults": {
    "SONAR_TOKEN": { "visibility": "all", "targets": { "github": ["actions", "dependabot"] } }
  }
}
```

`rules` maps `source → owner/repository → secret name → include`, `exclude`, `delete`, or `default`. `include`/`exclude` override the secret's default `sources`/`visibility` scope for that repository; `default` restores it and cancels a `exclude_repositories` or `repository_rules` match; `delete` stops syncing the secret there and marks the remote copy for removal by `prune`. `exclude_sources` always wins. Rules file entries take precedence over a hand-authored `repository_rules` key for the same repository and token; both CLI commands and the UI resolve the merged result.

`token_defaults` overrides a secret's default scope per field: `visibility`, `sources`, `targets`, and `exclude_repositories` set here replace the same YAML fields (an overlaid `exclude_repositories` replaces both `exclude_repositories` and `exclude_repos`); fields left unset keep the YAML value. Token identity is never overridable — `name`, `value_env`, digests, versions, `exclude_sources`, and `repository_rules` stay in the YAML.

Files without `token_defaults` stay at `version: 1`, so they remain readable by older builds. A `version: 2` file is rejected by builds that predate the section rather than silently ignoring overrides that change the plan.

Rules and `token_defaults` that reference a token or source no longer in the YAML config are **stale**: they can never fire, so they are ignored on load rather than failing the command — the CLI prints a warning, the UI lists them in the orphan notice, and the next UI save drops them. Deleting or renaming a token in the YAML is the typical cause; review the notice before saving so a re-added name cannot silently re-inherit an old rule.

### Preset files

The UI also manages two preset-library files beside the rules file, named after it — `cred-align.rules.json` pairs with `cred-align.presets-tokens.json` and `cred-align.presets-repos.json`, while a plain `rules.json` pairs with `presets-tokens.json` and `presets-repos.json`. They hold reusable stamp templates (token scope presets and repo rule bundles) that `plan`/`apply`/`check` never read — see [README.presets.md](README.presets.md).

Preset entries go stale the same way rules do: a repo-preset entry naming a token, or a token-preset `sources`/`exclude_repositories` entry naming a source, that no longer exists is inert, listed in the orphan notice, and dropped from the draft on the next save — while strict validation still rejects a *submitted* draft containing unknown references.
