# Configuration and authentication

The workflow and the script share a configuration surface: where the
marketplace lives, which fork to push to, and how to identify the actor that
opens pull requests. The workflow reads these from GitHub variables and
secrets. The script reads the same names from environment variables.

## Configuration model

| Name | Type | Scope | Purpose |
|---|---|---|---|
| `MARKETPLACE_REPO` | variable | org or repo | Upstream marketplace repo, `owner/repo` |
| `MARKETPLACE_FORK` | variable | org or repo | Bot's fork of the marketplace, `owner/repo` |
| `BOT_USERNAME` | variable | org or repo | GitHub login for the bot actor |
| `BOT_EMAIL` | variable | org or repo | Email recorded on bot commits and PRs |
| `MARKETPLACE_PAT` | secret | org or repo | PAT owned by the bot account, used for the workflow's push and PR-create |

All four variables and the secret can live at the organization level. Repo-level
values override org-level on name collision. Organization-level is the
recommended default because rotation and renaming only need to happen once.

## Why a bot account

The PR mechanic — push to a fork, open a PR upstream — needs an actor that
owns a fork and can act unattended. A bot account satisfies both:

- It owns its own fork (`alfred-int-bot/claude-marketplace` in the canonical
  setup), so cross-owner permission complications don't arise.
- It has a long-lived PAT scoped to its own repos, kept in the workflows
  secret store, rotated independently of any human's credentials.
- Commits and PRs are attributed to the bot, which is the correct signal when
  automation produced them.

A fine-grained PAT owned by a personal account cannot grant write access on
org-owned upstream repos that the personal account does not control. A
bot-owned PAT avoids that limitation by being the resource owner itself.

## Setting variables and secrets

### At organization level (recommended)

1. Open **Settings → Secrets and variables → Actions** in the
   organization that hosts this `workflows` repo.
2. Under the **Variables** tab, click **New organization variable** and add
   `MARKETPLACE_REPO`, `MARKETPLACE_FORK`, `BOT_USERNAME`, `BOT_EMAIL`.
3. Under the **Secrets** tab, click **New organization secret** and add
   `MARKETPLACE_PAT`.
4. For each, restrict access to the repositories that need it.

### At repository level (for overrides)

Same flow but in the workflows repository's own
**Settings → Secrets and variables → Actions**. A repo-level value takes
precedence over an org-level value with the same name.

## PAT scopes

Create the PAT while signed in as the bot account.

**Classic** — simplest:

- Scope: `repo` (full).
- Expiration: long enough for comfortable rotation, short enough to be hygienic.

**Fine-grained** — possible because the bot owns the fork:

- Resource owner: the bot account.
- Repository access: the bot-owned fork.
- Repository permissions:
  - `Contents: Read and write`
  - `Pull requests: Read and write`

For the PR-create call against the upstream repo, the bot account needs to be
either a collaborator on the upstream or a member of the upstream's
organization with at least Triage role on the marketplace repo. No additional
PAT permissions on the upstream are required for opening a PR from the bot's
own fork.

## Pre-flight check

The workflow's first step verifies that the four variables are set and fails
with a clear error if any is missing. The script does the equivalent check on
the env var names.

## Local environment for the script

The script reads `MARKETPLACE_REPO` and `MARKETPLACE_FORK` from the shell
environment. `MARKETPLACE_REPO` is required. `MARKETPLACE_FORK` defaults to
the authenticated `gh` user's namespace with the same repo name as
`MARKETPLACE_REPO`; set it explicitly if you maintain a fork under a different
name.

The script does not override the operator's `git config`. Commits and the
opened PR are attributed to whoever runs the script. Bot-attributed PRs come
from the workflow.

## Rotation

When the workflow starts failing with `Bad credentials`, regenerate the bot's
PAT and update `MARKETPLACE_PAT` in whichever scope (org or repo) it lives.
The script uses the operator's own `gh` token and has no separate rotation
schedule.
