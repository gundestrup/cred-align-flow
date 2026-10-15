# cred-align-flow — command reference

Part of the [cred-align-flow](README.md) documentation.

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

`scaffold` refreshes existing value digests and lists unimported env names; with the default `scaffold_action` it does not import names unless `--only` is supplied. Imports remain active entries, but require an exact destination tuple for every reviewed target:

```bash
bin/cred-align-flow scaffold
bin/cred-align-flow scaffold --only NEW_SECRET --target 'github-main|actions|owner/repo'
bin/cred-align-flow scaffold --only DEPLOY_KEY --target 'github-main|actions|owner/app' --target 'github-main|actions|owner/deploy'
bin/cred-align-flow scaffold --ignore LOCAL_HELPER_VAR
bin/cred-align-flow scaffold --digests-only
```

Each `--target` is one argument in the form `SOURCE|CONTEXT|OWNER/REPO`; quote it so the shell does not interpret `|`. `--only` is required to import, and the command prints the selected names and exact destinations before editing YAML. A scaffolded definition is active only for those repositories and contexts; other repositories for that source are excluded by default. The current config schema applies target contexts per provider type, so all selected repositories for a source must use the same context set and sources of the same provider type must use the same context set. Unsupported combinations are rejected instead of broadened. `--ignore` persists names in `ignored_env_names:` and excludes them immediately, including in the same invocation. Active definitions, not provenance comments, determine whether a name is already managed. The generated YAML is parsed and validated while holding a lock before atomic replacement; unsupported layouts fail without replacing the original. `--digests-only` never imports new names.

The top-level `scaffold_action:` setting changes what happens when names are imported **without** `--target` tuples:

- `default` (the default): imports require `--only` plus `--target`; plain `scaffold` only lists unimported names.
- `import`: `scaffold` (all names) or `scaffold --only NAMES` writes the entries into the YAML as **commented draft blocks** marked `# scaffold-draft:` — they stay inactive until you uncomment each entry. Drafted names are not offered again.

Imports under `import` or explicit `--target` tuples write the **full field set** so every option is visible: `visibility` (with its enum), `sources`, `targets` listing every context each configured provider supports (unselected contexts and owner scopes stay commented, e.g. Forgejo `user` notes its `user_secrets: true` requirement), the real `exclude_repositories`/`repository_rules` narrowing for targeted imports, and optional `exclude_sources`/narrowing templates as comments. Inside a draft block, comment lines carry a second `#` (`# #`), so removing one `# ` per line activates the entry while optional fields stay commented for the user to enable, delete, or change.
- `auto`: imports and **activates** the entries as minimal definitions — only `name`/`value_env`, digest, and version are written, so the token defaults apply (all sources, `visibility: public`, each provider's implicit context — GitHub `actions`; Forgejo sources need a `targets` entry, e.g. stamped by the UI's built-in Forgejo preset). Scope is then managed in the UI (`token_defaults`, presets, repo rules) or by editing the YAML.

Explicit `--target` tuples always produce active targeted entries, whatever the action.

## Plan statuses

- `create`: expected remote secret is missing.
- `unverified_present`: remote secret exists, but this state file has not recorded an apply. Use `apply --force` to overwrite it after review.
- `remote_newer`: remote `updated_at` is newer than the recorded local `applied_at` — the remote changed after our last write. Use `apply --force` to overwrite it.
- `update`: the desired value fingerprint differs from the fingerprint recorded at the last apply (a rotated value), or — for older records without a fingerprint — the configured `version` differs from the recorded one.
- `ok`: the target is managed and the recorded fingerprint (or version, for legacy records) is current.
- `pull_only`: the target's source is read-only (Forgejo repository secrets); the state is reported but never written.
- `unexpected`: a remote secret exists outside the configured target scope. It is report-only.
- `missing_value`: the configured `value_env` is not set.

Owner-scope targets (Forgejo `user`) are listed once per source under the synthetic `@owner` repository. Because the API cannot enumerate that store, `create`/`update`/`ok` there are journal-only judgments: `create` means "no recorded apply", `update` means "the local value differs from the recorded fingerprint", and neither says anything about remote state. There is no `unverified_present`, `remote_newer`, or `unexpected` for owner scope.

## Rotation

To rotate a value:

1. Update the value in the env file (`config/secrets.env` or `.env.local`).
2. Change the secret's `version` and `version_at` in the YAML config (recommended bookkeeping; the fingerprint check below does not depend on it).
3. Run `bin/cred-align-flow scaffold` to record the new `value_digest` — this accepts the rotated value locally (`doctor` flags a stale digest until you do). Even without this step, `plan` compares the env value's fingerprint against the per-target applied fingerprint and schedules an `update`.
4. Run `bin/cred-align-flow plan` or `bin/cred-align-flow apply --dry-run`.
5. Run `bin/cred-align-flow apply`, optionally limited by `--source`, `--repo`, `--secret`, or `--context`.
6. Run `bin/cred-align-flow check`.

If a remote timestamp is newer than the recorded apply baseline, the tool reports `remote_newer` and requires `--force` to replace it — configured `version_at` is never treated as proof that we own the remote value. After each successful write the applier re-reads the provider's own `updated_at` and records it as `applied_remote_at`, so drift detection compares two provider timestamps and is immune to local clock skew. Records written before that existed (or when the post-write re-read could not confirm a timestamp) fall back to local `applied_at`; a missing or invalid baseline is treated conservatively as `remote_newer`. Provider timestamps can still have coarse precision, so changes within the same second cannot always be distinguished. `version_at` should be UTC ISO8601 or include a numeric timezone offset. Forgejo may expose only `created_at` for a secret; the adapter uses `updated_at` when available and otherwise treats `created_at` as the remote timestamp.
