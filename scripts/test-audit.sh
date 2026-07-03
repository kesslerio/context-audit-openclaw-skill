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

# ── Total bootstrap budget gate ──────────────────────────────────────────────
# Hermetic: an empty temp config forces script defaults (WARN 11000 / CRIT 14000)
# so assertions test the code, not the developer's live ~/.config copy.
# (/dev/null can't be used here — it's a char device, not a regular file, so the
#  script's `[[ -f CONFIG ]]` guard rejects it.)
hermetic_config="$tmpdir/hermetic-config.sh"
: > "$hermetic_config"

# CRIT via per-workspace SUM: two bootstrap files each < CRIT, together >= 14000.
# This proves the gate sums the bootstrap set (not max/first file).
ws_sum="$tmpdir/bootstrap-sum"
mkdir -p "$ws_sum"
head -c 33000 /dev/zero | tr '\0' 'b' > "$ws_sum/AGENTS.md"   # ~8250 tok
head -c 33000 /dev/zero | tr '\0' 'b' > "$ws_sum/TOOLS.md"    # ~8250 tok => ~16500 sum

# WARN band (>= 11000, < 14000).
ws_warn="$tmpdir/bootstrap-warn"
mkdir -p "$ws_warn"
head -c 48000 /dev/zero | tr '\0' 'b' > "$ws_warn/AGENTS.md"  # ~12000 tok

out_bootstrap_budget="$(
  bash "$AUDIT_SCRIPT" \
    --dry-run \
    --config "$hermetic_config" \
    --workspace "$ws" \
    --workspace "$ws_sum" \
    --workspace "$ws_warn" \
    --baseline-dir "$tmpdir/baseline-bootstrap" \
    2>&1
)"

if ! echo "$out_bootstrap_budget" | rg -q "TOTAL BOOTSTRAP BUDGET"; then
  echo "FAIL: total bootstrap budget section was not emitted" >&2
  exit 1
fi

if ! echo "$out_bootstrap_budget" | rg -q "bootstrap-sum: ~16500 tokens \(critical limit: 14000\)"; then
  echo "FAIL: summed bootstrap workspace was not marked critical" >&2
  exit 1
fi

if ! echo "$out_bootstrap_budget" | rg -q "bootstrap-warn: ~12000 tokens \(warn limit: 11000\)"; then
  echo "FAIL: mid-range bootstrap workspace was not marked warn" >&2
  exit 1
fi

if ! echo "$out_bootstrap_budget" | rg -q "✅ ws: ~[0-9]+ tokens"; then
  echo "FAIL: under-budget workspace not rendered in OK bucket" >&2
  exit 1
fi

if echo "$out_bootstrap_budget" | rg -q "ws: ~[0-9]+ tokens \(critical limit: 14000\)"; then
  echo "FAIL: small workspace was unexpectedly marked bootstrap-critical" >&2
  exit 1
fi

# --all-root-md scans non-bootstrap *.md for per-file checks, but must NOT fold
# them into the per-workspace bootstrap total.
ws_allroot="$tmpdir/bootstrap-allroot"
mkdir -p "$ws_allroot"
printf '# a\nx\n' > "$ws_allroot/AGENTS.md"                    # tiny bootstrap file
head -c 60000 /dev/zero | tr '\0' 'b' > "$ws_allroot/NOISE.md" # large non-bootstrap md

out_allroot="$(
  bash "$AUDIT_SCRIPT" \
    --dry-run \
    --config "$hermetic_config" \
    --all-root-md \
    --workspace "$ws_allroot" \
    --baseline-dir "$tmpdir/baseline-allroot" \
    2>&1
)"

if echo "$out_allroot" | rg -q "bootstrap-allroot: ~[0-9]+ tokens \(critical limit: 14000\)"; then
  echo "FAIL: --all-root-md folded a non-bootstrap file into the bootstrap total" >&2
  exit 1
fi

# A configured-but-missing workspace directory must be surfaced, not silently skipped.
out_missing="$(
  bash "$AUDIT_SCRIPT" \
    --dry-run \
    --config "$hermetic_config" \
    --workspace "$tmpdir/does-not-exist" \
    --baseline-dir "$tmpdir/baseline-missing" \
    2>&1
)"

if ! echo "$out_missing" | rg -q "does-not-exist: configured workspace directory not found"; then
  echo "FAIL: missing workspace directory was not surfaced" >&2
  exit 1
fi

echo "PASS: context-audit smoke tests"
