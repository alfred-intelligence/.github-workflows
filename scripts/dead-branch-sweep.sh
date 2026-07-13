#!/usr/bin/env bash
# dead-branch-sweep.sh — org-wide dead-branch sweeper for alfred-intelligence.
#
# WHY THIS EXISTS: branches accumulate. Most are dead weight (merged and
# forgotten); a few are silently-stalled real work (unmerged, no open PR,
# untouched for months) — per the "everything-must-work"/legibility doctrine,
# THOSE are a triage signal, not garbage. This script tells the two apart and
# only ever deletes the first kind.
#
# SAFE BY DESIGN:
#   - Deletes ONLY branches that are fully MERGED into the repo's default
#     branch. "Merged" is checked two ways or-ed together, because neither
#     alone is reliable:
#       (a) commit-containment via `compare base...head` (status identical
#           or behind) — catches merge-commit and fast-forward merges.
#       (b) a closed PR for that branch head with merged_at set — catches
#           squash/rebase merges, where (a) alone would say "diverged"
#           even though the PR genuinely merged.
#   - NEVER deletes: the default branch, any name in PROTECTED_BRANCHES
#     (main/next/before/after — the mnab set — by default), any branch
#     GitHub itself reports as protected (covers release branches and
#     anything branch-protection-covered beyond the mnab set), or any
#     branch with an OPEN pull request — regardless of merge state.
#   - Unmerged branches with no open PR and no activity in STALE_DAYS are
#     REPORT-ONLY: listed for triage, never touched.
#   - DRY_RUN=true (the default) computes and reports every action it WOULD
#     take without calling the delete API at all.
#
# Usage: dead-branch-sweep.sh
# Reads all configuration from environment variables (see below) so the
# calling workflow stays a thin wrapper. Prints progress to stderr, writes
# the two triage tables (would-)deleted / stale-unmerged as markdown to
# stdout, and a machine-readable JSON summary to OUTPUT_JSON.
#
# Required env:
#   GH_TOKEN            - token gh CLI uses; scoped to contents:write +
#                          pull-requests:read on the target repos.
# Optional env:
#   ORG                 - org login to sweep (default: alfred-intelligence)
#   REPOS_OVERRIDE       - comma-separated owner/repo list; skips org
#                          enumeration when set (mainly for local testing)
#   DRY_RUN              - "true" (default) or "false"
#   STALE_DAYS           - report threshold for unmerged branches (default 90)
#   PROTECTED_BRANCHES   - comma-separated names never touched, in addition
#                          to each repo's own default branch and anything
#                          GitHub reports as `protected` (default:
#                          "main,next,before,after" — the mnab set)
#   OUTPUT_JSON          - path for the JSON summary (default: ./sweep-summary.json)
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
ORG="${ORG:-alfred-intelligence}"
DRY_RUN="${DRY_RUN:-true}"
STALE_DAYS="${STALE_DAYS:-90}"
PROTECTED_BRANCHES="${PROTECTED_BRANCHES:-main,next,before,after}"
OUTPUT_JSON="${OUTPUT_JSON:-./sweep-summary.json}"

for bin in gh jq date; do
  command -v "$bin" >/dev/null 2>&1 || {
    echo "dead-branch-sweep: missing required tool: $bin" >&2
    exit 1
  }
done

log() { printf '%s\n' "$*" >&2; }

is_protected_name() {
  local branch="$1" name
  IFS=',' read -ra names <<<"$PROTECTED_BRANCHES"
  for name in "${names[@]}"; do
    [[ "$branch" == "$name" ]] && return 0
  done
  return 1
}

# Resolve the repo list.
repos=()
if [[ -n "${REPOS_OVERRIDE:-}" ]]; then
  IFS=',' read -ra repos <<<"$REPOS_OVERRIDE"
else
  log "enumerating non-archived repos in org: $ORG"
  mapfile -t repos < <(
    gh api "orgs/${ORG}/repos" --paginate -q '.[] | select(.archived == false and .disabled == false) | .full_name'
  )
fi
log "repos to sweep: ${#repos[@]}"

deleted_rows=()
stale_rows=()
now_epoch=$(date -u +%s)

for repo in "${repos[@]}"; do
  owner="${repo%%/*}"
  log "== $repo =="

  default_branch=$(gh api "repos/${repo}" -q '.default_branch')

  mapfile -t branches < <(gh api "repos/${repo}/branches" --paginate -q '.[].name')

  for branch in "${branches[@]}"; do
    [[ "$branch" == "$default_branch" ]] && continue
    is_protected_name "$branch" && continue

    protected=$(gh api "repos/${repo}/branches/${branch}" -q '.protected')
    [[ "$protected" == "true" ]] && continue

    prs_json=$(gh api "repos/${repo}/pulls?head=${owner}:${branch}&state=all" 2>/dev/null || echo '[]')

    has_open_pr=$(jq -r 'any(.[]; .state == "open")' <<<"$prs_json")
    [[ "$has_open_pr" == "true" ]] && continue

    has_merged_pr=$(jq -r 'any(.[]; .merged_at != null)' <<<"$prs_json")

    compare_status=$(gh api "repos/${repo}/compare/${default_branch}...${branch}" -q '.status' 2>/dev/null || echo "unknown")
    merged_by_commits="false"
    [[ "$compare_status" == "identical" || "$compare_status" == "behind" ]] && merged_by_commits="true"

    branch_info=$(gh api "repos/${repo}/branches/${branch}")
    last_commit_date=$(jq -r '.commit.commit.committer.date' <<<"$branch_info")

    if [[ "$merged_by_commits" == "true" || "$has_merged_pr" == "true" ]]; then
      if [[ "$DRY_RUN" == "true" ]]; then
        action="would-delete"
      else
        action="deleted"
        gh api -X DELETE "repos/${repo}/git/refs/heads/${branch}"
      fi
      log "  $action: $branch (merged, last commit $last_commit_date)"
      deleted_rows+=("$(jq -nc --arg repo "$repo" --arg branch "$branch" --arg action "$action" \
        --arg last_commit "$last_commit_date" \
        '{repo:$repo, branch:$branch, action:$action, last_commit:$last_commit}')")
      continue
    fi

    # Unmerged, no open PR — staleness check only. Never deleted.
    commit_epoch=$(date -u -d "$last_commit_date" +%s)
    age_days=$(((now_epoch - commit_epoch) / 86400))
    if ((age_days > STALE_DAYS)); then
      log "  stale-unmerged: $branch (${age_days}d since last commit)"
      stale_rows+=("$(jq -nc --arg repo "$repo" --arg branch "$branch" --argjson age_days "$age_days" \
        --arg last_commit "$last_commit_date" \
        '{repo:$repo, branch:$branch, age_days:$age_days, last_commit:$last_commit}')")
    fi
  done
done

# ---- JSON summary (machine-readable, feeds lumberjack / operator triage) ----
deleted_json="[]"
if ((${#deleted_rows[@]} > 0)); then
  deleted_json=$(printf '%s\n' "${deleted_rows[@]}" | jq -s '.')
fi
stale_json="[]"
if ((${#stale_rows[@]} > 0)); then
  stale_json=$(printf '%s\n' "${stale_rows[@]}" | jq -s '.')
fi
jq -n --argjson deleted "$deleted_json" --argjson stale "$stale_json" \
  --arg dry_run "$DRY_RUN" --arg stale_days "$STALE_DAYS" \
  '{dry_run: ($dry_run == "true"), stale_days: ($stale_days | tonumber), merged: $deleted, stale_unmerged: $stale}' \
  >"$OUTPUT_JSON"
log "wrote summary: $OUTPUT_JSON"

# ---- Markdown tables (job summary) ----
mode_label="DRY RUN — nothing deleted"
[[ "$DRY_RUN" == "false" ]] && mode_label="ARMED — branches deleted"

printf '## Dead-branch sweep — %s\n\n' "$mode_label"

printf '### Merged branches (%s)\n\n' "$([[ "$DRY_RUN" == "true" ]] && echo "would delete" || echo "deleted")"
if ((${#deleted_rows[@]} == 0)); then
  printf '_none_\n\n'
else
  printf '| repo | branch | last commit |\n|---|---|---|\n'
  jq -r '.[] | "| \(.repo) | \(.branch) | \(.last_commit) |"' <<<"$deleted_json"
  printf '\n'
fi

printf '### Stale unmerged branches — report only, never deleted (>%s days idle, no open PR)\n\n' "$STALE_DAYS"
if ((${#stale_rows[@]} == 0)); then
  printf '_none_\n'
else
  printf '| repo | branch | age (days) | last commit |\n|---|---|---|---|\n'
  jq -r '.[] | "| \(.repo) | \(.branch) | \(.age_days) | \(.last_commit) |"' <<<"$stale_json"
fi
