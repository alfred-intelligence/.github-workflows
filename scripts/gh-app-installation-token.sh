#!/usr/bin/env bash
# gh-app-installation-token.sh — mint a short-lived GitHub App installation
# access token OUTSIDE a GitHub Actions workflow (local agent/script use).
#
# Why this exists: inside a workflow, actions/create-github-app-token does
# this for you. Local agents (e.g. Governator running sweeps via Bash, not
# inside Actions) have no equivalent action, so this replicates the same
# JWT -> installation-token exchange documented in
# .github-private/strategy/meta-apps.md ("Token issuance pattern > Outside
# a workflow").
#
# The output token is exactly as narrow as the App's declared permissions —
# this script does not (and cannot) request anything broader than what the
# App was registered with. It expires in 1 hour; callers should not cache it.
#
# Usage:
#   gh-app-installation-token.sh <app-id> <private-key-path> <org-login>
#
# Reads the App ID and PEM private-key path as arguments (never inline) so
# callers can source them from a secrets broker (Infisical, GitHub Actions
# secrets, etc.) without this script ever seeing where they're stored.
# Prints the installation access token to stdout and nothing else — safe
# to capture with `token=$(...)`. All diagnostics go to stderr.
#
# Example (Governator's org-ruleset check, credentials injected by the
# caller from Infisical — see docs/aifred-governance-app.md):
#   token=$(gh-app-installation-token.sh "$GH_APP_AIFRED_GOVERNANCE_ID" \
#     "$GH_APP_AIFRED_GOVERNANCE_KEY_PATH" alfred-intelligence)
#   gh api -H "Authorization: Bearer $token" orgs/alfred-intelligence/rulesets

set -euo pipefail

usage() {
  echo "Usage: $0 <app-id> <private-key-path> <org-login>" >&2
  exit 2
}

[[ $# -eq 3 ]] || usage

app_id="$1"
private_key_path="$2"
org_login="$3"

[[ -r "$private_key_path" ]] || {
  echo "gh-app-installation-token: cannot read private key at $private_key_path" >&2
  exit 1
}

for bin in openssl curl jq; do
  command -v "$bin" >/dev/null 2>&1 || {
    echo "gh-app-installation-token: missing required tool: $bin" >&2
    exit 1
  }
done

# --- Step 1: build a short-lived (9 min, under GitHub's 10 min ceiling) JWT
# signed with the App's private key. This JWT authenticates as the App
# itself, not as any installation — it can only be used to look up
# installations and mint installation tokens, nothing else.
now=$(date +%s)
iat=$((now - 60))     # allow for clock drift
exp=$((now + 540))    # 9 minutes

b64url() {
  # Standard base64 -> URL-safe base64 without padding, per RFC 7519.
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$iat" "$exp" "$app_id" | b64url)
signing_input="${header}.${payload}"
signature=$(printf '%s' "$signing_input" | openssl dgst -sha256 -sign "$private_key_path" | b64url)
jwt="${signing_input}.${signature}"

# --- Step 2: resolve this App's installation ID on the target org. Fails
# closed (non-zero exit) if the App isn't installed there — this is a
# deliberate check, not just error-passthrough, so a misconfigured caller
# gets a clear message instead of a confusing downstream 404.
installation_id=$(curl -sS \
  -H "Authorization: Bearer ${jwt}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/orgs/${org_login}/installation" \
  | jq -r '.id // empty')

if [[ -z "$installation_id" ]]; then
  echo "gh-app-installation-token: App ${app_id} is not installed on org ${org_login} (or the JWT was rejected)" >&2
  exit 1
fi

# --- Step 3: exchange for a 1-hour installation access token. No
# `permissions` or `repositories` body is passed — the token inherits
# exactly the App's declared permissions, nothing more, nothing less.
# (Callers needing a further-narrowed subset can pass a `permissions`
# object here; deliberately omitted for this narrow-by-design App.)
response=$(curl -sS -X POST \
  -H "Authorization: Bearer ${jwt}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/app/installations/${installation_id}/access_tokens")

token=$(printf '%s' "$response" | jq -r '.token // empty')

if [[ -z "$token" ]]; then
  echo "gh-app-installation-token: failed to mint installation token: ${response}" >&2
  exit 1
fi

printf '%s\n' "$token"
