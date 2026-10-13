# cred-align-flow — warnings and security model

Part of the [cred-align-flow](README.md) documentation.

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
