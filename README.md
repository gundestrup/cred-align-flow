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

> **Use this tool at your own risk.** Remote writes are irreversible — an overwritten secret cannot be rolled back, and `apply --force` can overwrite values the tool did not set. Try it on a disposable repository first, and read the full [warnings and security model](README.safety.md) before use.

## Quick start

Requires Ruby 3.4.10+, the GitHub CLI (`gh`) installed and authenticated, and a token with permission to administer the selected repositories.

```bash
mkdir -m 700 config
cp config.example.yml config/cred-align.local.yml
cp secrets.env.example config/secrets.env
chmod 600 config/cred-align.local.yml config/secrets.env
# edit both files, then:

bin/cred-align-flow doctor     # validate local configuration
bin/cred-align-flow inventory  # fetch remote metadata
bin/cred-align-flow plan       # preview what would change (read-only)
bin/cred-align-flow apply      # write after reviewing the plan
```

Full setup details and the configuration reference live in [README.config.md](README.config.md).

## Commands at a glance

- `doctor` — validate local configuration and value references.
- `inventory` / `pull` — refresh repository and remote secret metadata.
- `plan` / `diff` — show managed target states without writing; `--offline` uses cached inventory.
- `check` — fail when expected secrets are missing, unverified, stale, or remotely newer.
- `apply` — write missing or stale secrets after a confirmed plan; supports `--dry-run`, `--yes`, `--force`, and `--source`/`--repo`/`--secret`/`--context` filters.
- `scaffold` — record `value_digest` fingerprints and import env names into the config.
- `ui` — local browser editor for token defaults, presets, and per-repository token rules.

Full command reference, plan statuses, and the rotation workflow: [README.usage.md](README.usage.md).

## Documentation

| Document | Covers |
|---|---|
| [README.safety.md](README.safety.md) | Warnings, irreversibility, security model |
| [README.config.md](README.config.md) | Requirements, local setup, YAML configuration, UI-managed rules file |
| [README.usage.md](README.usage.md) | Command reference, plan statuses, rotation |
| [README.ui.md](README.ui.md) | Local configuration UI |
| [README.presets.md](README.presets.md) | Reusable UI presets — token scope templates and repo rule bundles |
| [README.devel.md](README.devel.md) | Provider adapter contract, development workflow, tests |

## License

This project is licensed under the GNU Affero General Public License, version 3 only (`AGPL-3.0-only`). See [LICENSE](LICENSE) and [DISCLAIMER.md](DISCLAIMER.md).

Per AGPL §15–16:

> THERE IS NO WARRANTY FOR THE PROGRAM, TO THE EXTENT PERMITTED BY APPLICABLE LAW. EXCEPT WHEN OTHERWISE STATED IN WRITING THE COPYRIGHT HOLDERS AND/OR OTHER PARTIES PROVIDE THE PROGRAM "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED OR IMPLIED, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE. THE ENTIRE RISK AS TO THE QUALITY AND PERFORMANCE OF THE PROGRAM IS WITH YOU. SHOULD THE PROGRAM PROVE DEFECTIVE, YOU ASSUME THE COST OF ALL NECESSARY SERVICING, REPAIR OR CORRECTION.
>
> IN NO EVENT UNLESS REQUIRED BY APPLICABLE LAW OR AGREED TO IN WRITING WILL ANY COPYRIGHT HOLDER, OR ANY OTHER PARTY WHO MODIFIES AND/OR CONVEYS THE PROGRAM AS PERMITTED ABOVE, BE LIABLE TO YOU FOR DAMAGES, INCLUDING ANY GENERAL, SPECIAL, INCIDENTAL OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE USE OR INABILITY TO USE THE PROGRAM (INCLUDING BUT NOT LIMITED TO LOSS OF DATA OR DATA BEING RENDERED INACCURATE OR LOSSES SUSTAINED BY YOU OR THIRD PARTIES OR A FAILURE OF THE PROGRAM TO OPERATE WITH ANY OTHER PROGRAMS), EVEN IF SUCH HOLDER OR OTHER PARTY HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGES.
>
> **USE AT YOUR OWN RISK.**
