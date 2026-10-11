# cred-align-flow: negative findings and required changes

Reviewed: 2026-10-10. Post-fix review: 2026-10-11. Scope: the local working tree, not a released version.

**Post-fix status:** all findings are closed; the original reproductions now have regression coverage. The finding bodies below retain the pre-fix evidence; their headings and the status matrix record current closure. Latest `bundle exec rake test` on Ruby 3.4.10 passed: 156 runs / 793 assertions / 0 failures, errors, or skips; RuboCop clean. Flay/flog remain informational. Semgrep was unavailable locally and skipped; `SEMGREP_REQUIRED=1` fails closed with exit 1. F08 now records the provider-confirmed `applied_remote_at` after each write, so drift detection compares two provider timestamps; `applied_at` remains only a documented local-clock fallback. F12's VM scenarios (out-of-order poll/preview, in-flight save, CSRF retry, poll-while-saving) run on CI under `NODE_REQUIRED=1`; locally without Node they fall back to static ordering assertions. F20 adds the env-gated `rake test:integration` disposable Forgejo service test. F22 now drives status vocabulary, digest pills, and field help from `UiMetadata` with a planner/UI drift-guard test. Do not interpret older counts in the pre-fix review method as remediated-tree results.

## Post-fix status matrix

| Finding | Current status | Post-fix evidence or remaining limit |
|---|---|---|
| F01 | DONE | Apply A → rotate B → scaffold → plan update → apply B is covered end-to-end with a fake provider. |
| F02 | DONE | Env-aware display revision; rules-save revision is separately documented. |
| F03 | DONE | Scaffolding takes a sibling lock, validates generated YAML before atomic replacement, and preserves unsupported input. |
| F04 | DONE | Imports require `--only` plus exact repeated `--target SOURCE|CONTEXT|OWNER/REPO`; same-run ignores are excluded. |
| F05 | DONE | Atomic restrictive writes, directory sync, lock/transaction merge, process-concurrency and post-provider state-save failure tests. |
| F06 | DONE | Canonical role validation covers config, env, rules, state, fingerprint key, and CLI overrides. |
| F07 | DONE | Applied baselines require stable repository and source identities; legacy/unbound records are conservative. |
| F08 | DONE | `version_at` no longer bypasses the remote guard. Successful writes record the provider's own `updated_at` as `applied_remote_at`, so drift detection compares two provider timestamps; local `applied_at` is only a documented fallback and missing/invalid baselines are conservative. |
| F09 | DONE | Interactive confirmation or `--yes`, preflight, local-input/state revision checks, repository identity/admin recheck, per-write remote-secret recheck, structured partial failures. Provider CAS and rollback remain unavailable; failures are surfaced for manual recovery. |
| F10 | DONE | Keyed HMAC, independent expected vector, no fingerprint in UI, private/gitignored key, fail-closed key loss, and key-rotation warning. |
| F11 | DONE | HTTPS/userinfo validation, sanitized errors, concurrently drained GitHub pipes, and synthetic reflected-output tests. |
| F12 | DONE | Request sequences are allocated before requests and dirty/error handling is guarded. Node VM scenarios cover out-of-order poll/preview, edits during a save, CSRF retry, and poll-while-saving; CI sets `NODE_REQUIRED=1` so the dynamic path always executes there, with static ordering assertions as the local fallback. Still not a real-browser certification. |
| F13 | DONE | Assignment provenance and cross-source/visibility/repository-scope warnings use the effective assignment logic. |
| F14 | DONE | The UI remains a rules-only writer by design and now explains exact CLI review/apply handoff and confirmation. |
| F15 | DONE | Active definitions, not markers, determine management; helper ignores persist and apply immediately. |
| F16 | DONE | Shared inventory checks enforce source/selection/context coverage, truncation, identity, and a 24-hour age limit for plan/apply. |
| F17 | DONE | GitHub name/48-KB/100-secret limits, malformed/duplicate metadata, bounded discovery, and pagination totals are checked. |
| F18 | DONE | Strict dotenv grammar rejects malformed/duplicate material; tests include physical quoted newlines. |
| F19 | DONE | Readiness, missing/blocking apply outcomes, no-match filters, option values, trailing arguments, and noninteractive approval have truthful exit behavior. |
| F20 | DONE | Regression coverage now includes CLI/provider faults, rotation, persistence, Node VM async scenarios, and `rake test:integration` — an env-gated loopback-only disposable Forgejo service test that exercises the real adapter (`rake test:integration` skips cleanly without it). A full real-browser suite remains open by deliberate scope decision. |
| F21 | DONE | Ruby 3.4.10 is the declared/tested floor; CI requires pinned Semgrep. Local Semgrep absence is reported separately and fails closed when required. |
| F22 | DONE | Assignment, inventory validity, and file-role checks are shared; UI status vocabulary, digest pills, and field help now come from `UiMetadata` served via the API payload, with a drift-guard test asserting every planner action exists in `UiMetadata::STATUSES`. |


**The implementation is materially safer and more correct than the version assessed in the original review, but this is not a provider-service or browser certification.** Explicitly scoped scaffolding, atomic/locked state writes, keyed fingerprints, path-role validation, inventory freshness, safer apply approval/rechecks, and sanitized provider I/O are now implemented and tested with synthetic fixtures.

The remaining limits are explicit and inherent to the providers rather than open findings: GitHub cannot reveal secret values or provide compare-and-swap for these writes, so remote equality and write rollback remain impossible. The remote-newer guard compares provider timestamps; provider timestamp granularity means changes within the same second cannot always be distinguished. The browser is tested in a Node VM (enforced on CI), not a real browser. Forgejo is still pull-only; its service test is env-gated and loopback-only rather than part of the default suite. A provider write followed by local-state persistence failure is reported as partial failure and requires inventory/adoption recovery.

The report continues to focus on defects, safety boundaries, and the small changes needed to close them. It is not a recommendation to replace the application with a vault, Kubernetes operator, or general infrastructure framework.

### Priority convention

- **P1 — release-blocking for the stated goal:** incorrect reconciliation, avoidable credential distribution, data loss, or a broken supported workflow.
- **P2 — required hardening/usability work:** important limitations to fix before calling the tool simple, reliable, or safe for routine use.
- **P3 — structural/documentation cleanup:** reduce future drift and maintenance risk after the behavioral defects.

A priority describes impact in this project; it is not a CVSS rating. Findings marked **reproduced** were checked with synthetic data and temporary fixtures. **Code-confirmed** findings follow directly from the implementation. **Design gap** findings identify missing safeguards, not demonstrated exploitation.

## Original review method and limits (pre-fix)

- Read the CLI, configuration validation, dotenv parser, scaffold writer, rules store, inventory/applied state, planner/applier, both provider adapters, Rack endpoints, browser JavaScript, and the automated tests and CI configuration.
- Used relevant lessons in `../engineering-memory`, particularly adapter-contract testing, environment-file hygiene, immutable identifiers, SimpleCov instrumentation, runtime-floor mismatches, and atomic file persistence.
- Ran isolated Ruby and JavaScript checks outside the repository to verify suspected defects. They used synthetic values, temporary configuration/state, injected fakes, and the page's JavaScript in a Node VM. The JavaScript checks are deterministic function-level checks, **not** a real-browser certification.
- Did not read or reproduce actual secret values, execute production provider writes, run `scaffold` on the real config, change application code, or change local operational configuration.
- Examined primary documentation for GitHub CLI, Infisical syncs, External Secrets Operator, SOPS, and OWASP. This is a practice/function comparison, **not** an independent security audit of those tools. Only the cited SOPS implementation was additionally inspected directly.
- SonarQube/SonarCloud was not executed in this review. No service-side quality-gate result or CI run is claimed.

### Verification baseline — not a safety verdict

| Check | Observed result |
| --- | --- |
| Runtime used | Ruby 3.4.10 on arm64 macOS |
| `bundle exec rake test` | 98 tests, 580 assertions, no failures/errors/skips |
| SimpleCov report from that run | 1,209 / 1,493 lines, 80.97%; parent-process Ruby coverage only |
| `bundle exec rubocop` | 41 files, no offenses |
| `bundle exec bundler-audit check` | No known vulnerabilities against the existing local advisory database; no database update performed |
| `bundle exec rake flay` | Structural score 514; informational, not a duplication percentage |
| `bundle exec rake flog` | Total 2,756.3; `CLI#doctor` 100.6, `CLI#run` 91.8, `Planner#plan` 70.1 |
| `bundle exec rake semgrep` | Local rules completed without findings; only three Ruby rules are configured |

## P1 findings

### F01. Value rotation is not connected to reconciliation or the applied baseline — DONE (fixed)

**Status:** reproduced. **Evidence:** `lib/cred_align_flow/config.rb:238-252`, `planner.rb:96-139`, `applier.rb:25-35`, `state.rb:79-86`, `scaffolder.rb:104-116`.

`value_digest_status` compares the current local value with the YAML fingerprint. However, the planner considers versions/timestamps, not fingerprints. The applied record stores a version and application time, not the fingerprint of what was sent. `scaffold` replaces the YAML fingerprint without changing either applied state or version metadata.

Synthetic reproduction:

1. A previously applied target has version `v1` and an older remote timestamp.
2. YAML records the fingerprint of value A.
3. The env value becomes B, with the same version metadata.
4. Digest status becomes `changed`, but the plan says `ok`.
5. Run scaffold: the YAML digest becomes current for B; the plan still says `ok`.

The UI can therefore stop warning even though the provider still holds A. `apply --force` does not rescue this: the planner deliberately excludes `ok` items even with force.

**Required change:** distinguish desired/accepted local material from successfully applied material. Persist a protected fingerprint of the exact value sent **per source, repository identity, context, and secret** after a successful provider write. Compare current desired material with that applied fingerprint when planning. Scaffolding must never advance the applied baseline. Decide explicitly whether an unaccepted local rotation is blocked or actionable; make the UI/doctor/plan wording consistent with that policy. Label `ok` as metadata-based evidence, not proof of remote value equality.

**Required regression:** apply A to a fake provider, rotate to B without changing version, run scaffold, and verify that `plan`/`check` require an update; apply B and verify the target becomes current. Include partial application and missing values. A matching YAML digest alone must not satisfy this test.

### F02. Env-only changes are invisible to the page's auto-refresh revision — DONE (fixed)

**Status:** reproduced. **Evidence:** `config_editor.rb:14-17,34-46,73-78`, `config_ui.html:550-560`.

The revision contains YAML, rules, and inventory bytes, but not the env inputs used to render availability/digest status. The API recomputes those statuses, then the browser discards the response when `result.revision === view.revision`.

Reproduction: editing only the synthetic env value changed the returned digest status from `current` to `changed`, but the revision stayed identical. Adding or removing a value has the same invalidation problem. The page can keep presenting stale green status until some unrelated file changes or the user reloads.

**Required change:** separate the rules-write concurrency revision from a display revision, or make the display revision cover every rendered input. Avoid exposing an unkeyed aggregate digest of secret material as a new guessing oracle; use a private keyed digest, a generation token, or a safe change detector. Capture the env input consistently with the view. File-system metadata alone needs a documented limitation for same-size/rapid rewrites.

**Required regression:** edit only the env fixture while a clean page is open; verify the token availability and rotation status update. No YAML rewrite should be necessary, and no values/fingerprints should be logged.

### F03. Scaffolding can replace a valid configuration with invalid YAML — DONE (fixed)

**Status:** reproduced. **Evidence:** `scaffolder.rb:33-58,72-101,119-157,159-168`.

The writer uses regular expressions and unquoted interpolated YAML, then renames the result over the real file without validating the complete new configuration first.

Confirmed failures:

- `secrets: [] # user comment` is accepted initially, but the special case only recognizes an uncommented `secrets: []` line. Appending block items makes the result invalid.
- `secrets: [{name: REVIEW_TOKEN}]` is accepted initially, but the append produces incompatible flow/block sequence syntax.
- A valid configured source ID such as `main,other` becomes two separate IDs in generated `sources: [main,other]`, making the resulting configuration invalid.

Additional unsupported-looking forms are visible in the implementation: quoted top-level keys, single-quoted names, reordered fields instead of `- name:` first, YAML document boundaries, and inline comments on an existing name. Digest lookup silently misses several of these. They need explicit tests or rejection, not a claim of general YAML support.

**Required change:** perform format-aware edits, or define and enforce a deliberately restricted editable format. Validate the entire generated document and all rule references **before** replacement; on unsupported input, fail without touching the original bytes. Quote generated scalars correctly. Add a concurrency guard and preserve unrelated comments. Do not fix this by blindly dumping/reformatting a user's entire YAML document.

**Required regression:** cover empty lists with comments, inline populated lists, quoted keys/names, unusual valid source IDs, differing indentation, missing `secrets`, trailing document boundaries, and unsupported layouts. Verify both parse validity and byte preservation on failure.

### F04. Active imports are automatically assigned a much wider destination scope than the user reviewed — DONE (fixed)

**Status:** code-confirmed design gap. **Evidence:** `scaffolder.rb:24-28,72-92`, `cli.rb:171-190`, `config.rb:194-210`, `providers/github.rb:79-85`.

All unreferenced dotenv names, including helper fields and empty placeholders, become active secrets. Defaults include every configured source and every context supported by those providers, with public-repository scope. The command that accepts a rotated digest also imports any new helper variables. A later broad `apply` may distribute them across all selected public repositories and both GitHub secret stores.

**Active by default was explicitly requested. The defect is not activation itself; it is equating activation with account-wide/all-context distribution without destination review.** A runner registration credential, deployment key, host name, or path is not automatically appropriate for every public project's workflows. Public repository secrets are not directly public, but every receiving CI/workflow trust boundary gains access.

**Required change:** keep active-by-default imports, but require an explicit import selection and a reviewed source/context/repository template. Separate “import new names” from “accept changed values,” or provide an option that refreshes existing fingerprints only. Show the resolved destination count and names before activation/push. Make newly discovered repositories a deliberate policy decision rather than silently expanding an existing credential's audience. Provide a persistent exclusion for helper variables so deleted unwanted entries are not simply reimported.

**Required regression:** a helper variable added during rotation must not quietly acquire broad distribution. Test that only the selected names and reviewed scopes become actionable. Verify that future repository discovery does not widen restricted assignments unexpectedly.

### F05. Inventory/applied-state persistence is neither atomic nor protected from stale writers — DONE (fixed)

**Status:** reproduced and code-confirmed. **Evidence:** `state.rb:11-15,79-95`, `inventory.rb:12-43`, `applier.rb:25-35`, `config_editor.rb:60-68`.

`State#save!` directly truncates/writes the JSON file. An interrupted write can corrupt the only applied baseline; readers can encounter partial JSON. There is no lock or generation check. Two `State` instances can overwrite each other's updates. A UI inventory refresh and CLI apply can therefore lose application records.

A deterministic reproduction loaded two state objects, wrote an applied record through the first, then saved the stale second object. The record disappeared. Under umask `022`, a newly created state file was mode `0644` before the subsequent `chmod 0600`; private repository metadata is exposed during that creation window when the parent directory permits access.

**Required change:** create temporary files with restrictive permissions from the outset, flush/fsync and atomically replace, and coordinate all read-modify-write transactions. Lock a stable sibling lockfile rather than the inode that gets replaced. Prevent inventory refresh from overwriting a newer applied journal. Consider separating inventory from applied state or merging both under one explicit transaction. Test recovery and account for directory-fsync/durability needs on supported platforms.

**Required regression:** concurrent/stale writer, truncated-state read, interruption before/after replacement, failure after a successful provider write, and restrictive permissions at creation. Final-file permissions alone are insufficient evidence.

### F06. Path collision and filesystem identity checks are inconsistent between UI and CLI — DONE (fixed)

**Status:** reproduced validation gap; destructive consequences are code-confirmed, not executed on real files. **Evidence:** `config_validation.rb:12-17`, `config.rb:82-92`, `config_editor.rb:22-31,121-124`, `state.rb:88-95`.

The CLI only checks that file-path settings are nonempty strings. It does not enforce separation of config, env, rules, and state. A JSON-formatted configuration (also valid YAML) with `state_file` pointing to its own path loads successfully; a subsequent state save can replace the configuration contents.

The editor has an `expand_path` string comparison and a rules-symlink check, but this is not canonical filesystem identity validation. Different paths can refer to the same file through symlinks/hard links. State writes follow a target symlink; scaffold replacement can replace the symlink rather than updating its intended target.

**Required change:** centralize file-role/path checks for every entry point before any writes. Detect identical paths and existing aliases using appropriate canonical-path/inode checks; define whether each file role allows symlinks. Protect parent-directory permissions and fail before modifying any input on collision. Explicitly handle paths that do not yet exist.

**Required regression:** config/state and env/rules collisions, same file through aliases, nonexistent parents, and supported/unsupported symlink behavior. A temporary test must confirm original bytes survive the rejection.

### F07. Stored repository IDs do not protect ownership, rules, or applied records — DONE (fixed)

**Status:** reproduced. **Evidence:** `state.rb:23-36,75-85,132-134`, `rules.rb:59-64`, `config_view.rb:177-188`.

IDs are collected, but the state and rules are still keyed by source label and repository name. An applied record survives replacing a repository with a different stable ID at the same `owner/name`. The synthetic replacement was still planned as `ok`. Reusing a source ID for a different host/account also leaves old applied records reachable.

Renames lose the intended mapping; name reuse can attach old includes, excludes, or ownership to a different resource. An orphan include is not necessarily harmless: it can become live again if the old name is reused. Inventory refresh clears repository listings but does not invalidate the applied ownership records.

**Required change:** bind applied ownership to provider type, normalized endpoint/account identity, stable repository ID, context, and normalized secret name. Reject/migrate changed identities explicitly. Use name-to-ID mapping for display and intentional rename handling; do not blindly replay orphan rules onto a replacement repository.

**Required regression:** rename, transfer, deletion/recreation under the same name, host/account change behind the same source label, and rules with reused names. Replacement resources must require new adoption, not inherit `ok` or force-free overwrite permission.

### F08. Desired version time can suppress the remote-change overwrite guard — DONE (provider-confirmed baseline; local clock is fallback only)

**Status:** reproduced. **Evidence:** `planner.rb:118-139`, `state.rb:68-85`, `config.rb:217-223`.

The conflict comparison uses `max(applied_at, configured version_at)`. A version time edited after an external remote change, or accidentally set far in the future, can make that remote change look older than the baseline. With a new version label, the planner returns `update` and does not require force, despite the remote secret changing after the last local application.

The synthetic case used an old applied time, a newer remote time, and a future configured time. It was classified as `update`, not `remote_newer`.

**Required change:** separate desired revision time from observed remote ownership/conflict evidence. Record the actual provider timestamp/revision acknowledged after a successful write, rather than synthesizing one solely from the client clock. Reject/warn about future desired timestamps and unknown/missing applied baselines conservatively. Document unavoidable clock and provider-resolution limits.

**Required regression:** external remote update followed by a local version bump, future configured time, clock skew, equal-resolution timestamps, and invalid/missing applied timestamps. The user must not unknowingly bypass adoption/overwrite protection by editing desired metadata.

### F09. Apply is not bound to a reviewed, fully preflighted operation set — DONE (fixed)

**Status:** code-confirmed design gap. **Evidence:** `cli.rb:38-54`, `applier.rb:12-37`, `providers/github.rb:79-85`.

`apply` refreshes, prints a new plan, and immediately writes without binding execution to a previously reviewed plan. There is no input/repository-identity revision check at the write boundary. `gh secret set` creates **or updates**; a “create” target that appears after inventory may be overwritten without force. A multi-target plan can also mix pull-only, missing-value, or conflicting items with writable targets; blocking items are omitted from the actionable subset without a clear overall partial-result policy.

The applier checks provider writability up front, but secret/value checks happen inside the write loop. A later failure leaves earlier writes in place. It saves after each successful write, yet a save failure occurs after the remote side effect and lacks a durable recovery record. There is no structured attempted/succeeded/failed/skipped operation result.

**Required change:** preflight every selected operation before the first write, show an explicit exact-scope confirmation, and bind approval to the relevant config/rules/value generation and resource identities. Define whether mixed blocked plans abort or explicitly continue with a partial result. Recheck remote metadata close to writes; use provider conditional updates when available and clearly state where compare-and-swap is unavailable. Journal outcomes without values and support safe resume after partial failures. Do not promise rollback of write-only remote secrets, whose old values cannot be read back.

**Required regression:** one invalid item after a valid item, provider failure on the second target, local state-save failure after remote success, newly created remote secret between plan and write, and changes to rules/identity while approval is pending. Tests must use fakes or disposable services only.

## P2 findings

### F10. Plain SHA-256 fingerprints are sensitive verifiers, not automatically safe metadata — DONE (fixed)

**Status:** code-confirmed cryptographic/privacy design gap. **Evidence:** `config.rb:238-252`, `config_view.rb:35-40`, `scaffolder.rb:86,112,130`.

The current fingerprint is an unkeyed fast hash of a public prefix, known name, and value. Domain separation changes equal-value digests between names, but **does not prevent offline guesses**. Short passwords, hostnames, usernames, and other low-entropy imported values can be guessed by someone who acquires the YAML or API response. The browser receives the complete secret configuration, including each fingerprint, even though only status is displayed.

This is not a claim that SHA-256 is broken or that random high-entropy API tokens are easily recovered. It is a claim that the mixed dotenv import model makes “hashes are safe to share” an invalid assumption.

**Required change:** treat fingerprints as credential-derived sensitive data; exclude them from browser payloads, logs, public examples, and shareable diagnostics. Prefer a keyed HMAC using a private local key, with a migration/backup story, for local comparison. Alternatively restrict fingerprints to appropriate high-entropy material and document the limitation explicitly. A salt alone does not solve low-entropy guessing. Keep hash/fingerprint state private regardless of algorithm.

**Required regression:** API output contains statuses but no raw fingerprint; independent known vectors verify the algorithm/domain separation; key rotation/loss does not silently declare stale targets current. Do not only compute expected hashes through the same production helper being tested.

### F11. Provider transport and error propagation do not enforce the stated no-secret-leak guarantee — DONE (fixed)

**Status:** non-loopback HTTP acceptance reproduced; error-leak paths code-confirmed. **Evidence:** `providers/forgejo.rb:60-76,110-147`, `providers/github.rb:102-126,133-148`, `cli.rb:57-59`.

Forgejo accepts authenticated non-loopback HTTP URLs and sends the token in an Authorization header. URL userinfo is not rejected and can be repeated in diagnostics. HTTP error handling includes up to 300 bytes of provider response body; GitHub failures include arbitrary subprocess stderr and JSON parser details. The CLI emits these errors verbatim. Neither boundary guarantees redaction if a provider/proxy/debugging tool reflects secret material.

The normal successful path avoids values in argv, but that does not prove errors/logs never contain values. The existing unauthorized-response test only uses a harmless fixture message; it does not exercise reflected payloads or auth headers. GitHub subprocesses also inherit ambient environment except for selected auth variables, with no explicit overall command timeout or controlled diagnostic mode.

**Required change:** require HTTPS for authenticated remote hosts, with an explicit narrowly scoped loopback/disposable-test exception. Reject embedded credentials in URLs. Convert provider errors to structured sanitized messages, retaining only safe status/action metadata. Redact known values defensively before any terminal/log output, and avoid dumping bodies even in ordinary debug mode. Define allowed subprocess environment and bounded execution behavior; do not enable verbose provider logging by accident.

**Required regression:** reflected synthetic token/value in stderr or HTTP error body, credential-bearing URL, HTTP remote-host rejection, TLS failure, hung command, and diagnostic env flags. Verify all resulting output is safe.

### F12. Browser async operations can overwrite newer data or discard newer user edits — DONE (fixed)

**Status:** reproduced with the actual page functions in a deterministic Node VM. **Evidence:** `config_ui.html:206-217,224-251,512-571`; `config_editor.rb:49-57`.

The preview has a sequence counter; polling, save, load, and inventory refresh do not share an operation-generation model. Two demonstrated sequences:

- A poll starts on revision A. A newer result B is accepted. The delayed poll returns A, which differs from B, and the clean page accepts the older view.
- A save starts with draft A. The user makes draft B while the request is pending. The save response calls `acceptView`, resetting draft/baseline to A and discarding B.

Save/refresh buttons and controls are not comprehensively locked while mutations are in flight. Polling non-200 responses are silently ignored, so a once-working page can display old success during malformed config or server failure. After server restart the embedded CSRF token is stale; the data poll does not renegotiate it. The server's check-then-save is also not an atomic compare-and-swap: another writer can change rules between the final revision check and rename.

**Required change:** use a small explicit UI state machine and request generation/abort guards across all asynchronous operations. Preserve edits made after a request begins, or disable editing with a clear busy state. Distinguish clean, dirty, validating, saving, stale, offline/error, and changed-server-session states. Make stale-save conflicts actionable without instructing the user to save against an already obsolete revision. Coordinate server writers using a stable lock and compare under that lock.

**Required regression:** deliberately resolve polling/preview/save responses out of order; edit during save/refresh; restart the server; introduce invalid YAML after successful load; run two saves from one baseline. Assert no draft loss and no stale success indication.

### F13. “Use defaults” and exclusion help do not consistently match rule precedence — DONE (fixed)

**Status:** frontend behavior reproduced; backend fallback reproduced. **Evidence:** `config_ui.html:102-107,388-419`, `config.rb:144-165`, `config_view.rb:105-116`, `rules.rb:24-27`.

For a legacy YAML `repository_rules` include/exclude, choosing “Use token defaults” usually deletes the JSON override. The legacy YAML rule then remains effective. The client knows about legacy glob exclusions, but not the provenance of every legacy exact rule, so it cannot reliably distinguish “remove JSON override” from “explicitly override YAML with default.”

The help text says repository exclusions must never receive the token “regardless of rules,” but the implementation intentionally permits `include` and explicit `default` to override those exclusions. Only `exclude_sources` is absolute. A manual include can also override the token's default source/visibility scope, while it cannot select a repository excluded by source filters. These are materially different safety boundaries.

**Required change:** return rule provenance separately from effective rule mode. Write an explicit `default` when needed to cancel legacy intent. Clearly distinguish hard exclusions from overridable defaults, and show a warning when an include crosses default visibility/source scope. Disable or explain controls for source-unselected/read-only targets. Correct the field help and test it against effective backend behavior.

**Required regression:** YAML exact include/exclude, YAML glob exclusion, JSON override, “default” clearing each case, hard source exclusion, visibility-crossing include, and a source-unselected repo. Assert UI labels and actual plan agree.

### F14. The UI does not yet provide a complete, understandable user workflow — DONE (fixed)

**Status:** design gap. **Evidence:** `config_rack_app.rb:47-64`, `config_ui.html:81-137,338-350,455-510`, `config_server.rb:15-35`.

The page is a rules editor and metadata viewer, not a complete synchronization application. It cannot import missing env names, repair definitions, accept a rotation, or execute a push. It does not clearly expose provider write capability, distinguish local-value status from per-target applied status, provide a global action summary, or guide the user through a restricted command for the reviewed target set. A Forgejo target can appear assigned/create even though pushing it is prohibited. Orphan cleanup is described but has no control.

With many repositories/secrets, the page renders every repository times every secret, even for omitted assignments, without search/filtering or an impact-oriented summary. The backend repeatedly scans all planned items for each repo's unexpected items (`config_view.rb:198-203`). Each five-second poll fetches/builds the full view even when nothing changed.

**Required change:** define a simple workflow: review newly discovered names → understand effective scope → refresh provider metadata → see blocked/actionable counts → review an exact operation set → explicitly execute → see results. Preserve the established writer boundary: if the browser must remain rules-only, offer a safe scoped CLI handoff and clear instructions instead of silently adding YAML-write or apply endpoints. Show read-only provider capability and blocked reasons. Add search/filtering, visible pending-change/impact summaries, and a deliberate orphan-cleanup action. Optimize indexing/full polling only where necessary; no WebSocket is required.

For container/remote usage, document that the current loopback host/IP checks and HTTP origin policy are a local single-user design, not an authenticated remote dashboard. Do not simply bind it to a public interface to make Docker access work. Use a documented secure access model before claiming remote/UI portability.

**Required regression:** a UI-only user can identify a missing value, read-only provider, unimported variable, rotated value, orphan rule, and pending push, and find the next safe action without guessing whether “Save” changes the provider.

### F15. The promised env-to-definition sync is still manual, and marker matching hides legitimate names — DONE (fixed)

**Status:** manual behavior code-confirmed; prefix defect reproduced. **Evidence:** `scaffolder.rb:24-28,63-69`, `cli.rb:20-27,171-190`, `config_view.rb:12-23`.

Nothing observes env-name additions and runs scaffold automatically. UI polling only reloads existing definitions. Newly added variables therefore remain invisible until a CLI import. The marker check uses substring inclusion: a marker for `NEW_TOKEN_LONG` suppresses the unrelated `NEW_TOKEN`. A deleted/commented block with a retained marker can prevent reimport, and ignoring a managed secret's name as well as its `value_env` can conceal a separate dotenv name with a different meaning.

**Required change:** expose unrepresented names and explicit ignore status in the read-only API/UI. Make candidate detection exact and structured; treat a provenance comment as provenance, not the source of truth for active definitions. Decide and document whether importing is explicit or a separate trusted local watcher; the rules-only webserver should not covertly write YAML. If automated, avoid deleting hand-edited definitions when values disappear.

**Required regression:** prefix names, retained markers, deleted definitions, alias value refs, ignored helpers, empty variables, and newly added env names becoming visible without manual page reload.

### F16. Cached inventory can be treated as current after relevant configuration or coverage changes — DONE (fixed)

**Status:** context-gap acceptance reproduced; broader freshness limitations code-confirmed. **Evidence:** `cli.rb:113-157`, `state.rb:46-62`, `config_view.rb:67-82,206-227`.

Offline validation accepts `refreshed_contexts == nil` as complete without verifying every selected repo actually has the needed context. A configuration change adding a context after a prior unfiltered pull can therefore turn unobserved remote state into apparent “missing” secrets. The UI does a more detailed coverage check than the CLI, so the two entry points can disagree.

Selected repositories are cached rather than reselected from current source filters. There is no inventory fingerprint tying source host/account/filter inputs to the snapshot, nor freshness limit or prominent stale-age state. `inventory_state: current` primarily means a source/context is present, not that the data is recent or produced for the current definition.

**Required change:** use one shared inventory-validity calculation for UI and CLI. Record source identity, selection policy/context coverage, and observation time; invalidate or clearly mark snapshots when these inputs change. Unknown context data must never be interpreted as confirmed absence. Distinguish complete, partial, stale, wrong-source, and unavailable.

**Required regression:** add a context after full pull, remove a per-repo context from state, change source filters/host, and use an old snapshot. Verify both UI and offline CLI reject or mark the same uncertainty.

### F17. Provider constraints and inventory completeness are insufficiently validated — DONE (fixed)

**Status:** invalid GitHub-name acceptance reproduced; limits code-confirmed and checked against official documentation. **Evidence:** `config_validation.rb:109-138`, `providers/github.rb:57-85`, `inventory.rb:77-98`, `state.rb:39-43`.

GitHub stores secret names uppercase and treats names case-insensitively, but local uniqueness/lookups are case-sensitive. Config accepts both `token` and `TOKEN`, and accepts reserved `GITHUB_` names. A lowercase configured name may not match the uppercased remote record, repeatedly planning creation and treating the actual remote name as unexpected. Value-size/secret-count constraints are not preflighted.

GitHub discovery is capped at 1,000 repositories without detecting/reporting truncation. Forgejo pagination assumes short pages mean completion and lacks an explicit overall request/result bound. Secret-list responses are not subjected to the same typed validation as repository metadata; malformed/duplicated secret data can fail late or be collapsed silently.

**Required change:** implement provider-specific name normalization/uniqueness, reserved-name/size/limit validation, and typed response contracts before planning writes. Detect capped/truncated inventory and refuse to call it complete; paginate or demand explicit includes. Bound provider work and report rate-limit/completeness problems precisely.

**Required regression:** mixed-case names, reserved prefix, oversized value, malformed secret list, exactly-at-cap and beyond-cap discovery, repeated/short pagination, and duplicate remote records. The fake `gh` must validate supported fields/options rather than accepting any plausible request.

### F18. The homegrown dotenv parser silently misreads credential material — DONE (fixed)

**Status:** literal multiline key truncation reproduced. **Evidence:** `dotenv.rb:5-29`, `test/dotenv_test.rb:6-21`.

Parsing is line-by-line with limited quote/escape handling. A valid-looking quoted multiline private key is read as only the first line, retaining its opening quote, while continuation lines are ignored. Unmatched quotes and malformed names are silently accepted or dropped, and duplicate keys overwrite without notice. Interpolation is not implemented. An env reference containing a file path is treated as the literal value, not file content; imported `_FILE` variables can thus become pushed paths rather than the intended key material.

**Required change:** define and document an exact supported dotenv grammar and reject malformed/unsupported input with line numbers but no values. Preserve byte semantics for supported credentials, including newlines, CRLF, comments, whitespace, quotes, escapes, and duplicate policy. Keep shell interpolation off unless explicitly designed. Make file-content sources a separate explicit feature or exclude path helpers; never guess from a name and read arbitrary files automatically.

**Required regression:** complete synthetic multiline key, escaped newline variant, unmatched quote, duplicate name, comment after quote, CRLF, backslashes, empty value, and literal path helper. A partially parsed nonempty string must not be considered a valid ready-to-push key.

### F19. Doctor/CLI success and failure semantics can mislead users and automation — DONE (fixed)

**Status:** missing-value success and ignored extra positional arguments reproduced. **Evidence:** `cli.rb:9-16,57-59,64-101,194-240`.

`doctor` exits zero when managed values are missing or changed. It can print “all current” for recorded digests even if some statuses are `missing`, because only `changed` and `unrecorded` are counted. GitHub doctor runs `gh --version`, not an authentication/access check; Forgejo doctor prints a configured URL without contacting the service. The current success wording is stronger than the evidence.

Command discovery searches for any command word anywhere in argv, even an option value. Unknown/trailing positional arguments are not rejected after `parse!`; `help unexpected-positional-argument` succeeds. Filters that match nothing can likewise return success without distinguishing an intentional no-op from a typo. Filesystem errors outside the project's error hierarchy can escape as a stack trace.

**Required change:** define explicit exit/status semantics for readiness, partial/blocked apply, missing values, changed material, and no-match filters. Split offline config/value validation from opt-in authenticated provider readiness checks. Parse the command position predictably and reject leftover arguments. Handle expected file/permission errors at the proper boundary with sanitized actionable messages.

**Required regression:** missing/changed/current/missing-recorded digest cases, invalid command, option values named after commands, no-match selectors, unreadable files, unavailable `gh`, and reachable-versus-configured provider status. Assert exact failure reasons and exit codes, not only a generic error prefix.

### F20. Test quality has critical gaps; high line coverage is not workflow assurance — DONE (service suite env-gated; browser certification deliberately out of scope)

**Status:** test inspection and reproduced missing regressions. **Evidence:** `test/*_test.rb`, especially `state_test.rb:6-26`, `applier_test.rb:17-58`, `cli_test.rb:13-49,111-130`, `scaffolder_test.rb:24-87`, `config_server_test.rb:7-60`, `test_helper.rb:3-40,146-208`.

**Are the tests merely smoke tests? No.** Many config/planner/rules tests assert exact actions and precedence; GitHub subprocess tests exercise the real executable/adapter against an isolated fake and assert argv/stdin/auth behavior; Forgejo loopback tests assert HTTP path/auth/pagination/normalization. These are meaningful unit/workflow/contract tests, not real provider compatibility tests.

The deficiencies are nevertheless significant:

1. No automated test executes the browser DOM workflow, polling, response order, dirty-state protection, or CSRF recovery after restart. Rack call tests do not launch Itsi or execute JavaScript.
2. The newly added rotation tests stop at the YAML digest. They do not establish a subsequent plan or apply, allowing F01 to pass unnoticed.
3. `StateTest` has one happy-path test. Its `refute_includes ... "redacted"` is vacuous because that string was never supplied to the state. It checks final permissions, not private creation, atomicity, aliasing, or concurrent persistence.
4. `ApplierTest` has one happy-path fake write; no fault-injection/resume or partial outcome checks.
5. `test_appends_secrets_section_when_missing` actually supplies `secrets: []`; it does not test the missing-section branch. `test_scaffolds_unmanaged_env_vars_as_commented_entries` now expects active entries. Test names no longer describe coverage.
6. Help substring/error-prefix checks are smoke-like unless they also verify exact behavior or reason. They are insufficient for argument parsing, readiness, and provider validation.
7. The fake `gh` tolerates unsupported `--json` fields/options and uses simplified timestamps. It cannot independently detect all real command/API incompatibilities. The earlier `databaseId` problem demonstrates this limitation.
8. Provider registry tests mainly check method presence and construction. They are structural smoke/contract-shape tests, not shared behavioral contract tests for every provider.
9. There is a Docker Compose fixture but no executable real-service integration suite under `test/integration`; default Rake only runs `test/*_test.rb`. Do not equate fixture availability with tested provider semantics.
10. Existing fingerprint expectations often call the production fingerprint helper, leaving algorithm errors without an independent oracle.

**Coverage correction:** the reported CLI coverage is 10.0% and GitHub adapter 52.8%, but these numbers do **not** prove their subprocess workflows are untested. SimpleCov starts only in the parent test process; child `bin/cred-align-flow` processes do not load the instrumentation. Their executed lines are absent. `config_server.rb` is 35.7%; HTML/JavaScript are not represented at all. Scaffolder 97.9%, state 98.4%, and dotenv 100% still coexist with reproduced bugs because line execution does not test all input formats, sequences, or invariants. Branch coverage is not enabled.

**Required change:** build an invariant-led test matrix around F01–F19. Instrument/merge subprocess coverage safely with distinct worker/run identity, or report it separately rather than calling parent coverage the whole project. Enable meaningful branch reporting. Add deterministic UI tests and a small real-browser suite. Add env-gated disposable Forgejo integration for actual service compatibility; keep production write tests prohibited. Correct vacuous assertions and misleading names, and use independent expected values. Do not chase 100% line coverage or add a global coverage gate as a substitute for these tests.

### F21. The declared runtime/CI floor and security-check claims are not supported by the current setup — DONE (fixed)

**Status:** dependency constraints verified locally; CI/security limitations code-confirmed. **Evidence:** `Gemfile:5-18`, `Gemfile.lock:43,56,88,154-155`, `.github/workflows/ci.yml:14-36,38-63`, `Rakefile:36-50`, `.semgrep.yml:9-52`.

The advertised development/test floor includes Ruby 3.2, but locked `simplecov 1.3.2`, `parallel 2.3.0`, and `rbs 4.2.0` require Ruby >= 3.3. Their installed gem specifications confirm the conflict. Bundler itself is locked at 4.0.21 and also needs validation against the intended matrix. A local Ruby 3.4 green suite does not establish the Ruby 3.2 bundle can install. The command-line runtime may remain stdlib-compatible; this finding concerns the documented bundle/UI/test setup and matrix.

Semgrep is not installed in the CI workflow and the Rake task skips it when absent. Therefore CI can report a green “checks” step with no security scan. When present, the configuration only addresses Ruby eval, selected command forms, and selected regex risk; it does not inspect the application's reconciliation, browser state machine, credential propagation, or filesystem races. Sonar is conditional on a secret and does not by itself establish an enforced quality-gate result.

**Required change:** choose an honest supported runtime floor and align documentation, CI, lock resolution, UI packaging, and RuboCop. If retaining a supported older floor, constrain incompatible development gems and verify install/test on that floor; otherwise raise it deliberately. Install/pin the intended security scanner in CI and report required versus optional checks separately. Preserve local/offline/no-upload policy and do not scan real ignored secrets. Add relevant rules/negative fixtures, but do not describe scanner cleanliness as a complete safety audit.

## P3 structural finding

### F22. Behavior and documentation are drifting because important policy has multiple implementations — DONE (fixed)

**Status:** code-confirmed. **Evidence:** `cli.rb:9-101,171-241`, `config_view.rb:67-82,105-130,206-229`, `planner.rb:22-59,96-139`, `applier.rb:53-60`, `config_ui.html:267-280,383-408`, `.rubocop.yml:20-52`, `README.md:126-129,226-255`.

Defaults, action eligibility, context coverage, rule interpretation, digest wording, and field help are spread across Ruby orchestration, view construction, JavaScript, and documentation. Divergence is already observable: UI versus CLI context validation, digest status versus plan, hard/soft exclusions in help, and the incomplete rotation instructions. Complexity exclusions hide growth in the most consequential orchestration methods; the newly expanded doctor scores 100.6 in flog. A low duplication score would not detect these semantic inconsistencies.

The application currently eagerly loads web backend classes even for ordinary CLI calls. Core config validation also branches on provider type despite the registry abstraction. These are not reasons for a large rewrite, but they make the advertised provider-agnostic boundary less clean.

**Required change:** introduce only the small shared abstractions that prevent demonstrated inconsistencies: one effective-assignment model, one inventory-validity model, one reconciliation/applied-baseline model, one file-role/persistence boundary, and centralized field metadata/capabilities for UI help. Split CLI dispatch/readiness reporting and browser request state from rendering where that improves testability. Reduce exemptions through focused simplification, not new frameworks. Update README and engineering-memory alongside behavioral fixes so incorrect acceptance/push claims do not become institutional knowledge.

## Comparisons: practices to borrow, not entire platforms

### GitHub CLI

Primary sources: [secret set](https://cli.github.com/manual/gh_secret_set), [repo list](https://cli.github.com/manual/gh_repo_list), [GitHub secrets reference](https://docs.github.com/en/actions/reference/security/secrets).

- `gh secret set` uses explicit repository/environment/organization destination flags, reads values from stdin, and locally encrypts values before sending them. cred-align-flow should retain the argv/stdin separation but add its own exact-scope approval and provider-specific validation.
- GitHub's organization-secret visibility is `all/private/selected`, not this project's `public/private/all` repository filter. Clarify that difference; do not imply the local field is a remote secret privacy setting.
- Names are uppercased/case-insensitive, reserved prefixes apply, values have size limits, and secret stores have count limits. These must be reflected in preflight tests rather than delegated to late write failures.
- `gh repo list --limit` is a cap, not evidence of complete inventory. Test and report that distinction.

### Infisical GitHub secret sync

Primary source: [GitHub sync documentation](https://infisical.com/docs/integrations/secret-syncs/github).

- Its setup separates source environment/path, connection, destination scope, options, and final review. Borrow that progressive review model and explicit sync-status/last-sync outcome, not its SaaS architecture.
- Key schemas help bound the keys it owns. cred-align-flow needs equally explicit ownership/import selection.
- Automatic sync and destination deletion are separate controls. The documented overwrite behavior can delete keys absent from the source; **do not copy that default**. Keep unknown remote secrets report-only and remote pushes explicitly approved.
- GitHub secrets cannot be imported/read back as values. Neither this tool nor an alternative can legitimately promise equality verification from a names/timestamps API alone.

### External Secrets Operator / PushSecret

Primary sources: [push policies](https://external-secrets.io/latest/guides/pushsecrets/) and [refresh/ownership/deletion lifecycle](https://external-secrets.io/latest/guides/ownership-deletion-policy/).

- Separates desired spec from observed status and distinguishes refresh, update/ownership, and deletion policy. This is the missing conceptual boundary behind F01 and the current “Save/active/current” ambiguity.
- PushSecret distinguishes `Replace` from `IfNotExists` and defaults deletion to `None`. Borrow explicit adoption/overwrite/retention policy. Do not interpret lack of overwrite as proof values match.
- Refresh policy is explicit and scoped to selected inputs/destinations; page refresh is not secret reconciliation.
- Kubernetes/controller complexity is unnecessary here. A small local desired/observed model and operation journal can implement the relevant safeguards.

### SOPS

Primary sources: [project overview](https://github.com/getsops/sops) and [document-tree/encrypted-MAC implementation](https://github.com/getsops/sops/blob/main/sops.go).

- SOPS separates structured metadata from encrypted material and validates document integrity using a protected MAC. A plain fast digest in public/shareable metadata is not an equivalent protection.
- Consider optional interoperability for encrypted-at-rest value sources later rather than inventing encryption. This is not a prerequisite for fixing reconciliation, and does not require merging plaintext values into YAML.
- Continue to minimize browser and diagnostic exposure even when local storage is encrypted.

### OWASP guidance

Primary source: [Secrets Management Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Secrets_Management_Cheat_Sheet.html).

Relevant gaps here are least-privilege distribution, correct rotation lifecycle, TLS for credential-bearing transport, safe audit/error handling, and usable but explicit approval. A personal local tool need not implement every enterprise vault feature, but its threat model must state that plaintext local values, same-user processes, backups, and destination workflows are trust boundaries. “Gitignored and 0600” is not encrypted storage or a complete safety claim.

## Original minimum test matrix (pre-fix review)

The rows below record the original review's recommended evidence, not a claim that every item is still open. See the post-fix status matrix above. Remaining independent assurance includes running the Node VM path on a Node-enabled runner, adding a full browser workflow, and exercising the adapter against the disposable Forgejo service; no GitHub provider writes should be used for this.

| Invariant | Minimum evidence needed |
| --- | --- |
| Rotation remains pending until the exact target received the new value | Fake-provider apply A → rotate B → scaffold → plan/check → apply B → current |
| Env-only change reaches the browser | API revision/display generation + DOM/browser polling test |
| YAML mutation never destroys a valid unsupported document | Format matrix + validate-before-rename + original-byte preservation |
| Import cannot widen scope unnoticed | Selected candidate/template tests + target-impact confirmation |
| Applied history survives interruption/concurrency | State fault injection + stale-writer/lock tests |
| Repository replacement never inherits ownership | Stable-ID and source-identity migration/rejection tests |
| Remote change guard is independent of desired time | Clock-skew/future-time/adoption tests |
| Partial writes are visible and resumable | Provider error + state-save error + structured outcome tests |
| UI never discards a later edit/accepts an older response | Deferred promises/operation-generation tests + browser save/refresh flows |
| Rules help and controls match effective scope | Backend precedence + frontend default/legacy/hard-exclusion cases |
| Provider I/O is bounded, validated, and sanitized | Name/size/limit, timeout, reflected-error, TLS and pagination tests |
| Parser never silently sends a truncated credential | Dotenv grammar + multiline/escape/duplicate/path tests |
| Supported runtime can install and run the suite | Actual frozen bundle install/test on each advertised floor |
| Coverage represents its stated scope | Child-process instrumentation/merge validation + separate JS coverage |

## Remaining follow-up

1. Record provider-confirmed application revisions where an API supports them. GitHub currently exposes metadata, not secret values or conditional writes, so keep the local-clock limitation and force/review boundary explicit.
2. Run the embedded UI response-order test on a Node-enabled runner and add a full browser workflow for dirty edits, CSRF retry, and save/refresh interleavings.
3. Add an executable, environment-gated Forgejo test against the disposable Compose service. The default suite must stay offline, and the current Forgejo adapter remains pull-only.
4. Consolidate duplicated field/capability help only where a shared model reduces demonstrated drift; do not introduce a general metadata framework for its own sake.
5. Keep the state-save failure path explicit: after provider success but local journal failure, refresh inventory and review/adopt before retrying. Remote rollback is not available.

## Engineering-memory implications

The review reuses, but also qualifies, existing memory:

- `patterns/adapter-contract-testing.md`: fake executables/loopback servers test the application's contract, not provider service correctness. Registry method-presence checks alone are weaker than shared behavioral contracts.
- `tools/simplecov.md` and `lessons-learned/simplecov-merge-timeout-drops-parallel-workers.md`: executed child code needs its own instrumentation and correctly merged run identities; raising merge timeout alone cannot collect an uninstrumented process.
- `lessons-learned/coverage-never-fail-suite.md`: do not replace missing safety tests with an arbitrary global coverage gate.
- `lessons-learned/dep-bump-breaks-ci-runtime-floor.md`: this project's locked development gems repeat that verified runtime-floor mismatch.
- `lessons-learned/url-keyed-data-orphans-on-rename.md`: collecting stable IDs is not enough; lookup and ownership must use/validate them.
- `lessons-learned/docker-bind-mount-breaks-atomic-rewrite.md`: directory mounts remain the appropriate unit for replace-by-rename writers. State writes now use atomic replacement and lock-protected reload/merge transactions; provider I/O is not performed while holding the shared state lock.
- The scaffold workflow now requires explicit names and exact destinations. Local acceptance of a new HMAC digest is distinct from recording a per-target applied baseline; provider success followed by local state failure still requires manual refresh/adoption recovery.

The follow-up remediation and test evidence are recorded in engineering-memory. No production provider writes or local operational-config changes were made.
