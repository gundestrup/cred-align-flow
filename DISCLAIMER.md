# Disclaimer

**Last updated:** 2026-10-11

## Introduction

The software and documentation provided in this repository (`cred-align-flow`, the "Software") is for general informational and operational purposes only. All information and functionality is provided in good faith; however, the authors and contributors make no representation or warranty of any kind, express or implied, regarding the accuracy, adequacy, validity, reliability, availability, or completeness of the Software or any output it produces.

Under no circumstance shall the authors or contributors have any liability to you for any loss or damage of any kind incurred as a result of the use of the Software or reliance on any information produced by it — including, without limitation, overwritten or lost CI/CD secrets, broken deployment pipelines, leaked credentials, corrupted local state, or downtime of dependent services. **Your use of the Software and your reliance on any information it produces is solely at your own risk.**

## Warranty and liability

The Software is licensed under the GNU Affero General Public License, version 3 only. Per AGPL §15–16, the Software is provided "AS IS" without warranty of any kind, and in no event will any copyright holder or other party be liable for damages arising out of its use or inability to be used. The full text is in [LICENSE](LICENSE) and is also quoted in the [README](README.md#license).

## Third-party services disclaimer

The Software interacts with third-party services (for example GitHub and Forgejo instances) through their public APIs and CLIs. Those services are not investigated, monitored, or controlled by the authors, and their behavior — including API changes, rate limits, authentication policies, and timestamp semantics — can change without notice.

The authors do not warrant, endorse, guarantee, or assume responsibility for the accuracy or reliability of any data returned by third-party services, nor for any transaction or operation performed on your accounts with those services. You are responsible for the credentials and permissions you grant the Software on those platforms.

## Errors and omissions disclaimer

While every effort is made to keep drift detection, fingerprints, and inventory snapshots accurate, the Software cannot prove remote secret values (providers do not reveal them), cannot perform atomic compare-and-swap writes, and cannot detect changes made within provider timestamp granularity. Output that reports a secret as current is metadata-based evidence, not certification of remote equality.

The Software is not a substitute for a professional security review, a secret-management platform, or your own verification of what will be written before approving an `apply`. Before acting on plans the Software generates — especially plans involving `--force` or unattended `--yes` operation — review them and confirm ownership of every affected remote secret.

## Fair use / copyright notice

All third-party product and service names (GitHub, Forgejo, and others) are trademarks of their respective owners. References are nominative and imply no affiliation, endorsement, or sponsorship.

---

*This disclaimer is a standard template adapted for this project; it does not constitute legal advice.*
