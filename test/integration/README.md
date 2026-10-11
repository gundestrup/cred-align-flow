# Integration test policy

The default test suite in `../` is offline-only and uses synthetic values only. It does not read user credentials or contact a real provider.

## Pull tests

Read-only provider pull/inventory tests may run against an explicitly configured real account only when an environment variable enables them. They should assert repository and secret metadata is returned and must not assert or log secret values.

## Offline adapter and write-path tests

The GitHub CLI workflow is exercised through a generated fake `gh` executable created in the test's temporary directory. The CLI child process receives a `PATH` containing only that fake, a temporary `HOME`/`GH_CONFIG_DIR`, a scrubbed environment, and a socket guard that rejects network connections. The fake validates command arguments and synthetic stdin in memory, persists repository/secret metadata only, and does not record secret values. These tests cover the `gh` command contract and our workflow; they do not establish GitHub service-side compatibility or perform a provider write. No Docker image or separate mock repository is needed for this layer.

The Forgejo provider tests exercise the actual `Net::HTTP` adapter against a temporary Ruby `TCPServer` bound only to `127.0.0.1`. Proxy environment variables are cleared during the request; tests cover API paths, authentication headers, pagination, targeted metadata lookup, response normalization, and HTTP errors. Explicit repository includes do not list an account's repositories; they query only each configured repo. This is a local request-contract test, not a substitute for a real Forgejo service integration run.

## Push integration tests

Tests that actually write to a provider must not target production repositories or real provider accounts. They may run only when all of the following are true:

- `CRED_ALIGN_FLOW_PUSH_INTEGRATION=1` is set explicitly.
- The provider is a disposable service managed by this directory's Compose file.
- The repository under test is created by the test and is deleted with the service volume.
- Test values are generated at runtime and are not committed.

GitHub has no local secret-write sandbox, so tests never send writes to GitHub. Community editions such as Gitea or Forgejo can be tested locally with Docker. Enterprise editions are out of scope; for compatible APIs, test the corresponding community API contract and document the expected compatibility.

## Provider integration targets

| Provider | Docker target | Notes |
|---|---|---|
| GitHub | none | No official local GitHub API container exists. The current `gh`-backed adapter is tested with the isolated fake executable above; that cannot prove GitHub service-side write behavior. |
| Forgejo | `codeberg.org/forgejo/forgejo:15.0.9` | Real disposable service; preferred for pull and eventual push tests. |
| Gitea | `docker.gitea.com/gitea:<version>` | Real disposable service candidate once an adapter exists. |
| GitLab | `gitlab/gitlab-ce:<version>-ce.0` | Real disposable service candidate once a project-variable adapter exists; heavier than Forgejo/Gitea. |
| Mercurial/Bazaar/Perforce | none | These are VCS types, not repository-hosting secret APIs; an adapter would need a hosting service/API. |

GitHub API mock servers such as WireMock, Prism, `fakehub`, or `@simulacrum/github-api-simulator` can emulate selected HTTP responses, but they do not exercise the current `gh`-based adapter. They are not official and do not automatically reproduce authentication, pagination, or GitHub secret encryption. If used after a direct-HTTP refactor, they are suitable only for explicitly env-gated contract tests, not proof that a real GitHub write would succeed.

GitHub's documented `/stubbed` API endpoints apply only to GitHub Marketplace testing. They return fixed fake billing/listing data and do not cover repository discovery, Actions secrets, Dependabot secrets, or secret writes. The Checks API is likewise unrelated to this adapter.

## GitHub mock evaluation

| Tool | Result |
|---|---|
| `fakehub` | Standalone Rust server, but no published Docker image/Dockerfile and the current server routes cover only the root and user endpoints. It is not currently suitable for repository or secret tests. |
| `@simulacrum/github-api-simulator` | Runs as a lightweight Node HTTP service via `npx`. Generated OpenAPI examples answer `200` for repository, Actions-secret, and Dependabot-secret endpoints. A probe accepted `PUT .../actions/secrets/{name}`, but did not persist it and later returned the generated fixture, so it can validate request/response shapes but not write semantics or drift behavior. |
| `@kie/mock-github` | JavaScript/Nock-style in-process mocking plus local Git/action helpers. It is not a standalone API server and cannot intercept requests made by Ruby or a separate `gh` process. |
| `github_api` (`piotrmurach/github`) | Ruby client, not a mock service. Its current source predates the Actions/Dependabot secret APIs and contains no secret endpoints, so it cannot replace this adapter. It also adds several older runtime dependencies. |

For the current `gh`-backed adapter, the fast default is the generated fake executable plus a no-network CLI subprocess. The Forgejo adapter uses loopback `TCPServer` contract tests by default; `forgejo_service_test.rb` additionally exercises the real adapter against the disposable Compose service when the environment opts in. WEBrick is no longer part of Ruby's standard library; the optional browser UI uses the development-only Itsi server. A disposable GitHub repository is not used for automated writes.

The Forgejo scaffold is pinned to `codeberg.org/forgejo/forgejo:15.0.9`, uses SQLite, binds HTTP only to `127.0.0.1`, disables registration/SSH, enables Actions, and sets a loopback-only reverse-proxy trust list for the v15 container default. Validate or start it with:

```bash
docker compose -f test/integration/compose.yml config
docker compose -f test/integration/compose.yml up -d
```

Then provision a user and access token inside the container:

```bash
docker compose -f test/integration/compose.yml exec -u git forgejo \
  forgejo admin user create --username ci-bot --password ci-bot-password \
    --email ci-bot@example.invalid --admin
docker compose -f test/integration/compose.yml exec -u git forgejo \
  forgejo admin user generate-access-token --username ci-bot \
    --token-name ci --scopes 'write:repository,read:user,write:user'
```

Run the service test, then tear down:

```bash
CRED_ALIGN_FLOW_FORGEJO_URL=http://127.0.0.1:3300 \
CRED_ALIGN_FLOW_FORGEJO_TOKEN=<printed token> \
  bundle exec rake test:integration
docker compose -f test/integration/compose.yml down -v
```

The test skips cleanly when the env vars are unset, refuses non-loopback base URLs, creates a private repository with a generated name, exercises `repositories`, `repository`, `secrets`, and `readiness`, verifies `set_secret` still raises pull-only, and deletes the repository afterwards. `down -v` is required for integration teardown so repository and secret state does not leak into the next run.
