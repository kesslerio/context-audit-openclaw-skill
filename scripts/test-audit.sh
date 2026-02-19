#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT_SCRIPT="$SCRIPT_DIR/audit-context.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

ws="$tmpdir/ws"
mkdir -p "$ws"

cat > "$ws/AGENTS.md" <<'EOF'
# AGENTS
short
EOF

# Large non-bootstrap markdown file used to verify --all-root-md behavior.
head -c 9000 /dev/zero | tr '\0' 'a' > "$ws/NOISE.md"

out_default="$(
  bash "$AUDIT_SCRIPT" \
    --dry-run \
    --workspace "$ws" \
    --baseline-dir "$tmpdir/baseline-default" \
    2>&1
)"

if echo "$out_default" | rg -q "NOISE.md"; then
  echo "FAIL: default scan unexpectedly included NOISE.md" >&2
  exit 1
fi

out_all_root="$(
  bash "$AUDIT_SCRIPT" \
    --dry-run \
    --workspace "$ws" \
    --all-root-md \
    --baseline-dir "$tmpdir/baseline-all-root" \
    2>&1
)"

if ! echo "$out_all_root" | rg -q "NOISE.md"; then
  echo "FAIL: --all-root-md did not include NOISE.md" >&2
  exit 1
fi

mkdir -p "$tmpdir/baseline-corrupt"
echo "{bad json" > "$tmpdir/baseline-corrupt/baseline.json"

out_bad_baseline="$(
  bash "$AUDIT_SCRIPT" \
    --dry-run \
    --workspace "$ws" \
    --baseline-dir "$tmpdir/baseline-corrupt" \
    2>&1
)"

if ! echo "$out_bad_baseline" | rg -q "invalid JSON"; then
  echo "FAIL: malformed baseline warning was not emitted" >&2
  exit 1
fi

echo "PASS: context-audit smoke tests"
