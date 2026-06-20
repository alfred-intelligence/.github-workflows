#!/usr/bin/env bash
# guardrails.sh — pre-publish hygiene scanner for alfred-intelligence repos.
#
# Catches the classes of mistake that must never reach a public/shared repo:
#   1. Secrets            — Proton PATs, private keys, GitHub/AWS tokens
#   2. Personal identity  — emails / author names outside the approved allowlist
#   3. Local path leaks   — /home/<user>/ or /Users/<user>/ absolute paths
#   4. plugin.json author — must be an approved org identity
#
# Usage: guardrails.sh [SUBJECT_DIR]   (default: .)
# Exits non-zero (and prints every finding) if anything trips.
set -uo pipefail

SUBJECT="${1:-.}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALLOWLIST="${GUARDRAILS_ALLOWLIST:-$SCRIPT_DIR/../.github/identity-allowlist.txt}"

fail=0
note() { printf '  %s\n' "$1"; }
section() { printf '\n=== %s ===\n' "$1"; }

# Files to scan: tracked files if a git repo, else everything. Skip binaries,
# deps, and the guardrail's own files (they legitimately contain the patterns).
mapfile -t FILES < <(
  { git -C "$SUBJECT" ls-files 2>/dev/null || (cd "$SUBJECT" && find . -type f); } \
  | sed 's#^\./##' \
  | grep -vE '(^|/)(\.git/|node_modules/)' \
  | grep -vE '(^|/)(guardrails\.sh|guardrails\.md|identity-allowlist\.txt)$' \
  | grep -vE '\.(png|jpe?g|gif|webp|ico|pdf|zip|gz|tgz|woff2?|ttf|otf|mp4|mov)$'
)
abs() { printf '%s/%s' "${SUBJECT%/}" "$1"; }

# ---------- 1. secrets ----------
section "secrets"
SECRET_RE='pst_[A-Za-z0-9]+::[A-Za-z0-9_-]+|-----BEGIN[A-Z ]*PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9]{36,}|AKIA[0-9A-Z]{16}'
for f in "${FILES[@]}"; do
  absf="$(abs "$f")"
  if hits=$(grep -nHE "$SECRET_RE" "$absf" 2>/dev/null); then
    echo "${hits//$absf/$f}"; fail=1
  fi
done
[[ $fail -eq 0 ]] && note "ok"

# ---------- 2. & 4. identity (emails + plugin.json author) ----------
section "identity"
id_fail=0
# Build allowed-token set from the allowlist (emails and names, '#' comments ignored).
ALLOWED=""
[[ -f "$ALLOWLIST" ]] && ALLOWED=$(grep -vE '^\s*(#|$)' "$ALLOWLIST")
is_allowed() { grep -Fxq -- "$1" <<<"$ALLOWED"; }

EMAIL_RE='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
for f in "${FILES[@]}"; do
  while IFS= read -r email; do
    [[ -z "$email" ]] && continue
    # noreply addresses of the bot are fine; everything else must be allowlisted.
    if ! is_allowed "$email"; then
      echo "  $f: disallowed email '$email'"; id_fail=1
    fi
  done < <(grep -ohE "$EMAIL_RE" "$(abs "$f")" 2>/dev/null | sort -u)
done

# plugin.json author must be an approved identity.
for mf in ".claude-plugin/plugin.json" "plugin.json"; do
  p="$(abs "$mf")"
  [[ -f "$p" ]] || continue
  if command -v jq >/dev/null 2>&1; then
    aname=$(jq -r '.author.name // empty' "$p" 2>/dev/null)
    aemail=$(jq -r '.author.email // empty' "$p" 2>/dev/null)
    [[ -n "$aname" ]] && ! is_allowed "$aname" && { echo "  $mf: author.name '$aname' not in allowlist"; id_fail=1; }
    [[ -n "$aemail" ]] && ! is_allowed "$aemail" && { echo "  $mf: author.email '$aemail' not in allowlist"; id_fail=1; }
  fi
done
[[ $id_fail -eq 0 ]] && note "ok" || fail=1

# ---------- 3. local path leaks ----------
section "local-paths"
path_fail=0
# allow CI runner paths and the documented placeholder user
PATH_RE='/home/[A-Za-z0-9._-]+|/Users/[A-Za-z0-9._-]+'
for f in "${FILES[@]}"; do
  absf="$(abs "$f")"
  if hits=$(grep -nHE "$PATH_RE" "$absf" 2>/dev/null | grep -vE '/home/(runner|youruser)\b|/Users/youruser\b'); then
    echo "${hits//$absf/$f}"; path_fail=1
  fi
done
[[ $path_fail -eq 0 ]] && note "ok" || fail=1

section "result"
if [[ $fail -ne 0 ]]; then
  echo "GUARDRAILS FAILED — fix the findings above before publishing."
  exit 1
fi
echo "GUARDRAILS PASSED"
