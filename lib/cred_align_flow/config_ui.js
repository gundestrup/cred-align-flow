let csrfToken = document.querySelector('meta[name="cred-align-csrf"]').content;
const message = document.getElementById("message");
let view;
// The draft mirrors the UI-managed files' editable sections: the
// rules file's rules and token_defaults, plus the two preset
// libraries. All of them post together so a save is always
// internally consistent.
let baseline = { rules: {}, token_defaults: {}, token_presets: {}, repo_presets: {} };
let draft = { rules: {}, token_defaults: {}, token_presets: {}, repo_presets: {} };
let previewValid = true;
let previewPending = false;
let previewSequence = 0;
let previewTimer;
// Every view-producing request gets a sequence number; a response may
// only replace the page state when it is newer than every response
// already applied, so out-of-order delivery can never restore an
// older view or discard a newer draft.
let issuedSequence = 0;
let appliedSequence = 0;
let saving = false;
let refreshing = false;
let lastStaleWarning = null;
let updateCheckStarted = false;

function element(name, className, text) {
  const node = document.createElement(name);
  if (className) node.className = className;
  if (text !== undefined && text !== null) node.textContent = String(text);
  return node;
}

function copy(value) {
  return JSON.parse(JSON.stringify(value));
}

function setMessage(text, kind) {
  message.textContent = text || "";
  message.className = `message ${kind || ""}`;
}

function isDirty() {
  return JSON.stringify(draft) !== JSON.stringify(baseline);
}

function updateButtons() {
  document.getElementById("save").disabled = !isDirty() || !previewValid || previewPending || saving || refreshing;
  document.getElementById("cancel").disabled = saving || refreshing;
  document.getElementById("refresh-inventory").disabled = saving || refreshing;
}

function requestOptions(body) {
  return {
    method: "POST",
    cache: "no-store",
    headers: {
      "Content-Type": "application/json",
      "X-Cred-Align-Token": csrfToken
    },
    body: JSON.stringify(body)
  };
}

async function post(path, body) {
  const response = await fetch(path, requestOptions(body));
  const result = await response.json();
  if (response.status === 403 && !post.retriedCsrf) {
    post.retriedCsrf = true;
    await refreshCsrfToken(); // picks up a fresh csrf token after a server restart
    return post(path, body);
  }
  post.retriedCsrf = false;
  if (!response.ok) {
    const error = new Error(result.error || "Request failed");
    error.status = response.status;
    throw error;
  }
  return result;
}

async function refreshCsrfToken() {
  const response = await fetch("/api/data", { cache: "no-store" });
  const result = await response.json();
  if (!response.ok) throw new Error(result.error || "Could not refresh the config UI request token");
  if (result.csrf) csrfToken = result.csrf;
}

async function fetchData() {
  const sequence = ++issuedSequence;
  const response = await fetch("/api/data", { cache: "no-store" });
  const result = await response.json();
  if (sequence <= appliedSequence) return null;
  appliedSequence = sequence;
  if (result.csrf) csrfToken = result.csrf;
  if (!response.ok) {
    const error = new Error(result.error || "Could not load configuration");
    error.status = response.status;
    throw error;
  }
  return result;
}

async function loadData() {
  const result = await fetchData();
  if (result) acceptView(result, { applyRules: true });
}

// applyRules controls whether the draft form resets to the saved
// rules; a save/preview response must never discard edits made while
// the request was in flight.
function acceptView(result, { applyRules }) {
  if (result.csrf) csrfToken = result.csrf;
  view = result;
  if (applyRules) {
    baseline = viewSections(result);
    draft = copy(baseline);
    previewValid = true;
    previewPending = false;
  }
  document.getElementById("config-file").textContent =
    `Config ${result.config_file} (read-only) · rules file ${result.rules_file} · inventory last refreshed ${result.generated_at || "never"}.`;
  renderAll();
  updateButtons();
  void checkForUpdate();
}

async function checkForUpdate() {
  const indicator = document.getElementById("update-indicator");
  if (!view.check_for_updates) {
    indicator.hidden = true;
    return;
  }
  if (updateCheckStarted) return;

  updateCheckStarted = true;
  try {
    const response = await fetch("/api/update", { cache: "no-store" });
    if (!response.ok) return;

    const result = await response.json();
    if (!result.update_version) return;

    document.getElementById("update-version").textContent = result.update_version;
    indicator.href = `https://github.com/gundestrup/cred-align-flow/releases/tag/${encodeURIComponent(result.update_version)}`;
    indicator.hidden = false;
  } catch (_) {
    return;
  }
}

// Tab switching is pure CSS: hidden radio inputs + body:has() rules.
// #repo-N-N anchor links remain untouched by the tab state.

function renderAll() {
  renderHelp();
  renderTokens();
  renderPresets();
  renderUnimported();
  renderSummary();
  renderPreview();
}

function markChanged() {
  previewValid = false;
  previewPending = true;
  updateButtons();
  setMessage("Checking the draft changes against the configuration…");
  clearTimeout(previewTimer);
  const sequence = ++previewSequence;
  previewTimer = setTimeout(() => previewDraft(sequence), 300);
}

// The editable sections a view payload carries; missing keys
// (older payloads, minimal fixtures) mean empty sections.
function viewSections(result) {
  return {
    rules: copy(result.rules || {}),
    token_defaults: copy(result.token_defaults || {}),
    token_presets: copy(result.token_presets || {}),
    repo_presets: copy(result.repo_presets || {})
  };
}

// All editable sections post together; the server validates the
// combined candidate documents, not each section in isolation.
function draftPayload(revision) {
  return {
    revision: revision,
    rules: draft.rules || {},
    token_defaults: draft.token_defaults || {},
    token_presets: draft.token_presets || {},
    repo_presets: draft.repo_presets || {}
  };
}

async function previewDraft(sequence) {
  const viewSequence = ++issuedSequence;
  try {
    const result = await post("/api/preview", draftPayload(view.revision));
    if (sequence !== previewSequence) return;
    if (result.csrf) csrfToken = result.csrf;
    if (viewSequence > appliedSequence) {
      appliedSequence = viewSequence;
      acceptView(result, { applyRules: false });
    }
    previewValid = true;
    setMessage("Draft changes are valid. Save writes them to the local rules and preset files.", "success");
  } catch (error) {
    if (sequence !== previewSequence) return;
    previewValid = false;
    setMessage(error.message, "error");
  } finally {
    if (sequence === previewSequence) {
      previewPending = false;
      updateButtons();
    }
  }
}

function readOnlyField(container, labelText, value) {
  const field = element("div", "field");
  field.append(element("span", "field-label", labelText));
  field.append(element("span", "", value || "—"));
  container.append(field);
}

// ---- token defaults editing -------------------------------------
// Controls edit a sparse draft overlay: a key present in
// draft.token_defaults[name] replaces that YAML field; keys absent
// inherit the YAML value (or the built-in default). Setting a field
// back to its YAML value prunes the key so the file stays minimal.

function normValue(value) {
  if (Array.isArray(value)) return value.map(String).slice().sort((a, b) => a.localeCompare(b));
  if (value && typeof value === "object") {
    const out = {};
    Object.keys(value).sort((a, b) => a.localeCompare(b)).forEach((key) => { out[key] = normValue(value[key]); });
    return out;
  }
  return value;
}

function sameScopeValue(a, b) {
  return JSON.stringify(normValue(a)) === JSON.stringify(normValue(b));
}

// Targets normalized to an explicit { type: [contexts] } map using the
// same built-in default the config layer applies (github → actions).
function normalizedTargets(fields) {
  const normalized = {};
  Object.keys(view.provider_contexts || {}).forEach((type) => {
    normalized[type] = targetsChecked(fields, type);
  });
  return normalized;
}

// The YAML-level value for a scope field, applying the same built-in
// defaults the config layer uses when the key is absent.
function yamlFieldDefault(entry, key) {
  const yaml = entry.yaml || {};
  if (key === "targets") return normalizedTargets(yaml);
  if (yaml[key] !== undefined) return yaml[key];
  if (key === "exclude_repositories" && yaml.exclude_repos !== undefined) return yaml.exclude_repos;
  if (key === "visibility") return "public";
  if (key === "sources") return ["all"];
  return undefined;
}

// Effective draft state for a scope field: draft overlay, then saved
// overlay (via yaml merge order), then the YAML/built-in value.
function effectiveFields(entry) {
  const name = (entry.config || {}).name;
  const overlay = (draft.token_defaults || {})[name] || {};
  return Object.assign({}, entry.yaml || {}, overlay);
}

function setTokenDefaultField(entry, key, value) {
  const name = entry.config.name;
  const defaults = draft.token_defaults = draft.token_defaults || {};
  const fields = defaults[name] = defaults[name] || {};
  if (value === undefined || sameScopeValue(yamlFieldDefault(entry, key), value)) delete fields[key];
  else fields[key] = value;
  if (Object.keys(fields).length === 0) delete defaults[name];
  markChanged();
}

function resetTokenDefaults(name) {
  if (draft.token_defaults) delete draft.token_defaults[name];
  markChanged();
  renderTokens();
}

function applyPreset(tokenName, presetName) {
  const fields = (draft.token_presets || {})[presetName];
  if (!fields) return;
  const defaults = draft.token_defaults = draft.token_defaults || {};
  defaults[tokenName] = Object.assign({}, defaults[tokenName] || {}, copy(fields));
  markChanged();
  renderTokens();
}

function sourcesChecked(fields) {
  const raw = fields.sources;
  if (raw === undefined || raw === null) return { all: true, ids: [] };
  const list = (Array.isArray(raw) ? raw : [raw]).map(String);
  if (list.length === 0 || list.includes("all")) return { all: true, ids: [] };
  return { all: false, ids: list };
}

function targetsChecked(fields, type) {
  const targets = fields.targets;
  if (targets === undefined || targets === null) return type === "github" ? ["actions"] : [];
  const raw = targets[type];
  if (raw === undefined || raw === null) return type === "github" ? ["actions"] : [];
  if (Array.isArray(raw)) return raw.map(String);
  if (raw && typeof raw === "object") return Object.keys(raw).filter((name) => raw[name] === true);
  return [];
}

function exclusionsText(fields) {
  const raw = fields.exclude_repositories;
  if (raw === undefined || raw === null) return "";
  if (Array.isArray(raw)) return raw.join(", ");
  if (typeof raw === "string") return raw;
  if (raw && typeof raw === "object") {
    return Object.entries(raw).map(([source, patterns]) => `${source}: ${[].concat(patterns).join(", ")}`).join("; ");
  }
  return "";
}

// Shared editor for the four overridable scope fields, used by token
// cards and preset cards. setField(key, value) receives undefined to
// clear a field.
function scopeEditor(fields, setField, overriddenKeys) {
  const wrap = element("div", "field-grid");
  const overridden = overriddenKeys || {};

  const visField = element("div", "field");
  const visLabel = element("span", "field-label", "Visibility");
  if (overridden.visibility) visLabel.append(element("span", "override-tag", "override"));
  visField.append(visLabel);
  const visSelect = document.createElement("select");
  ["public", "private", "all"].forEach((value) => {
    const option = element("option", "", value);
    option.value = value;
    option.selected = (fields.visibility || "public") === value;
    visSelect.append(option);
  });
  visSelect.addEventListener("change", () => setField("visibility", visSelect.value));
  visField.append(visSelect);
  wrap.append(visField);

  const srcField = element("div", "field");
  const srcLabel = element("span", "field-label", "Sources");
  if (overridden.sources) srcLabel.append(element("span", "override-tag", "override"));
  srcField.append(srcLabel);
  const checked = sourcesChecked(fields);
  const row = element("div", "check-row");
  // "All" writes ["all"]; unchecking it materializes every configured
  // source as an explicit selection so individual boxes can be
  // deselected. Presets may name sources that no longer exist — those
  // render as deselectable "(not configured)" rows.
  const sourceIds = (view.sources || []).map((source) => source.id);
  const allLabel = element("label", "");
  const allBox = document.createElement("input");
  allBox.type = "checkbox";
  allBox.checked = checked.all;
  allLabel.append(allBox, document.createTextNode("All configured sources"));
  allBox.addEventListener("change", () => {
    setField("sources", allBox.checked ? ["all"] : sourceIds.slice());
  });
  row.append(allLabel);
  const listed = checked.all ? sourceIds.slice() : checked.ids;
  sourceIds.concat(listed.filter((id) => !sourceIds.includes(id))).forEach((sourceId) => {
    const label = element("label", "");
    const box = document.createElement("input");
    box.type = "checkbox";
    box.checked = listed.includes(sourceId);
    box.disabled = checked.all;
    const known = sourceIds.includes(sourceId);
    label.append(box, document.createTextNode(known ? sourceId : `${sourceId} (not configured)`));
    box.addEventListener("change", () => {
      const ids = box.checked
        ? listed.concat([sourceId])
        : listed.filter((id) => id !== sourceId);
      setField("sources", ids.length ? ids : ["all"]);
    });
    row.append(label);
  });
  srcField.append(row);
  srcField.append(element("span", "scope-note", checked.all
    ? "Applies to all configured sources."
    : "Deselecting every source applies to all sources."));
  wrap.append(srcField);

  const tgtField = element("div", "field");
  const tgtLabel = element("span", "field-label", "Targets");
  if (overridden.targets) tgtLabel.append(element("span", "override-tag", "override"));
  tgtField.append(tgtLabel);
  Object.keys(view.provider_contexts || {}).forEach((type) => {
    const contexts = view.provider_contexts[type] || [];
    const selected = targetsChecked(fields, type);
    const typeRow = element("div", "check-row");
    contexts.forEach((context) => {
      const label = element("label", "");
      const box = document.createElement("input");
      box.type = "checkbox";
      box.checked = selected.includes(context);
      label.append(box, document.createTextNode(`${type}: ${context}`));
      box.addEventListener("change", () => {
        const targets = normalizedTargets(fields);
        targets[type] = box.checked
          ? selected.concat([context]).filter((v, i, a) => a.indexOf(v) === i)
          : selected.filter((name) => name !== context);
        setField("targets", targets);
      });
      typeRow.append(label);
    });
    if (contexts.length === 0) typeRow.append(element("span", "scope-note", `${type}: no contexts`));
    tgtField.append(typeRow);
  });
  wrap.append(tgtField);

  const exField = element("div", "field");
  const exLabel = element("span", "field-label", "Exclude repositories");
  if (overridden.exclude_repositories) exLabel.append(element("span", "override-tag", "override"));
  exField.append(exLabel);
  const exInput = element("input", "");
  exInput.type = "text";
  exInput.placeholder = "owner/repo, owner/other…";
  exInput.value = exclusionsText(fields);
  exInput.addEventListener("change", () => {
    const list = exInput.value.split(",").map((part) => part.trim()).filter(Boolean);
    setField("exclude_repositories", list.length ? list : undefined);
  });
  exField.append(exInput);
  wrap.append(exField);

  return wrap;
}

// Tokens sharing a PREFIX_ before their first underscore are grouped
// under that prefix when at least three share it; groups and
// ungrouped tokens interleave alphabetically by name.
function tokenPrefix(name) {
  const match = (name || "").match(/^([^_]+)_/);
  return match ? match[1] : null;
}

function groupedTokens(entries) {
  const sorted = entries.slice().sort(
    (a, b) => ((a.config || {}).name || "").localeCompare((b.config || {}).name || "")
  );
  const counts = {};
  sorted.forEach((entry) => {
    const prefix = tokenPrefix((entry.config || {}).name);
    if (prefix) counts[prefix] = (counts[prefix] || 0) + 1;
  });
  const units = [];
  const groups = {};
  sorted.forEach((entry) => {
    const prefix = tokenPrefix((entry.config || {}).name);
    if (!prefix || counts[prefix] < 3) {
      units.push({ title: null, entries: [entry] });
      return;
    }
    if (!groups[prefix]) {
      groups[prefix] = { title: prefix, entries: [] };
      units.push(groups[prefix]);
    }
    groups[prefix].entries.push(entry);
  });
  return units;
}

// Repositories where a token is currently assigned, built by reversing
// the per-repo assignment lists the view already computes (so draft
// edits reflect after a preview).
function tokenRepoRows(secretName) {
  const rows = [];
  (view.sources || []).forEach((source) => {
    (source.repositories || []).forEach((repo) => {
      const assigned = (repo.assigned || []).find((entry) => entry.name === secretName);
      if (assigned) {
        rows.push({ source: source.id, repo: repo.name, origin: assigned.origin, contexts: assigned.contexts || [] });
      }
    });
  });
  return rows;
}

function tokenEnabledDetails(secretName) {
  const rows = tokenRepoRows(secretName);
  if (rows.length === 0) {
    return element("p", "empty small", "Not assigned to any repository in the current inventory.");
  }
  const details = element("details", "fold");
  details.append(element("summary", "", `Enabled on ${rows.length} ${rows.length === 1 ? "repository" : "repositories"}`));
  rows.forEach((row) => {
    const line = element("div", "assignment-row");
    line.append(element("strong", "", `${row.source} · ${row.repo}`));
    const origin = element("span", `origin ${row.origin === "manual" ? "origin-manual" : "origin-default"}`,
      row.origin === "manual" ? "Manual" : "Default");
    line.append(origin);
    const contexts = element("span", "small");
    row.contexts.forEach((context, index) => {
      if (index) contexts.append(document.createTextNode(" · "));
      contexts.append(document.createTextNode(`${context.name}: `));
      const status = element("span", statusClass(context.action), context.action.replaceAll("_", " "));
      status.title = context.detail || "";
      contexts.append(status);
    });
    line.append(contexts);
    details.append(line);
  });
  return details;
}

function tokenCard(entry, presetNames) {
  const secret = entry.config || {};
  const card = element("article", "token-card");
  const title = element("div", "token-title");
  title.append(element("h3", "", secret.name || "(unnamed token)"));
  const digestStatus = entry.value_digest_status;
  const pills = (view.meta && view.meta.value_pills) || {};
  const pillKey = !entry.value_available ? "missing" : (pills[digestStatus] ? digestStatus : "ready");
  const pill = pills[pillKey] || { css: "value-ready", label: "Local value is set" };
  title.append(element("span", `status-pill ${pill.css}`, pill.label));
  card.append(title);

  const overrides = (draft.token_defaults || {})[secret.name] || {};
  if (Object.keys(overrides).length) {
    const note = element("p", "small muted");
    note.append(element("span", "override-tag", "rules-file defaults"));
    note.append(document.createTextNode(" These fields override the YAML defaults; the YAML file is unchanged."));
    const reset = element("button", "orphan-remove", "Reset to YAML defaults");
    reset.addEventListener("click", () => resetTokenDefaults(secret.name));
    note.append(reset);
    card.append(note);
  }

  if (presetNames.length) {
    const presetRow = element("p", "small");
    presetRow.append(element("span", "field-label", "Apply preset: "));
    const select = document.createElement("select");
    const placeholder = element("option", "", "choose a preset…");
    placeholder.value = "";
    select.append(placeholder);
    presetNames.forEach((presetName) => {
      const option = element("option", "", presetName);
      option.value = presetName;
      select.append(option);
    });
    select.addEventListener("change", () => applyPreset(secret.name, select.value));
    presetRow.append(select);
    card.append(presetRow);
  }

  const fields = element("div", "field-grid");
  readOnlyField(fields, "Value environment variable", secret.value_env || secret.name);
  readOnlyField(fields, "Version", secret.version || "1");
  readOnlyField(fields, "Version time", secret.version_at || secret.updated_at || "unset");
  const excludedSources = Array.isArray(secret.exclude_sources) ? secret.exclude_sources.join(", ") : "";
  if (excludedSources) readOnlyField(fields, "Excluded sources (YAML, always wins)", excludedSources);
  card.append(fields);

  card.append(tokenEnabledDetails(secret.name));

  card.append(scopeEditor(
    effectiveFields(entry),
    (key, value) => { setTokenDefaultField(entry, key, value); renderTokens(); },
    overrides
  ));
  return card;
}

function renderTokens() {
  const container = document.getElementById("tokens");
  container.replaceChildren();
  const presetNames = Object.keys(draft.token_presets || {});
  groupedTokens(view.secrets).forEach((unit) => {
    if (unit.title) container.append(element("h3", "token-group-title", unit.title));
    unit.entries.forEach((entry) => container.append(tokenCard(entry, presetNames)));
  });
  if (view.secrets.length === 0) {
    container.append(element("p", "empty", "No token definitions. Add secrets to the YAML config file."));
  }
}

// ---- presets -----------------------------------------------------
// Presets live in their own files, one per type: token presets hold
// scope fields, repo presets hold token => rule bundles with an
// optional "*" catch-all. Applying stamps a copy into the rules
// file's draft sections.

function setPresetField(group, name, key, value) {
  const presets = draft[group] = draft[group] || {};
  const fields = presets[name] = presets[name] || {};
  if (value === undefined) delete fields[key];
  else fields[key] = value;
  markChanged();
}

function renamePreset(group, oldName, input) {
  const newName = input.value.trim();
  if (!newName || newName === oldName) {
    renderPresets();
    return;
  }
  if ((draft[group] || {})[newName]) {
    setMessage(`A preset named "${newName}" already exists.`, "error");
    renderPresets();
    return;
  }
  draft[group][newName] = draft[group][oldName];
  delete draft[group][oldName];
  markChanged();
  renderPresets();
  renderTokens();
}

function deletePreset(group, name) {
  if (draft[group]) delete draft[group][name];
  markChanged();
  renderPresets();
  renderTokens();
}

function addPreset(group) {
  const presets = draft[group] = draft[group] || {};
  let name = "new-preset";
  let counter = 2;
  while (presets[name]) name = `new-preset-${counter++}`;
  presets[name] = group === "token_presets"
    ? { visibility: "public", sources: ["all"], targets: normalizedTargets({}) }
    : {};
  markChanged();
  renderPresets();
  renderTokens();
}

function presetCardHead(group, name) {
  const head = element("div", "preset-head");
  const nameInput = element("input", "preset-name");
  nameInput.type = "text";
  nameInput.value = name;
  nameInput.setAttribute("aria-label", "Preset name");
  nameInput.addEventListener("change", () => renamePreset(group, name, nameInput));
  head.append(nameInput);
  const remove = element("button", "orphan-remove", "Delete preset");
  remove.addEventListener("click", () => deletePreset(group, name));
  head.append(remove);
  return head;
}

// Repo preset rows: a rule select per configured token plus the "*"
// catch-all stamped onto every token the preset does not name.
function repoPresetEditor(name, fields) {
  const wrap = element("div", "");
  const tokenNames = view.secrets.map((entry) => (entry.config || {}).name).filter(Boolean);
  [["*", "All unlisted tokens"]].concat(tokenNames.map((token) => [token, token])).forEach(([key, label]) => {
    const row = element("div", "assignment-row");
    row.append(element("strong", "", label));
    const select = document.createElement("select");
    [
      ["", "Not part of this preset"],
      ["default", "Use token defaults"],
      ["include", "Assign to the repository"],
      ["exclude", "Do not assign to the repository"]
    ].forEach(([value, text]) => {
      const option = element("option", "", text);
      option.value = value;
      option.selected = (fields[key] || "") === value;
      select.append(option);
    });
    select.addEventListener("change", () => {
      setPresetField("repo_presets", name, key, select.value === "" ? undefined : select.value);
    });
    row.append(select);
    wrap.append(row);
  });
  if (tokenNames.length === 0) {
    wrap.append(element("p", "scope-note", "No tokens are configured yet; the catch-all can still be set."));
  }
  return wrap;
}

function renderPresets() {
  const files = view.preset_files || {};
  document.getElementById("preset-files").textContent =
    `(${files.tokens || "presets-tokens.json"} / ${files.repos || "presets-repos.json"})`;

  const tokenContainer = document.getElementById("token-presets");
  tokenContainer.replaceChildren();
  Object.entries(draft.token_presets || {}).forEach(([name, fields]) => {
    const card = element("article", "token-card");
    card.append(presetCardHead("token_presets", name));
    card.append(scopeEditor(fields, (key, value) => { setPresetField("token_presets", name, key, value); }));
    tokenContainer.append(card);
  });
  if (Object.keys(draft.token_presets || {}).length === 0) {
    tokenContainer.append(element("p", "empty", "No token presets yet. New token preset creates a reusable scope template."));
  }

  const repoContainer = document.getElementById("repo-presets");
  repoContainer.replaceChildren();
  Object.entries(draft.repo_presets || {}).forEach(([name, fields]) => {
    const card = element("article", "token-card");
    card.append(presetCardHead("repo_presets", name));
    card.append(repoPresetEditor(name, fields));
    repoContainer.append(card);
  });
  if (Object.keys(draft.repo_presets || {}).length === 0) {
    repoContainer.append(element("p", "empty", "No repository presets yet. New repository preset creates a reusable rule bundle."));
  }
}

function renderUnimported() {
  const container = document.getElementById("unimported");
  container.replaceChildren();
  const names = view.unimported_env_names || [];
  const ignored = view.ignored_env_names || [];
  if (names.length === 0 && ignored.length === 0) return;
  const notice = element("div", "notice");
  if (names.length) {
    notice.append(element("strong", "", "Env-file variables without a token definition: "));
    notice.append(document.createTextNode(names.join(", ")));
    notice.append(document.createTextNode(". Import only after choosing exact destinations: scaffold --only NAME --target 'SOURCE|CONTEXT|OWNER/REPO'. Imports are active only for those targets; use scaffold --ignore NAME for helper variables."));
  } else {
    notice.append(element("strong", "", "No unimported env-file variables."));
  }
  if (ignored.length) notice.append(element("p", "small muted", `Ignored: ${ignored.join(", ")}`));
  container.append(notice);
}

function renderSummary() {
  const summary = view.action_summary || {};
  const parts = Object.entries(summary).sort(([a], [b]) => a.localeCompare(b)).map(([action, count]) => `${action}: ${count}`);
  document.getElementById("action-summary").textContent = parts.length
    ? `Plan actions in the current inventory: ${parts.join(" · ")}`
    : "";
}

function renderPreview() {
  document.getElementById("inventory-summary").textContent = `Inventory snapshot: ${view.generated_at || "none"}. Refreshing inventory does not write provider secrets.`;
  renderOrphans();
  renderSourceIndex();
  renderRepositories();
}

function removeOrphan(orphan) {
  const sourceRules = (draft.rules || {})[orphan.source];
  if (!sourceRules || !sourceRules[orphan.repository]) return;
  delete sourceRules[orphan.repository][orphan.secret];
  if (Object.keys(sourceRules[orphan.repository]).length === 0) delete sourceRules[orphan.repository];
  if (Object.keys(sourceRules).length === 0) delete (draft.rules || {})[orphan.source];
  markChanged();
}

function renderOrphans() {
  const container = document.getElementById("orphans");
  container.replaceChildren();
  const orphans = view.orphan_rules || [];
  if (orphans.length === 0) return;
  const notice = element("div", "notice");
  notice.append(element("strong", "", "Rules for repositories missing from the inventory: "));
  orphans.forEach((orphan, index) => {
    if (index) notice.append(document.createTextNode("; "));
    notice.append(document.createTextNode(`${orphan.repository} (${orphan.secret}: ${orphan.rule})`));
    const button = element("button", "orphan-remove", "Remove");
    button.addEventListener("click", () => removeOrphan(orphan));
    notice.append(button);
  });
  notice.append(document.createTextNode(". Orphan rules can re-activate if the name is reused; remove them deliberately and Save."));
  container.append(notice);
}

function renderSourceIndex() {
  const container = document.getElementById("source-index");
  container.replaceChildren();
  view.sources.forEach((source) => {
    const card = element("section", "source-card");
    const heading = element("h3", "", source.id);
    if (source.writable === false) {
      heading.append(document.createTextNode(" "));
      heading.append(element("span", "status-pill status-pull_only", "pull-only"));
    }
    card.append(heading);
    card.append(element("p", "source-meta muted", `${source.type}${source.owner ? ` · ${source.owner}` : ""} · inventory ${source.inventory_state}${source.discovered_at ? ` · ${source.discovered_at}` : ""}`));
    (source.stale_reasons || []).forEach((reason) => {
      card.append(element("p", "notice", `Inventory is stale: ${reason}. Refresh the repository inventory.`));
    });
    if (source.contexts_not_refreshed.length) {
      card.append(element("p", "notice", `Inventory is incomplete for: ${source.contexts_not_refreshed.join(", ")}.`));
    }
    const list = element("ul", "repo-links");
    source.repositories.forEach((repo) => {
      const item = element("li");
      const link = element("a", "", repo.name);
      link.href = `#${repo.anchor}`;
      item.append(link);
      const assignedCount = repo.assigned.length;
      item.append(document.createTextNode(repo.selected ? ` (${assignedCount} assigned)` : " (not selected)"));
      list.append(item);
    });
    if (source.repositories.length === 0) {
      card.append(element("p", "empty", source.inventory_state === "missing" ? "No repository inventory yet. Use Refresh repository inventory." : "No repositories are present in this inventory."));
    } else {
      card.append(list);
    }
    container.append(card);
  });
  if (view.sources.length === 0) container.append(element("p", "empty", "No configured sources."));
}

// Status vocabulary comes from the server's UiMetadata, not a local
// copy, so new planner actions render instead of silently degrading.
function statusClass(action) {
  const known = (view.meta && view.meta.statuses) || [];
  return known.includes(action) ? `status-pill status-${action}` : "status-pill status-not_checked";
}

// Backtick spans become <code> elements; everything else is a text
// node — no innerHTML, so metadata text can never inject markup.
function appendMarkedText(container, text) {
  String(text).split("`").forEach((part, index) => {
    if (part === "") return;
    container.append(index % 2 === 1 ? element("code", "", part) : document.createTextNode(part));
  });
}

function renderHelp() {
  const list = document.getElementById("field-help");
  list.replaceChildren();
  ((view.meta && view.meta.field_help) || []).forEach((entry) => {
    list.append(element("dt", "", entry.term));
    const dd = element("dd", "");
    appendMarkedText(dd, entry.text);
    list.append(dd);
  });
}

function repoRuleControl(source, repo, secret) {
  const row = element("div", "assignment-row");
  row.append(element("strong", "", secret.name));
  const select = document.createElement("select");
  [
    ["default", "Use token defaults"],
    ["include", "Assign to this repository"],
    ["exclude", "Do not assign to this repository"]
  ].forEach(([value, label]) => {
    const option = element("option", "", label);
    option.value = value;
    option.selected = repo.rule_modes[secret.name] === value;
    select.append(option);
  });
  const locked = repo.locked_sources[secret.name] === true || repo.selected !== true;
  select.disabled = locked;
  select.addEventListener("change", () => changeRepositoryRule(source.id, repo, secret.name, select.value));
  row.append(select);
  if (repo.locked_sources[secret.name] === true) row.append(element("span", "lock-note", "Source is explicitly excluded in the YAML config."));
  else if (repo.selected !== true) row.append(element("span", "lock-note", "Repository is not selected by the source filters."));
  else if (repo.legacy_exclusions[secret.name] && select.value === "exclude") row.append(element("span", "small muted", "Excluded by the YAML config; choosing defaults will add a specific override."));
  else if (select.value === "include" && repo.crosses_scope[secret.name]) row.append(element("span", "small muted", "Manual include reaches beyond default source/visibility scope or a repository exclusion."));
  return row;
}

// A repo preset stamps its token => rule entries onto the repo's
// draft rules; the "*" catch-all applies to every configured token
// the preset does not name. Tokens locked by exclude_sources are
// skipped — no rule can cross that boundary anyway.
function applyRepoPreset(sourceId, repo, presetName) {
  const fields = (draft.repo_presets || {})[presetName];
  if (!fields) return;
  const locked = repo.locked_sources || {};
  view.secrets.forEach((entry) => {
    const name = (entry.config || {}).name;
    if (!name || locked[name] === true) return;
    const mode = fields[name] !== undefined ? fields[name] : fields["*"];
    if (mode !== undefined) changeRepositoryRule(sourceId, repo, name, mode);
  });
}

// "Use token defaults" deletes a JSON override only when there is no
// YAML intent underneath; against a YAML rule or exclusion it writes
// an explicit "default" that cancels it (see rule provenance).
function changeRepositoryRule(sourceId, repo, secretName, mode) {
  const rules = draft.rules = draft.rules || {};
  const sourceRules = rules[sourceId] = rules[sourceId] || {};
  const repoRules = sourceRules[repo.name] = sourceRules[repo.name] || {};
  const provenance = repo.rule_sources[secretName];
  const legacy = repo.legacy_exclusions[secretName] === true;
  if (mode === "default" && provenance !== "yaml" && !legacy) delete repoRules[secretName];
  else repoRules[secretName] = mode;
  if (Object.keys(repoRules).length === 0) delete sourceRules[repo.name];
  if (Object.keys(sourceRules).length === 0) delete rules[sourceId];
  markChanged();
}

function appendAssigned(container, entry) {
  const row = element("div", "assignment-row");
  row.append(element("strong", "", entry.name));
  row.append(element("span", `origin ${entry.origin === "manual" ? "origin-manual" : "origin-default"}`, entry.origin === "manual" ? "Manual assignment" : "Default assignment"));
  const contexts = element("span", "");
  entry.contexts.forEach((context, index) => {
    if (index) contexts.append(document.createTextNode(" · "));
    contexts.append(document.createTextNode(`${context.name}: `));
    const status = element("span", statusClass(context.action), context.action.replaceAll("_", " "));
    status.title = context.detail || "";
    contexts.append(status);
    const dates = [];
    if (context.remote_updated_at) dates.push(`remote updated ${context.remote_updated_at}`);
    if (context.applied_at) dates.push(`last applied ${context.applied_at}`);
    if (dates.length) {
      contexts.append(document.createTextNode(" "));
      contexts.append(element("span", "small muted", dates.join(" · ")));
    }
  });
  row.append(contexts);
  container.append(row);
}

function appendNotAssigned(container, entry) {
  const row = element("div", "assignment-row");
  row.append(element("strong", "", entry.name));
  const className = entry.category === "manual" ? "origin-manual-excluded" : entry.category === "source" ? "origin-source" : "origin-default-excluded";
  const label = entry.category === "manual" ? "Manual exclusion" : entry.category === "source" ? "Source selection" : "Outside defaults";
  row.append(element("span", `origin ${className}`, label));
  row.append(element("span", "small", entry.reason));
  container.append(row);
}

function repoMatchesFilter(repo) {
  const filter = document.getElementById("repo-filter").value.trim().toLowerCase();
  return filter === "" || repo.name.toLowerCase().includes(filter);
}

function renderRepositories() {
  const container = document.getElementById("repositories");
  container.replaceChildren();
  view.sources.forEach((source) => {
    const group = element("section", "");
    group.append(element("h3", "", source.id));
    if (source.repositories.length === 0) {
      group.append(element("p", "empty", source.inventory_state === "missing" ? "No repository data. Refresh the inventory to populate this source." : "No repositories in this source snapshot."));
      container.append(group);
      return;
    }
    source.repositories.filter(repoMatchesFilter).forEach((repo) => {
      const card = element("article", "repo-card");
      card.id = repo.anchor;
      const heading = element("div", "repo-heading");
      heading.append(element("h4", "", repo.name));
      heading.append(element("span", "visibility", repo.visibility));
      heading.append(element("span", `origin ${repo.selected ? "origin-default" : "origin-source"}`, repo.selected ? "Selected" : "Not selected"));
      if (!repo.admin) heading.append(element("span", "status-pill status-not_checked", "No admin permission"));
      card.append(heading);

      const rules = element("details", "repo-rule-list");
      const summary = element("summary", "", "Repository-specific token rules");
      rules.append(summary);
      const repoPresetNames = Object.keys(draft.repo_presets || {});
      if (repoPresetNames.length) {
        const presetRow = element("p", "small");
        presetRow.append(element("span", "field-label", "Apply preset: "));
        const presetSelect = document.createElement("select");
        const placeholder = element("option", "", "choose a preset…");
        placeholder.value = "";
        presetSelect.append(placeholder);
        repoPresetNames.forEach((presetName) => {
          const option = element("option", "", presetName);
          option.value = presetName;
          presetSelect.append(option);
        });
        presetSelect.addEventListener("change", () => {
          applyRepoPreset(source.id, repo, presetSelect.value);
          presetSelect.value = "";
        });
        presetRow.append(presetSelect);
        rules.append(presetRow);
      }
      view.secrets.forEach((entry) => rules.append(repoRuleControl(source, repo, entry.config || {})));
      card.append(rules);

      const assigned = element("div", "repo-assignment");
      assigned.append(element("h5", "", "Tokens assigned by current rules"));
      if (repo.assigned.length) repo.assigned.forEach((entry) => appendAssigned(assigned, entry));
      else assigned.append(element("p", "empty", "No tokens are currently assigned."));
      card.append(assigned);

      if (repo.not_assigned.length) {
        const omitted = element("details", "repo-assignment fold");
        omitted.append(element("summary", "", `Tokens not assigned (${repo.not_assigned.length})`));
        repo.not_assigned.forEach((entry) => appendNotAssigned(omitted, entry));
        card.append(omitted);
      } else {
        card.append(element("p", "empty", "All configured token rules assign to this repository."));
      }

      if (repo.unexpected.length) {
        const unexpected = element("div", "repo-assignment");
        unexpected.append(element("h5", "", "Remote tokens outside configuration"));
        repo.unexpected.forEach((entry) => {
          const row = element("div", "assignment-row");
          row.append(element("strong", "", entry.name));
          row.append(element("span", "status-pill status-unexpected", `Unexpected · ${entry.context}`));
          row.append(element("span", "small", entry.detail));
          unexpected.append(row);
        });
        card.append(unexpected);
      }
      group.append(card);
    });
    container.append(group);
  });
}

async function cancelChanges() {
  if (isDirty() && !window.confirm("Discard unsaved repository-rule changes?")) return;
  clearTimeout(previewTimer);
  previewSequence += 1;
  try {
    const result = await fetchData();
    if (result) {
      acceptView(result, { applyRules: true });
      setMessage("Configuration loaded.", "success");
    }
  } catch (error) {
    setMessage(error.message, "error");
  }
}

async function saveChanges() {
  if (saving) return;
  saving = true;
  updateButtons();
  const viewSequence = ++issuedSequence;
  const submitted = copy(draft);
  try {
    const result = await post("/api/save", {
      revision: view.revision,
      rules: submitted.rules || {},
      token_defaults: submitted.token_defaults || {},
      token_presets: submitted.token_presets || {},
      repo_presets: submitted.repo_presets || {}
    });
    appliedSequence = Math.max(appliedSequence, viewSequence);
    if (JSON.stringify(draft) === JSON.stringify(submitted)) {
      acceptView(result, { applyRules: true });
      setMessage("Saved locally. No provider secrets were changed.", "success");
    } else {
      // Edits made during the save are kept; only the read-only data
      // refreshes, and a new preview validates the merged draft.
      acceptView(result, { applyRules: false });
      baseline = viewSections(result);
      // markChanged schedules the revalidation preview; the save outcome
      // must be reported after it so the "checking" status does not
      // overwrite it.
      markChanged();
      setMessage("Saved your earlier edits; your newer edits are kept as a draft.", "success");
    }
  } catch (error) {
    setMessage(error.message, "error");
    if (error.status === 409) {
      previewValid = false;
      updateButtons();
    }
  } finally {
    saving = false;
    updateButtons();
  }
}

async function refreshInventory() {
  if (refreshing) return;
  if (isDirty() && !window.confirm("Discard unsaved repository-rule changes and refresh inventory?")) return;
  refreshing = true;
  updateButtons();
  clearTimeout(previewTimer);
  previewSequence += 1;
  try {
    const sequence = ++issuedSequence;
    const result = await post("/api/inventory", { revision: view.revision });
    if (sequence > appliedSequence) {
      appliedSequence = sequence;
      if (result.csrf) csrfToken = result.csrf;
      acceptView(result, { applyRules: true });
    }
    setMessage("Repository and secret metadata refreshed. No provider secrets were changed.", "success");
  } catch (error) {
    setMessage(error.message, "error");
  } finally {
    refreshing = false;
    updateButtons();
  }
}

async function pollData() {
  if (saving || refreshing) return;
  const sequence = ++issuedSequence;
  try {
    const response = await fetch("/api/data", { cache: "no-store" });
    if (!response.ok) {
      if (sequence > appliedSequence) {
        appliedSequence = sequence;
        if (view) setMessage(`Server returned ${response.status}; the page is showing the last good data.`, "error");
      }
      return;
    }
    const result = await response.json();
    if (sequence <= appliedSequence) return;
    appliedSequence = sequence;
    if (result.csrf) csrfToken = result.csrf;
    if (!view) {
      acceptView(result, { applyRules: true });
      setMessage("Configuration loaded.", "success");
      return;
    }
    if (result.display_revision === view.display_revision) return;
    if (isDirty()) {
      if (lastStaleWarning !== result.display_revision) {
        lastStaleWarning = result.display_revision;
        setMessage("The config, rules, values, or inventory changed on disk. Save or discard your edits before reloading.", "error");
      }
      return;
    }
    acceptView(result, { applyRules: true });
  } catch (_) {
    if (sequence > appliedSequence) {
      appliedSequence = sequence;
      if (view) setMessage("Could not refresh; the page is showing the last good data.", "error");
    }
    // Server unreachable or restarting; the next tick retries.
  }
}

document.getElementById("cancel").addEventListener("click", cancelChanges);
document.getElementById("save").addEventListener("click", saveChanges);
document.getElementById("add-token-preset").addEventListener("click", () => addPreset("token_presets"));
document.getElementById("add-repo-preset").addEventListener("click", () => addPreset("repo_presets"));
document.getElementById("refresh-inventory").addEventListener("click", refreshInventory);
document.getElementById("repo-filter").addEventListener("input", renderRepositories);
document.addEventListener("visibilitychange", () => { if (!document.hidden) void pollData(); });
setInterval(pollData, 5000);
loadData().catch((error) => setMessage(error.message, "error"));
