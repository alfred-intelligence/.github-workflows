# workflows

Reusable GitHub Actions workflows and CLI scripts for the
alfred-intelligence ecosystem.

## What's here

| Path | Purpose |
|---|---|
| [`.github/workflows/register-skill.yml`](.github/workflows/register-skill.yml) | Register a published skill in the alfred marketplace via fork-and-PR. Manual trigger from the Actions tab. |
| [`scripts/register-skill.sh`](scripts/register-skill.sh) | Local CLI fallback for the same registration flow. |
| [`docs/register-skill.md`](docs/register-skill.md) | When to use the workflow vs the script, with step-by-step instructions. |
| [`docs/auth.md`](docs/auth.md) | PAT setup, required scopes, and where the secret lives. |
| [`.github/workflows/go-bash-ci.yml`](.github/workflows/go-bash-ci.yml) | Reusable CI (`workflow_call`) for the Go+Bash stack: `go-test`, `go-lint`, `shell-lint`. The single source of truth for the generic gates. |
| [`.github/workflows/guardrails.yml`](.github/workflows/guardrails.yml) | Reusable pre-publish hygiene gate (secret/identity/local-path scan). |
| [`docs/ci.md`](docs/ci.md) | The reusable-CI gate contract + canonical required-check contexts for org rulesets. |

## Quick start

See [docs/register-skill.md](docs/register-skill.md). First-time setup
(creating the PAT and saving the secret) is in [docs/auth.md](docs/auth.md).

## License

MIT. See [LICENSE](LICENSE).
