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

## mnab gate gradient (`mnab-gate.yml`)

Org-binding per `DECISIONS.md` "CI-grind-konvention (mnab-modellen)" (2026-07-09):
branch protection and CI gate *intensity* ramp toward `stable`, not the other
way round. `mnab-gate.yml` is the single source of truth for **which** gates
run on **which** mnab channel; it composes `go-bash-ci.yml` for the gate
bodies rather than re-implementing them, so there is still exactly one
definition of what `go-test`/`go-lint`/`shell-lint` mean.

| mnab branch | Release channel | Gates | Cadence |
|---|---|---|---|
| `after` | `dark` | conventional-commits + build only | push (PR gate) + fully-automatic nightly 00:00 UTC cron, skip-if-unchanged |
| `next` | `light` | conventional-commits + go-test + go-lint | on push/PR |
| `main` | `stable` | conventional-commits + full battery (go-test, go-lint, shell-lint) | on push/PR |
| `before` | `patch` | conventional-commits + full battery | on push/PR |

**Conventional commits is the one gate present on every channel, including
dark.** It's a form gate, not a quality gate: release-please / semver bump /
channel promotion all parse the commit header, so a malformed header would
silently break release automation regardless of channel. It checks every
commit introduced by the push/PR (not just HEAD), and exempts GitHub-generated
`Merge ...` headers.

### Consuming it

A caller needs two things: a normal push/PR workflow that maps its own branch
to a channel and calls `mnab-gate.yml`, and (full-mnab repos only) a second,
schedule-triggered thin workflow for the dark nightly — reusable workflows
cannot carry their own `on: schedule`, so the cron has to live in the caller.

```yaml
# .github/workflows/ci.yml — push/PR gate, channel derived from branch
name: CI
on:
  push:
    branches: [before, main, next, after]
  pull_request:

permissions:
  contents: read

jobs:
  channel:
    runs-on: ubuntu-latest
    outputs:
      channel: ${{ steps.map.outputs.channel }}
    steps:
      - id: map
        env:
          REF_NAME: ${{ github.head_ref || github.ref_name }}
        run: |
          case "$REF_NAME" in
            before) echo "channel=patch" >> "$GITHUB_OUTPUT" ;;
            main)   echo "channel=stable" >> "$GITHUB_OUTPUT" ;;
            next)   echo "channel=light" >> "$GITHUB_OUTPUT" ;;
            after)  echo "channel=dark" >> "$GITHUB_OUTPUT" ;;
            *)      echo "channel=light" >> "$GITHUB_OUTPUT" ;;  # PRs into next default to light
          esac

  gate:
    needs: channel
    uses: alfred-intelligence/.github-workflows/.github/workflows/[email protected]
    with:
      channel: ${{ needs.channel.outputs.channel }}
      shellcheck-paths: "install.sh init/init.bash"
```

```yaml
# .github/workflows/dark-nightly.yml — the fully-automatic 00:00 publish path
name: Dark nightly
on:
  schedule:
    - cron: "0 0 * * *"
  workflow_dispatch:

permissions:
  contents: read

jobs:
  gate:
    uses: alfred-intelligence/.github-workflows/.github/workflows/[email protected]
    with:
      channel: dark
      nightly-dark: true
```
The `nightly-dark: true` input turns on skip-if-unchanged (no new commits on
`after` since the last `v*-dark.*` tag => the run is a no-op) and computes the
`vX.Y.Z-dark.<YYYYMMDD>+<shortsha>` release name. Tagging/publishing the
computed name as an actual GitHub release is left to the caller's own
release step for now — `mnab-gate.yml` computes and surfaces the name
(`dark-build.outputs.dark-tag`) but does not push tags itself, so a repo
without `contents: write` permission wired up doesn't silently fail.

### What's still local per repo

- `light`/`stable` release-please retargeting for the `-light.<n>` / bare
  `vX.Y.Z` suffix convention — today's release-please configs predate the
  mnab decision and are not yet rewritten; that's a follow-on, not part of
  this gate-gradient definition.
- Branch-protection required-check lists per channel (see the repo's
  `.github/protection/*.json` or the org ruleset) — `mnab-gate.yml` defines
  what CAN run; the ruleset/protection config still has to require exactly
  those contexts. Verify they agree before relying on this as a merge gate.
- Repo-specific extras (acceptance matrices, perf benches, goreleaser checks)
  stay in the caller's own workflows, same split as `go-bash-ci.yml`.

## Conformance upgrades (deliberately deferred)

- `go-lint`: add `golangci-lint` (org code-review decision) once consumers are
  clean against it; today it is `go vet` to avoid introducing new failures.
- `shell-lint`: wrap in Reviewdog for inline PR annotations (org decision).
- Action pinning: pin `actions/*` to commit SHAs to match this repo's
  actions-hardening posture.
