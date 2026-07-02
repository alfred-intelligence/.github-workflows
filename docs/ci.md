# Reusable CI — the generic gate contract

`go-bash-ci.yml` is the **single source of truth** for the generic CI gates of
the alfred-intelligence Go + Bash stack. Branch-protection / org-ruleset
required checks reference the contexts it emits; consumer repos call it instead
of hand-rolling their own. CI names and protection requirements therefore derive
from one definition and cannot drift.

## Why this exists

Previously every repo wrote its own `ci.yml` with ad-hoc job names (`go`,
`shell`, …) while branch protection required *different* names (`go-test`,
`go-lint`, `shell-lint`). The required contexts never matched what ran, so every
PR sat permanently `BLOCKED` on checks that could never report. Each session
re-patched it differently → permanent drift. One shared definition removes the
second source of truth, which removes the drift.

## What it covers — and what it does not

| In scope (generic, shared here) | Out of scope (repo-specific, stays local) |
|---|---|
| `go-test` — `go test -race ./...` | goreleaser checks |
| `go-lint` — `go vet ./...` | OS acceptance matrices |
| `shell-lint` — shellcheck | perf / benchmark jobs |

Repo-specific gates are inherently per-repo; forcing them into a shared workflow
just recreates the "10-input reusable workflow" anti-pattern. Keep them in the
consumer's own workflows.

## How to consume it

Add a thin caller to the consumer repo. The **job id you choose becomes the
context prefix** — pick `ci` so the contexts read cleanly:

```yaml
# .github/workflows/ci.yml in the consumer repo
name: CI
on:
  push:
    branches: [main, next]
  pull_request:

jobs:
  ci:
    uses: alfred-intelligence/.github-workflows/.github/workflows/[email protected]
    with:
      # Optional. Empty default scans every *.sh/*.bash in the repo.
      shellcheck-paths: "install.sh init/init.bash"
  # Repo-specific jobs (goreleaser-check, acceptance, …) live here alongside.
```

Pin `@<tag-or-sha>` rather than `@main` once this repo tags releases, so a change
here can't break every consumer at once.

## Canonical required-check contexts (for the org ruleset)

With a caller job named `ci`, the reusable jobs surface as:

```
ci / go-test
ci / go-lint
ci / shell-lint
```

These are the exact strings an org ruleset (or branch protection) must list as
required status checks. Plus whatever repo-specific contexts the consumer keeps
locally (e.g. `goreleaser-check`). **The list of required contexts lives here and
in the ruleset only — never re-typed per repo.**

## Conformance upgrades (deliberately deferred)

- `go-lint`: add `golangci-lint` (org code-review decision) once consumers are
  clean against it; today it is `go vet` to avoid introducing new failures.
- `shell-lint`: wrap in Reviewdog for inline PR annotations (org decision).
- Action pinning: pin `actions/*` to commit SHAs to match this repo's
  actions-hardening posture.

## Dependabot auto-merge (`dependabot-automerge.yml`)

Separate concern from the CI gate above, same one-source-of-truth discipline.
Policy: operator decision S-konservoppnaren (2026-07-02) — fleet merges
Dependabot's own minor/patch bumps once required checks are green; majors and
security-flagged majors still go to a human. The policy's *words* live in
`alfred-intelligence/.github-private/DECISIONS.md`; this workflow is the
policy's *mechanics* only.

```yaml
# .github/workflows/dependabot-automerge.yml in the consumer repo
name: dependabot-automerge
on:
  pull_request:
    types: [opened, reopened, synchronize]

jobs:
  automerge:
    if: github.actor == 'dependabot[bot]'
    uses: alfred-intelligence/.github-workflows/.github/workflows/[email protected]
    with:
      merge-method: rebase   # match the repo's own merge convention
    secrets:
      merge-token: ${{ secrets.FLEET_MERGE_TOKEN }}
```

Two one-time repo-admin prerequisites this workflow deliberately does **not**
do for you:

1. `gh repo edit <owner>/<repo> --enable-auto-merge` — auto-merge must be
   enabled on the repo itself before `gh pr merge --auto` has any effect.
2. Required checks must already be enforced (branch protection or org
   ruleset) — this workflow queues a merge, it never bypasses the gate.

Rollout to individual repos is a deliberate follow-up, not automatic on
landing this file.
