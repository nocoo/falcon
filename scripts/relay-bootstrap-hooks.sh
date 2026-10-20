#!/usr/bin/env bash
# Explicit Husky install for Falcon relay Worker checks.
# Running this script is the install request. Do not run until the parent is ready.
# Marker: relay-hooks-bootstrap
#
# Optional BUN_CONFIG_REGISTRY: validated and stored as repo-local git config
# falcon.relayRegistry (never Bun global). Absent env preserves an existing value.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

REGISTRY_KEY="falcon.relayRegistry"
VALIDATE="$ROOT/scripts/relay-check-index.py"

HUSKY_BIN="$ROOT/services/relay/node_modules/.bin/husky"
if [[ ! -x "$HUSKY_BIN" ]]; then
  echo "relay-bootstrap-hooks: missing executable $HUSKY_BIN" >&2
  echo "Install services/relay dependencies (including husky) first." >&2
  exit 1
fi

if [[ ! -f .husky/pre-commit ]]; then
  echo "relay-bootstrap-hooks: missing .husky/pre-commit" >&2
  exit 1
fi

if [[ ! -f "$VALIDATE" ]]; then
  echo "relay-bootstrap-hooks: missing $VALIDATE" >&2
  exit 1
fi

chmod +x .husky/pre-commit scripts/relay-check-index.py scripts/relay-verify-production.py

if [[ -n "${BUN_CONFIG_REGISTRY:-}" ]]; then
  validated="$(python3 "$VALIDATE" --validate-registry "$BUN_CONFIG_REGISTRY")"
  git config "$REGISTRY_KEY" "$validated"
  echo "relay-bootstrap-hooks: recorded $REGISTRY_KEY for offline Bun cache namespace"
elif git config --get "$REGISTRY_KEY" >/dev/null 2>&1; then
  echo "relay-bootstrap-hooks: preserving existing $REGISTRY_KEY (BUN_CONFIG_REGISTRY unset)"
else
  echo "relay-bootstrap-hooks: no $REGISTRY_KEY; snapshot install uses default Bun registry"
fi

# Husky creates .husky/_ launcher and sets core.hooksPath=.husky/_
"$HUSKY_BIN" .husky

hooks_path="$(git config --get core.hooksPath || true)"
if [[ "$hooks_path" != ".husky/_" ]]; then
  echo "relay-bootstrap-hooks: expected core.hooksPath=.husky/_, got ${hooks_path:-empty}" >&2
  exit 1
fi
if [[ ! -f .husky/_/h ]]; then
  echo "relay-bootstrap-hooks: husky did not create .husky/_ launcher" >&2
  exit 1
fi

echo "relay-hooks-bootstrap: core.hooksPath=.husky/_"
echo "Installed via services/relay husky. Worker index-snapshot gate only; Swift L1 remains explicit and incomplete."
