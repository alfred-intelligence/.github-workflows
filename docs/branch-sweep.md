# Dead-branch sweep

`dead-branch-sweep.yml` is a central, org-wide job (not a per-repo
`workflow_call` reusable) that finds and removes dead branches across
`alfred-intelligence`. It lives in this repo the same way
`register-skill.yml` does: one cross-repo job, deployed once, rather than
something each consumer repo opts into separately.

## Safety guarantees (read this before arming it)

- **Deletes ONLY fully-merged branches.** "Merged" is decided two ways,
  OR-ed together:
  1. Commit-containment: `compare <default>...<branch>` reports `identical`
     or `behind` — the branch has no commits the default branch lacks.
  2. Merged-PR history: a closed PR exists for that branch head with
     `merged_at` set — this is what catches **squash and rebase merges**,
     which (1) alone would miss because the base branch gets a *new* commit
     SHA, not the branch's original commits.
- **Never deletes:** the repo's own default branch, the mnab set
  (`main`, `next`, `before`, `after`) by name, any branch GitHub's API
  itself reports as `protected` (covers release branches and anything
  branch-protection-covered beyond the mnab set), or any branch with an
  **open** pull request — regardless of merge state.
- **Stale unmerged branches are report-only.** A branch with no open PR,
  not merged, and no commit activity in `stale_days` (default 90) is listed
  in the job summary and JSON artifact for human triage — never deleted.
  Per the legibility doctrine, an unmerged branch nobody opened a PR for is
  exactly the "stalled but maybe-real work" signal, not garbage.
- **Dry-run by default, twice over.** The scheduled (cron) run only deletes
  anything if the repo variable `BRANCH_SWEEP_ARMED` is literally `true` —
  an explicit step outside this workflow's own PR. A manual
  `workflow_dispatch` run's `dry_run` input also defaults to `true`. Nothing
  deletes until an operator deliberately flips one of those.

## What it does not cover

- **Scope is the token's reach, not the whole org's repos in a legal
  sense.** The sweep enumerates repos via `GET /orgs/alfred-intelligence/
  repos` using `BRANCH_SWEEP_TOKEN` — it only sees repos that token can
  read/write. It never crosses to `GeGGe01`, `SAVANTERNA`, `kebab-it`, or
  any other owner; those are out of scope by construction, not by choice
  each run.
- It does not touch tags, releases, or anything outside `refs/heads/*`.
- It does not open issues. Report output is the job summary (markdown
  tables, human-readable in the Actions run) plus a JSON artifact
  (`dead-branch-sweep-summary`, 90-day retention) for anything that wants
  to consume it programmatically (e.g. a future lumberjack ingest).

## Configuration

| Name | Type | Scope | Purpose |
|---|---|---|---|
| `BRANCH_SWEEP_TOKEN` | secret | org (recommended) or repo | Token used for every cross-repo API call: list repos/branches, compare, list PRs, delete refs. |
| `BRANCH_SWEEP_ARMED` | variable | org or repo | Must be exactly `true` for the **scheduled** run to actually delete anything. Absent/anything else = dry-run. |

`workflow_dispatch` inputs (`dry_run`, `stale_days`, `repos_override`) are
per-run and don't need any variable set — useful for a supervised first
pass before touching `BRANCH_SWEEP_ARMED` at all.

## Token scope — current state vs. target state

**Current (this PR):** `BRANCH_SWEEP_TOKEN` is a fine-grained PAT owned by
the fleet bot account (`alfred-int-bot`), following the same pattern as
`MARKETPLACE_PAT` (see [`docs/auth.md`](auth.md)) — a bot-owned token kept
in the org (or repo) secret store, least-privilege repository permissions:

- `Contents: Read and write` (branch read/delete)
- `Pull requests: Read` (open-PR check, merged-PR history for squash/rebase
  detection — write is never needed)

Set while signed in as the bot account, resource owner = the bot account,
repository access = **All repositories** in `alfred-intelligence` (needed
to reach the whole org from one token; requires org-admin approval for a
member-owned fine-grained PAT with org-wide repo access — an operator
step, same class as any fine-grained-PAT-across-many-repos grant).

**Target state:** this exact permission profile —
`Contents: write` + `Pull requests: read`, org-wide — is inside the
already-decided but not-yet-registered `aifred-maintenance` App's scope
(`.github-private/strategy/meta-apps.md`: "Stale-issue triage,
dependency-bump PRs, lint-fix PRs" — a dead-branch sweep is the same class
of maintenance chore). Once that App is registered (blocked on an
operator-only GitHub UI step, same as `aifred-governance`'s), migrate this
workflow to `actions/create-github-app-token` with
`permission-contents: write` / `permission-pull-requests: read`
(sub-setting the App's own broader declared permissions, per the "Token
issuance pattern" in `meta-apps.md`) instead of a standing PAT. This is a
mechanical swap of the auth step only — the sweep logic
(`scripts/dead-branch-sweep.sh`) does not change.

## Governance note — flagged, not decided here

`DECISIONS.md` has no existing entry authorizing "merged branches get
auto-deleted org-wide." The zero-cost-review-stack and mnab-CI-gate-gradient
decisions govern *what runs and what's required*, not branch lifecycle —
this sweep doesn't fight either (it never touches protected branches or
required-check config, and dry-run-by-default keeps it inert until an
operator arms it). But "delete X automatically, org-wide" is exactly the
shape of decision the governance doc says lives in `DECISIONS.md`, not
something a workflow silently decides for itself. **This PR does not add
that entry** — it ships the mechanism inert (dry-run) and flags that the
operator/governance-owner should add a short `DECISIONS.md` post before
`BRANCH_SWEEP_ARMED` is ever set to `true` anywhere.

## Local testing

The script is standalone and callable outside Actions:

```bash
GH_TOKEN=$(gh auth token) \
ORG=alfred-intelligence \
DRY_RUN=true \
STALE_DAYS=90 \
  bash scripts/dead-branch-sweep.sh
```

Use `REPOS_OVERRIDE=owner/repo1,owner/repo2` to scope a test run to one or
two repos before trusting it against the whole org.
