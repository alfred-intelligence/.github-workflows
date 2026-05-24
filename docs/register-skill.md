# Register a skill in the marketplace

There are two ways to register: the **workflow** (browser, automated, bot
identity) and the **script** (local CLI, manual, operator identity). Both end
with a PR opened against the upstream marketplace.

First-time setup (variables, secrets, bot account) is in [auth.md](auth.md).

## When to use which

| Workflow | Script |
|---|---|
| Runs from the browser, no local tooling needed | Runs locally, needs `gh`, `jq`, `git` |
| Commits and PR are attributed to the bot | Commits and PR are attributed to you |
| Pushes to the bot's fork (`vars.MARKETPLACE_FORK`) | Pushes to your own fork (default: derived from current `gh` user) |
| Audit trail in GitHub Actions | Audit trail is your local shell history |

Both produce the same end state in the marketplace repo: a PR adding or
updating the skill's entry. The difference is who appears as the actor.

## The workflow

1. Open <https://github.com/alfred-intelligence/workflows/actions/workflows/register-skill.yml>.
2. Click **Run workflow**.
3. Fill in the inputs:
   - **Skill repo** — e.g., `owner/skill-name-skill`.
   - **Skill ref** — leave empty for the default branch, or specify a tag like
     `v1.0.0`.
   - **Category** — e.g., `productivity`, `legal`, `infrastructure`. Optional.
   - **Dry run** — tick to preview the diff without opening a PR.
4. Click **Run workflow**.
5. When the run finishes, the PR link is in the run output.

The workflow is idempotent: re-running with the same inputs detects no change
and exits cleanly.

The workflow reads `MARKETPLACE_REPO`, `MARKETPLACE_FORK`, `BOT_USERNAME`,
`BOT_EMAIL`, and `MARKETPLACE_PAT` from variables and secrets. See
[auth.md](auth.md).

## The script

Prerequisites: `gh`, `jq`, `git`. `gh` must be authenticated against an
account that has a fork of the marketplace and can open PRs upstream.

Set the upstream once (in your shell profile or a sourced env file):

```
export MARKETPLACE_REPO=owner/marketplace-repo
# Optional, defaults to <gh-current-user>/<marketplace-repo-name>:
# export MARKETPLACE_FORK=your-fork-owner/marketplace-repo
```

Run from inside the skill repo:

```
cd ~/code/your-skill
register-skill.sh --category productivity
```

Or with explicit path:

```
register-skill.sh --skill-dir ~/code/your-skill --category productivity --dry-run
```

### Options

| Flag | Description |
|---|---|
| `--skill-dir <path>` | Path to the skill repo. Default: current directory. |
| `--category <name>` | Marketplace category. Optional. |
| `--dry-run` | Show the diff without pushing or opening a PR. |

### Behaviour

- Reads `name`, `description`, and `version` from
  `.claude-plugin/plugin.json`, or from `plugin.json` at repo root for
  flat-layout single-skill plugins.
- Reads the GitHub repo from the skill's `origin` remote.
- Clones `MARKETPLACE_FORK` to a temp directory, syncs with
  `MARKETPLACE_REPO`'s `main`, applies the change, force-pushes the
  `register/<skill-name>` branch to the fork, and opens the PR via `gh pr
  create`.
- Does not override `git config`. Commits and the opened PR are attributed to
  the operator running the script.
- If an entry with the same `name` already exists in the marketplace, the
  script *updates* it instead of adding a duplicate.

## Updating an existing entry

Re-run the workflow or script. If `name`, `description`, `category`, or
`source.repo` has changed, the existing entry is replaced. If nothing has
changed, the run exits without a PR.
