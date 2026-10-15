# cred-align-flow — presets

Presets are named, reusable templates managed by the local config UI. They are *personal library* files, not configuration inputs: `plan`/`apply`/`check` never read them. Applying a preset **stamps** its fields — it copies the values into the rules file where the normal preview/save flow validates them. Editing a preset afterwards does not re-apply it to tokens or repositories that were already stamped.

## Files

Two JSON files live beside the rules file, named after it:

| Rules file | Token presets | Repo presets |
|---|---|---|
| `cred-align.rules.json` | `cred-align.presets-tokens.json` | `cred-align.presets-repos.json` |
| `rules.json` | `presets-tokens.json` | `presets-repos.json` |

A custom `rules_file:` in the YAML config relocates all three. The files are gitignored like the rules file — they are local, personal state. They may be hand-edited; strict validation applies on the next UI load.

## Token presets

A token preset holds the same scope fields a `token_defaults` entry may override:

```json
{
  "version": 1,
  "presets": {
    "github-ci": {
      "visibility": "public",
      "sources": ["github-main"],
      "targets": { "github": ["actions"] },
      "exclude_repositories": ["example/experimental-*"]
    }
  }
}
```

Applying a token preset on a token card stamps its fields into that token's `token_defaults` entry in the rules file. `sources` may only name configured sources (or `all`), and `targets` may only name supported provider contexts — the UI validates references at save time so a preset cannot be stored that would stamp broken state.

## Built-in token presets

Provider adapters ship read-only presets for their standard scope options — for example GitHub offers *"GitHub: Actions + Dependabot"* and *"GitHub: all contexts"*, which stamp a `targets` selection for the new `agents`/`codespaces` secret stores without memorizing context names, and Forgejo offers *"Forgejo: repository Actions"* and *"Forgejo: user scope"*. The `user` scope preset only takes effect on sources that opt in with `user_secrets: true`; saving a config where a targeted source lacks the flag fails validation. Built-ins appear under a separate group in the "Apply preset" dropdown and as read-only cards in the Presets tab. They are adapter constants, not file entries — a custom preset saved under the same name shadows the built-in.

## Repo presets

A repo preset holds a `token → rule` bundle for stamping onto a repository's per-source `rules` entries:

```json
{
  "version": 1,
  "presets": {
    "ci-lockdown": { "SONAR_TOKEN": "include", "*": "exclude" }
  }
}
```

Each token key maps to `include`, `exclude`, or `default` — the same values as the per-repository dropdowns. The `"*"` key is a catch-all stamped onto every configured token the preset does not name; without it, unlisted tokens keep their existing rules. Tokens locked by `exclude_sources` are skipped at apply time — no rule can cross that boundary.

Applying a repo preset uses the "Repository-specific token rules" dropdown on a repository card. Stamping `default` behaves like choosing "Use token defaults": it deletes a redundant JSON rule, or writes an explicit `default` to cancel a hand-authored `repository_rules`/`exclude_repositories` match.

### Composition and conflicts

Presets **accumulate**: each apply merges the preset's entries into the repository's existing rules, so several presets can stack on one repo — and even a `*` catch-all only touches tokens whose current rule differs from the preset's.

When a preset entry would change an existing non-default rule (e.g. the repo already says `exclude` but the preset wants `include`), that entry is held as a **conflict**: the non-conflicting entries still apply, the card lists the held entries, and a **Force apply** button stamps the preset's values over them. `exclude_sources`-locked tokens are never touched, force or not.

### Clearing rules

Two "clear" actions reset rules back to the token defaults:

- **Clear rules** on a repository card removes every token rule on that repo.
- **Clear repository rules** on a token card removes that token's rules across every repository and source.

Both delete JSON rules outright and write an explicit `default` where a YAML `repository_rules` entry or `exclude_repositories` match would otherwise keep applying — the net effect is "no manual rules".

## Boundaries

- Presets are saved, previewed, and revision-guarded together with the rules draft; a preset file that changes on disk stales the page's revision.
- Stamping changes only the rules file — remote provider writes still require `apply` after a printed, confirmed plan.
- `exclude_sources`, token identity (`name`, `value_env`, digests, versions), and `repository_rules` remain YAML-only and unreachable through presets.
