# Guardrails — pre-publish hygiene gate

`scripts/guardrails.sh` + `.github/workflows/guardrails.yml` block the mistakes that
must never reach a public or shared repo. It exists because they already happened once:
a personal name + private email landed in a plugin's `plugin.json`, and `/home/<user>/`
paths (pointing at a real PAT file) were committed.

## What it checks

| Check | Fails on |
|---|---|
| **secrets** | Proton PATs (`pst_…::…`), private-key blocks, GitHub tokens (`ghp_…`/`gho_…`/…), AWS keys (`AKIA…`) |
| **identity** | any email, or `plugin.json` `author.name`/`author.email`, not in `.github/identity-allowlist.txt` |
| **local-paths** | absolute `/home/<user>/` or `/Users/<user>/` paths (allows `runner` and the `youruser` placeholder) |

The allowlist (`.github/identity-allowlist.txt`) holds the approved org identities
(maintainer persona + bot). Add new approved identities there — never silence the check
by committing a real name.

## Run it locally before pushing

```bash
bash scripts/guardrails.sh .            # scan current repo
bash scripts/guardrails.sh ../some-plugin
```

Exit 0 = clean; non-zero prints every finding.

## Use it in another repo

This repo's `guardrails.yml` is reusable. Add a tiny caller to any plugin repo:

```yaml
# .github/workflows/guardrails.yml
name: Guardrails
on: [pull_request, push]
jobs:
  guardrails:
    uses: alfred-intelligence/workflows/.github/workflows/guardrails.yml@main
```

It checks out the calling repo, runs the org's scanner against it, and fails the PR on
any finding — so the next leak is stopped before merge, not after publish.
