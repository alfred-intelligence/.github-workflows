# `aifred-governance` — the org-ruleset read axis

Status: active (App registration pending operator — see
`.github-private/DECISIONS.md` § "Governators blinda fläck:
`aifred-governance`-appen").

## What this covers

One check in Governator's conformance sweep — org-level rulesets and
installed-App inventory — is invisible to every `repo`-scoped or
`read:org`-scoped fleet token: `GET /orgs/{org}/rulesets` and
`GET /orgs/{org}/installations` both 404 with "needs the admin:org scope"
regardless of the caller's org *role*. This doc covers the narrow
credential that closes that one gap, and nothing else Governator checks
(branch protection, required-check contexts, and per-repo settings all
already work with existing tokens).

## The credential

A dedicated GitHub App, **not** a wider scope on any standing identity.
See `.github-private/strategy/meta-apps.md` for the full `aifred-*`
family and the reasoning for App-over-PAT in general.

| | |
|---|---|
| App slug | `aifred-governance` |
| Display name | `AIfred Governance` |
| Organization permissions | `Administration: Read-only`, `Custom properties: Read-only` |
| Repository permissions | none |
| Webhooks | none |
| Installation | org-wide on `alfred-intelligence` (no repos to select — the App requests none) |

Read-only is enforced structurally by GitHub's permission model, not by
convention: a token minted from this App's installation cannot call any
mutating endpoint no matter what the caller sends it.

## Minting a token (local script, not a workflow)

Governator runs as a local agent via `Bash`, not inside GitHub Actions, so
it cannot use `actions/create-github-app-token`. It uses
[`scripts/gh-app-installation-token.sh`](../scripts/gh-app-installation-token.sh)
instead — the same JWT-then-installation-token exchange that action
performs, done directly against the GitHub REST API:

```bash
token=$(scripts/gh-app-installation-token.sh \
  "$GH_APP_AIFRED_GOVERNANCE_ID" \
  "$GH_APP_AIFRED_GOVERNANCE_KEY_PATH" \
  alfred-intelligence)

gh api -H "Authorization: Bearer ${token}" orgs/alfred-intelligence/rulesets
```

The minted token expires in 1 hour and is never written to disk by the
script — callers should hold it only in a shell variable for the duration
of the sweep.

## Where the credential itself is stored

The App ID and PEM private key are **not** GitHub Actions secrets — this
App never runs inside a workflow. They live in Infisical (the
`agent-secrets` project, `dev` environment) under:

- `GH_APP_AIFRED_GOVERNANCE_ID`
- `GH_APP_AIFRED_GOVERNANCE_PRIVATE_KEY`

matching the `GH_APP_` naming convention in
`.github-private/strategy/secrets-and-variables.md`. The private key
should be materialized to a local file only transiently (e.g. via
`infisical run` piping to a process substitution or a file under a
session-scoped scratch dir with `0600` perms), never committed or left
resident on disk between sweeps.

## Boundary

This App is read-only by design and stays that way. If a future need
arises to *fix* org-ruleset drift automatically (not just detect it),
that's a **separate** write-capable App (`aifred-config` already covers
org `Administration: write` — see `meta-apps.md`) — never a permission
bump on this one. Same "many narrow apps" principle the rest of the
`aifred-*` family follows.
