# frozen_string_literal: true

module CredAlignFlow
  # Single source of truth for the status vocabulary and help text the
  # config UI renders. The page builds its status pills, digest badges,
  # and help panel from this payload instead of hardcoding copies, so the
  # wording cannot drift from the planner/applier semantics that produce
  # those statuses. Adding a planner action requires an entry here — a
  # test asserts every emitted action is listed.
  #
  # Descriptions use backticks for inline code; the page renders those
  # spans as <code> elements (never innerHTML).
  module UiMetadata
    STATUSES = {
      "ok" => "the locally recorded applied fingerprint matches the current local value; " \
              "GitHub does not reveal remote values, so this is not proof of remote equality",
      "create" => "the refreshed plan proposes creating this remote secret",
      "update" => "the refreshed plan proposes overwriting this remote secret",
      "unverified_present" => "the remote secret exists but was not applied by this state file; " \
                              "adopt with `apply --force` after review",
      "remote_newer" => "the remote secret changed after the last recorded apply; requires `apply --force` after review",
      "missing_value" => "no local value is set for this secret",
      "pull_only" => "the provider cannot receive writes",
      "unexpected" => "remote-only secret, report-only",
      "not_checked" => "no inventory is available",
      "not_refreshed" => "inventory does not cover this context"
    }.freeze

    APPLY_NOTE =
      "Apply prints the current plan and asks before writing; noninteractive use must pass `--yes`."

    PLAN_ACTIONS_TEXT =
      "#{STATUSES.map { |name, text| "`#{name}` — #{text}" }.join('. ')}. #{APPLY_NOTE}".freeze

    # [status class, label] for the token value/digest badge. The page
    # picks "missing" when no env value is set, else the digest status.
    VALUE_PILLS = {
      "missing" => { "css" => "value-missing", "label" => "Local value missing" },
      "changed" => { "css" => "value-changed", "label" => "Value changed — run apply to push, scaffold to re-record" },
      "unverifiable" => { "css" => "value-unverifiable", "label" => "Digest present but the fingerprint key is unavailable" },
      "unrecorded" => { "css" => "value-unrecorded", "label" => "Local value is set · no digest recorded" },
      "ready" => { "css" => "value-ready", "label" => "Local value is set" }
    }.freeze

    FIELD_HELP = [
      ["Token name / value environment variable",
       "The secret name pushed to providers (uppercase, as providers store it) and the env-file variable " \
       "holding its value. Values are never shown here."],
      ["Version / version time",
       "Your recorded intent — a label and timestamp for this token definition, not the provider's state."],
      ["Value digest",
       "A keyed fingerprint of the name + value recorded in the YAML (the fingerprint itself is never " \
       "shown here). \"Value changed\" means the env value differs from the recorded fingerprint — run " \
       "`apply` to push it, then `scaffold` to re-record the digest."],
      ["Visibility",
       "Repository visibility scope: `public`, `private`, or `all` — which repos may receive this token. " \
       "This is a local repository filter, not a provider-side secret visibility setting."],
      ["Source scope",
       "Which sources (e.g. github-main, forgejo-main) the token applies to; no selection (or \"all\") " \
       "means every configured source."],
      ["Targets",
       "Provider secret stores per source type — GitHub `actions`, `agents`, `codespaces`, and " \
       "`dependabot`, Forgejo `actions` and `user`. Forgejo `user` targets the account-level " \
       "store, which the API cannot list: pushes are blind and require `user_secrets: true` on " \
       "the source. Sources marked pull-only cannot receive repository writes at all."],
      ["Token default overrides",
       "The editable fields on a token card write `token_defaults` entries in the rules file. A field " \
       "set here replaces the same YAML field; fields marked `override` differ from the hand-edited " \
       "value. \"Reset to YAML defaults\" removes a token's overrides. Name, value env, versions, and " \
       "`exclude_sources` stay YAML-only — exclusions there always win. A comma-separated exclusion " \
       "list applies to all sources; per-source exclusion maps remain YAML-only."],
      ["Token presets",
       "Named scope templates in the token preset file, plus read-only built-ins provided by the " \
       "configured adapters. Applying one on a token card copies its fields into that token's " \
       "overrides — later preset edits do not change tokens already stamped. A custom preset with " \
       "a built-in's name shadows it."],
      ["Repository presets",
       "Named `token => rule` bundles in the repo preset file; `*` covers every token not listed. " \
       "Applying one on a repository card merges those rules into the repo's rules, so presets " \
       "accumulate — later preset edits do not re-apply. An entry that would change an existing " \
       "non-default rule is held as a conflict: the safe entries still apply and \"Force apply\" " \
       "overwrites the conflicting ones."],
      ["Clearing rules",
       "\"Clear rules\" on a repository card removes every token rule there, and \"Clear repository " \
       "rules\" on a token card removes that token's rules on every repository and source. YAML rules " \
       "and repository exclusions get an explicit `default` that cancels them; `exclude_sources`-locked " \
       "tokens stay untouched."],
      ["Hard vs soft exclusions",
       "`exclude_sources` and source repository filters are hard boundaries — no rule can cross them. " \
       "`exclude_repositories` and YAML repository rules are overridable defaults — an `include` or " \
       "explicit `default` can change them."],
      ["Per-repository rules",
       "`default` follows the token defaults, `include` force-assigns the token, `exclude` blocks it on " \
       "that repo. When a YAML rule or exclusion already applies, choosing \"Use token defaults\" writes " \
       "an explicit `default` to cancel it rather than deleting the JSON entry."],
      ["Plan actions", PLAN_ACTIONS_TEXT],
      ["Orphan rules",
       "Saved rules for repos no longer in inventory (renamed or gone). They stay in the rules file and " \
       "can re-activate if the name is reused — remove them deliberately."],
      ["Unimported env names",
       "Variables in the env file with no token definition. To import, explicitly select names with " \
       "`scaffold --only` and exact destinations with repeated `--target 'SOURCE|CONTEXT|OWNER/REPO'` " \
       "options. Imports are active only for those targets. Helper variables can be persisted with " \
       "`scaffold --ignore` or `ignored_env_names`."]
    ].freeze

    def self.to_h
      {
        "statuses" => STATUSES.keys,
        "status_help" => STATUSES,
        "value_pills" => VALUE_PILLS,
        "field_help" => FIELD_HELP.map { |term, text| { "term" => term, "text" => text } }
      }
    end
  end
end
