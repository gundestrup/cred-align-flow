# cred-align-flow — configuration UI

Part of the [cred-align-flow](README.md) documentation.

Start the local browser editor with Bundler (Itsi is a development-only dependency):

```bash
bundle exec bin/cred-align-flow ui
```

Open the printed `http://127.0.0.1:8043/` address. Use `--config`, `--env-file`, and `--state` to select local files, or `--port` to choose another local port. Sources and token identities (name, value env, versions, digests, `exclude_sources`) are read-only in the UI — edit the YAML config by hand. The editable controls are a token's default scope fields (visibility, sources, targets, repository exclusions) and the per-repository token rule dropdowns — both written to the rules file — plus the named presets, which live in the two preset files next to it. Token presets stamp scope fields onto a token card; repo presets stamp a `token → rule` bundle (with a `*` catch-all) onto a repository card. The UI shows the inventory and plan statuses, including whether a token is assigned by defaults or a repository rule, and the remote/applied timestamps available in local state. “Refresh repository inventory” makes provider read requests only. “Cancel changes” reloads the saved rules and presets. Actual env-file values are never returned to the browser.

The new-release indicator is opt-in: set `check_for_updates: true` in the YAML config. `update_notice_min_age_days` defaults to `7`; set it to `0` for immediate notices. The local UI makes one same-origin request per page session, and the local server checks this repository's public GitHub releases. It shows a notice only for a published, non-draft numeric release whose GitHub `published_at` is at least the configured age. Results (including no-update/error results) are cached for 24 hours per current version and age setting in the running UI process, so a release may be noticed up to a day after it reaches the age threshold. No configuration, repository names, or secret values are sent; GitHub can see the server's outbound IP. When `check_for_updates` is absent or false, the browser does not request update status and the server makes no outbound release-check request. If the check is unavailable, the indicator stays hidden.

Every save revalidates the full draft (rule shapes, token-default overrides merged into the YAML secrets, preset shapes, and all source/token/context references), requires the page's per-run CSRF token, and rejects stale saves if the config, rules file, preset files, or inventory changed while the page was open. The UI also polls an HMAC-protected display revision that includes env-file bytes, so availability/value status refreshes when only the env file changes; an env-only update does not invalidate a rules-only save. Rules for repositories no longer in inventory are kept and flagged so they can be removed deliberately. Unimported env names are shown with the explicit `scaffold --only ... --target ...` workflow.
