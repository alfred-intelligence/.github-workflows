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
    uses: alfred-intelligence/.github-workflows/.github/workflows/go-bash-ci.yml@854faf25fdc8cd1bd10bbd5030abd40a6486040c
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
| `next` | `light` | conventional-commits + full go-bash-ci battery* | on push/PR |
| `main` | `stable` | conventional-commits + full battery (go-test, go-lint, shell-lint) | on push/PR |
| `before` | `patch` | conventional-commits + full battery | on push/PR |

\* Verified live (workflows PR#5 / shy PR#27): `light-gates` and
`full-gauntlet` both currently call `go-bash-ci.yml` in full — it has no
input to shed `shell-lint`, so light does not yet get a lighter battery
than stable despite being named separately for that purpose. Closing that
gap needs a subsetting input added to `go-bash-ci.yml` itself (shared
contract, out of Phase 1 scope) — tracked as follow-up, not silently
inconsistent with this table.

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
    uses: alfred-intelligence/.github-workflows/.github/workflows/mnab-gate.yml@<pin-to-real-sha-once-workflows-PR5-merges>
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
    uses: alfred-intelligence/.github-workflows/.github/workflows/mnab-gate.yml@<pin-to-real-sha-once-workflows-PR5-merges>
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

## Sonar rating gate (`sonar-rating-gate.yml`)

Per operator directive (2026-07-16, `dante-ops/docs/sonar-rating-gate-per-branch.md`,
section "The gate: OVERALL composite, per target branch"): a required check
that enforces SonarCloud's **overall New-Code composite** (ratings +
duplication + coverage, worst failing condition governs) for the PR's target
(base) branch, along the same mnab maturity gradient as the CI gate above —
maturity increases toward `main`, so the composite bar does too.

| PR base branch | Rating (new code)* | Duplication (new) | Coverage (new) |
|---|---|---|---|
| `after`  | ≥ **C** | ≤ 5% | advisory (report, don't block) |
| `next`   | ≥ **B** | ≤ 3% | ≥ 80% |
| `main`   | **A**   | ≤ 3% | ≥ 80% |
| `before` | **A**   | ≤ 3% | ≥ 80% |

\* Worst-of-three across Maintainability (`new_maintainability_rating`),
Reliability (`new_reliability_rating`), Security (`new_security_rating`).
`main`/`before` mirror SonarCloud's strict "Sonar way" default profile; `next`
relaxes ratings to B; `after` relaxes ratings to C and duplication to ≤5%,
with coverage advisory-only. All thresholds are per-input overrides on the
reusable workflow — the table is the org-binding default, not hardcoded.

This workflow is **independent of go-bash-ci.yml / mnab-gate.yml** — it reads
measures from the SonarCloud API, it does not run tests, so it applies to any
language SonarCloud analyzes, not just the Go+Bash stack.

**Structural no-permanent-block guarantees** (this org's everything-must-work
posture): a repo with no coverage tool instrumented never gets permanently
blocked by the coverage axis — an ABSENT `new_coverage` metric is treated as
"not tracked, not enforceable" (skip + warn), never as a failing 0%. A PR
with zero New Code (e.g. docs-only) is treated the same as "no analysis yet"
— see `fail-if-no-analysis` below.

### Prerequisites (per consumer repo)

1. SonarCloud **automatic analysis** already running on the repo (GitHub App,
   no CI sonar step needed) so PR analyses exist to query.
2. The repo's exact SonarCloud **project key** (from the SonarCloud project
   settings — do not guess from the repo name). Confirmed for centralstation:
   `alfred-intelligence_centralstation`, org `alfred-intelligence` (2026-07-16).
3. `SONAR_TOKEN` provisioned as an **admin-plane** Actions secret (org or repo
   level) — the operator/CI-owner does this; agents do not enumerate the
   secret store looking for it (see `admin-plane-operator-ops-plane-bot`).

### Consuming it

```yaml
# .github/workflows/sonar-gate.yml in the consumer repo
name: Sonar rating gate
on:
  pull_request:

permissions:
  contents: read

jobs:
  sonar-gate:
    uses: alfred-intelligence/.github-workflows/.github/workflows/sonar-rating-gate.yml@<pin-to-real-sha-once-merged>
    with:
      sonar-project-key: "alfred-intelligence_centralstation"  # confirmed 2026-07-16; other repos: confirm from SonarCloud settings
      # sonar-org defaults to "alfred-intelligence" already — override only if it ever differs
    secrets:
      sonar-token: ${{ secrets.SONAR_TOKEN }}
```

With a caller job named `sonar-gate`, the required-check context is:

```
sonar-gate / rating-gate
```

That is the exact string to add to branch protection / the org ruleset per
mnab base branch (see the wire-up instructions handed to the operator
alongside this PR — this workflow never applies branch protection itself).

### Behavior notes

- Runs only on `pull_request` events (reads `github.event.pull_request.*`);
  wiring it to `push` is a caller misconfiguration, not silently ignored.
- A PR whose base branch is none of `before`/`main`/`next`/`after` **passes
  with a warning** by default (`unmapped-base-behavior: skip`) — not every
  repo runs full mnab yet. Set it to `fail` for repos that want every base
  branch explicitly mapped.
- A missing SonarCloud PR analysis, or a PR with no New Code to rate, **blocks
  by default** (`fail-if-no-analysis: true`, the strict default) — flip to
  `false` only during a repo's initial rollout window.
- All three composite axes (ratings, duplication, coverage) are evaluated and
  reported together in one run — a PR failing on multiple axes (as `#88` did,
  on both Duplication and Security Rating simultaneously) sees all of them at
  once, not just the first.
- Governance anchor: the gradient table above is drafted for
  `alfred-intelligence/.github-private/DECISIONS.md` — priest drafts, operator
  lands via PR (same discipline as the mnab CI-grind-gradient decision).

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
