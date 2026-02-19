#!/usr/bin/env bash
set -euo pipefail

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# context-audit — Monthly context file audit
# Scans agent workspaces for bloated context files, growth drift, and duplicates
#
# USAGE: audit-context.sh [--dry-run] [--config PATH] [--workspace DIR]...
# OUTPUT: Formatted report to stdout, optionally posted via openclaw message send
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"

# ── Preflight ────────────────────────────────────────────────────────────────

for cmd in jq md5sum awk; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: required command '$cmd' not found" >&2
    exit 1
  fi
done

# ── Defaults (overridden by config file, then CLI args) ──────────────────────

WORKSPACES=()
declare -A THRESHOLDS=()
DEFAULT_THRESHOLD="1000:2000"
# Only OpenClaw-injected bootstrap files are audited by default.
# Override in config or use --all-root-md to scan everything.
CONTEXT_FILES=(
  AGENTS.md SOUL.md TOOLS.md IDENTITY.md USER.md
  HEARTBEAT.md BOOTSTRAP.md MEMORY.md
)
ALL_ROOT_MD=false
MEMORY_DIR_NAME="memory"
MEMORY_FILE_WARN=50
DUP_MIN_WORDS=50
GROWTH_WARN_PERCENT=30
BASELINE_DIR="$HOME/.openclaw/context-audit"
NOTIFY_CHANNEL=""
NOTIFY_TARGET=""
DRY_RUN=false
CONFIG_PATH=""

# ── Parse CLI args (before config, to get --config path) ─────────────────────

CLI_WORKSPACES=()

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --config)
      CONFIG_PATH="$2"
      shift 2
      ;;
    --workspace)
      CLI_WORKSPACES+=("$2")
      shift 2
      ;;
    --notify-channel)
      NOTIFY_CHANNEL="$2"
      shift 2
      ;;
    --notify-target)
      NOTIFY_TARGET="$2"
      shift 2
      ;;
    --baseline-dir)
      BASELINE_DIR="$2"
      shift 2
      ;;
    --all-root-md)
      ALL_ROOT_MD=true
      shift
      ;;
    -h|--help)
      echo "Usage: $(basename "$0") [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --dry-run              Print report only, do not send notification"
      echo "  --config PATH          Path to config file"
      echo "  --workspace DIR        Workspace directory to scan (repeatable)"
      echo "  --all-root-md          Scan all *.md at workspace root (not just bootstrap set)"
      echo "  --notify-channel CH    Notification channel (e.g., telegram)"
      echo "  --notify-target ID     Notification target (e.g., chat ID)"
      echo "  --baseline-dir DIR     Directory for baseline storage"
      echo "  -h, --help             Show this help"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Run with --help for usage" >&2
      exit 1
      ;;
  esac
done

# ── Load config (top-level source so declare -A works) ───────────────────────
# Priority: explicit --config > ~/.config/context-audit/config.sh > skill-local

_config_loaded=false
if [[ -n "$CONFIG_PATH" ]]; then
  [[ -f "$CONFIG_PATH" ]] || { echo "Error: config not found at $CONFIG_PATH" >&2; exit 1; }
  # shellcheck source=/dev/null
  source "$CONFIG_PATH"
  _config_loaded=true
elif [[ -f "$HOME/.config/context-audit/config.sh" ]]; then
  # shellcheck source=/dev/null
  source "$HOME/.config/context-audit/config.sh"
  _config_loaded=true
elif [[ -f "$SKILL_DIR/config.sh" ]]; then
  # shellcheck source=/dev/null
  source "$SKILL_DIR/config.sh"
  _config_loaded=true
fi

# CLI workspaces override config
if [[ ${#CLI_WORKSPACES[@]} -gt 0 ]]; then
  WORKSPACES=("${CLI_WORKSPACES[@]}")
fi

# Validate we have workspaces
if [[ ${#WORKSPACES[@]} -eq 0 ]]; then
  echo "Error: no workspaces configured" >&2
  echo "Set WORKSPACES in config file or use --workspace DIR" >&2
  exit 1
fi

# Build lookup set from CONTEXT_FILES array
declare -A CONTEXT_FILE_SET
for f in "${CONTEXT_FILES[@]}"; do
  CONTEXT_FILE_SET[$f]=1
done

# ── Helpers ──────────────────────────────────────────────────────────────────

estimate_tokens() {
  local file="$1"
  local bytes
  bytes=$(wc -c < "$file" 2>/dev/null || echo 0)
  echo $(( (bytes + 3) / 4 ))  # ~1 token per 4 chars/bytes, ceiling
}

get_threshold() {
  local filename="$1"
  local thresh="${THRESHOLDS[$filename]:-$DEFAULT_THRESHOLD}"
  echo "$thresh"
}

# Stable workspace key: full resolved path for baseline JSON keys
workspace_key() {
  local ws="$1"
  # Resolve symlinks, normalize trailing slashes
  readlink -f "$ws" 2>/dev/null || echo "$ws"
}

# Short name for display in reports
workspace_label() {
  basename "$1"
}

# ── Ensure baseline dir exists ───────────────────────────────────────────────

mkdir -p "$BASELINE_DIR"
BASELINE_FILE="$BASELINE_DIR/baseline.json"

# Load existing baseline (or empty object)
if [[ -f "$BASELINE_FILE" ]]; then
  BASELINE=$(cat "$BASELINE_FILE")
else
  BASELINE="{}"
fi

# ── Scan workspaces ──────────────────────────────────────────────────────────

CRITICALS=()
WARNINGS=()
DUPLICATES=()
HEALTHY_COUNT=0
TOTAL_TOKENS=0
WORKSPACE_COUNT=0
NEW_BASELINE="$BASELINE"  # Start from existing baseline to preserve history

# For duplicate detection: hash -> "workspace/file" mappings
declare -A PARAGRAPH_HASHES  # hash -> "ws1/file|ws2/file|..."
declare -A PARAGRAPH_TEXTS   # hash -> preview text for display
declare -A PARAGRAPH_TOKENS  # hash -> estimated token count

for ws in "${WORKSPACES[@]}"; do
  [[ -d "$ws" ]] || continue
  WORKSPACE_COUNT=$((WORKSPACE_COUNT + 1))
  ws_key=$(workspace_key "$ws")
  ws_label=$(workspace_label "$ws")

  # Build file list: bootstrap set by default, or all *.md with --all-root-md
  scan_files=()
  if [[ "$ALL_ROOT_MD" == "true" ]]; then
    for mdfile in "$ws"/*.md; do
      [[ -f "$mdfile" ]] && scan_files+=("$mdfile")
    done
  else
    for fname in "${CONTEXT_FILES[@]}"; do
      [[ -f "$ws/$fname" ]] && scan_files+=("$ws/$fname")
    done
  fi

  for mdfile in "${scan_files[@]}"; do
    filename=$(basename "$mdfile")
    tokens=$(estimate_tokens "$mdfile")
    bytes=$(wc -c < "$mdfile" 2>/dev/null || echo 0)
    TOTAL_TOKENS=$((TOTAL_TOKENS + tokens))

    # Get thresholds
    thresh=$(get_threshold "$filename")
    warn_limit="${thresh%%:*}"
    crit_limit="${thresh##*:}"

    # Check previous baseline for growth
    growth_info=""
    prev_tokens=$(echo "$BASELINE" | jq -r --arg ws "$ws_key" --arg f "$filename" \
      '.[$ws][$f].tokens // 0' 2>/dev/null || echo 0)
    if [[ "$prev_tokens" -gt 0 && "$tokens" -gt 0 ]]; then
      delta=$((tokens - prev_tokens))
      if [[ "$prev_tokens" -gt 0 ]]; then
        pct=$(( (delta * 100) / prev_tokens ))
      else
        pct=0
      fi
      if [[ "$delta" -gt 0 && "$pct" -ge "$GROWTH_WARN_PERCENT" ]]; then
        growth_info="  ↑ grew $delta tokens (+${pct}%) since last audit"
      elif [[ "$delta" -lt 0 ]]; then
        abs_delta=$(( -delta ))
        growth_info="  ↓ shrank $abs_delta tokens since last audit"
      fi
    fi

    # Classify
    if [[ "$tokens" -ge "$crit_limit" ]]; then
      entry="$ws_label/$filename: ~${tokens} tokens (critical limit: ${crit_limit})"
      [[ -n "$growth_info" ]] && entry="$entry"$'\n'"$growth_info"
      CRITICALS+=("$entry")
    elif [[ "$tokens" -ge "$warn_limit" ]]; then
      entry="$ws_label/$filename: ~${tokens} tokens (warn limit: ${warn_limit})"
      [[ -n "$growth_info" ]] && entry="$entry"$'\n'"$growth_info"
      WARNINGS+=("$entry")
    else
      HEALTHY_COUNT=$((HEALTHY_COUNT + 1))
      # Still report significant growth even on healthy files
      if [[ -n "$growth_info" ]]; then
        WARNINGS+=("$ws_label/$filename: ~${tokens} tokens (under limits but notable growth)"$'\n'"$growth_info")
      fi
    fi

    # Update baseline (merge into existing, preserving unscanned workspaces)
    NEW_BASELINE=$(echo "$NEW_BASELINE" | jq \
      --arg ws "$ws_key" --arg f "$filename" \
      --argjson t "$tokens" --argjson b "$bytes" \
      '.[$ws] //= {} | .[$ws][$f] = {tokens: $t, bytes: $b}')

    # Extract paragraphs for duplicate detection
    # A "paragraph" = block of text separated by blank lines, normalized
    while IFS= read -r -d '' para; do
      word_count=$(echo "$para" | wc -w)
      [[ "$word_count" -lt "$DUP_MIN_WORDS" ]] && continue

      # Normalize: lowercase, collapse whitespace, strip markdown headers
      normalized=$(echo "$para" | tr '[:upper:]' '[:lower:]' | sed 's/^#\+\s*//' | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//')
      hash=$(echo -n "$normalized" | md5sum | cut -d' ' -f1)
      para_bytes=$(echo -n "$para" | wc -c)
      para_tokens=$(( (para_bytes + 3) / 4 ))

      location="$ws_label/$filename"
      if [[ -n "${PARAGRAPH_HASHES[$hash]:-}" ]]; then
        # Exact pipe-delimited match to avoid substring false positives
        if [[ "|${PARAGRAPH_HASHES[$hash]}|" != *"|$location|"* ]]; then
          PARAGRAPH_HASHES[$hash]="${PARAGRAPH_HASHES[$hash]}|$location"
        fi
      else
        PARAGRAPH_HASHES[$hash]="$location"
        PARAGRAPH_TEXTS[$hash]=$(echo "$para" | head -c 200 | tr '\n' ' ' | sed 's/  */ /g;s/^ //;s/ $//')
        PARAGRAPH_TOKENS[$hash]="$para_tokens"
      fi
    done < <(
      # Split file into paragraphs (separated by blank lines), null-terminated
      awk 'BEGIN{RS=""; ORS="\0"} {print}' "$mdfile"
    )
  done

  # Check memory directory
  mem_dir="$ws/$MEMORY_DIR_NAME"
  if [[ -d "$mem_dir" ]]; then
    file_count=$(find "$mem_dir" -maxdepth 1 -type f | wc -l)
    if [[ "$file_count" -ge "$MEMORY_FILE_WARN" ]]; then
      WARNINGS+=("$ws_label/$MEMORY_DIR_NAME/: $file_count files (suggest archival, threshold: $MEMORY_FILE_WARN)")
    fi
  fi
done

# Collect duplicates
for hash in "${!PARAGRAPH_HASHES[@]}"; do
  locations="${PARAGRAPH_HASHES[$hash]}"
  # Only flag if found in 2+ locations
  if [[ "$locations" == *"|"* ]]; then
    preview="${PARAGRAPH_TEXTS[$hash]}"
    tokens="${PARAGRAPH_TOKENS[$hash]}"
    loc_display=$(echo "$locations" | tr '|' ', ')
    DUPLICATES+=("\"${preview:0:60}...\" (~${tokens} tokens)"$'\n'"  Found in: $loc_display")
  fi
done

# ── Build report ─────────────────────────────────────────────────────────────

DATE=$(date '+%b %-d, %Y')

if [[ ${#CRITICALS[@]} -eq 0 && ${#WARNINGS[@]} -eq 0 && ${#DUPLICATES[@]} -eq 0 ]]; then
  REPORT="✅ Context Audit — $DATE: All clear. ~${TOTAL_TOKENS} tokens across $WORKSPACE_COUNT workspaces."
else
  REPORT="🔍 Context Audit — $DATE"
  REPORT+=$'\n'"━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if [[ ${#CRITICALS[@]} -gt 0 ]]; then
    REPORT+=$'\n\n'"🔴 CRITICAL (${#CRITICALS[@]})"
    for item in "${CRITICALS[@]}"; do
      REPORT+=$'\n'"• $item"
    done
  fi

  if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    REPORT+=$'\n\n'"⚠️ WARNINGS (${#WARNINGS[@]})"
    for item in "${WARNINGS[@]}"; do
      REPORT+=$'\n'"• $item"
    done
  fi

  if [[ ${#DUPLICATES[@]} -gt 0 ]]; then
    REPORT+=$'\n\n'"🔄 DUPLICATES (${#DUPLICATES[@]})"
    for item in "${DUPLICATES[@]}"; do
      REPORT+=$'\n'"• $item"
    done
  fi

  REPORT+=$'\n\n'"✅ HEALTHY ($HEALTHY_COUNT files across $WORKSPACE_COUNT workspaces)"
  REPORT+=$'\n\n'"━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  REPORT+=$'\n'"Total context: ~${TOTAL_TOKENS} tokens across $WORKSPACE_COUNT workspaces"
fi

# ── Output ───────────────────────────────────────────────────────────────────

echo "$REPORT"

# Save new baseline
echo "$NEW_BASELINE" | jq '.' > "$BASELINE_FILE"

# Send notification
if [[ "$DRY_RUN" == "true" ]]; then
  echo "" >&2
  echo "(dry-run: notification skipped)" >&2
elif [[ -n "$NOTIFY_CHANNEL" && -n "$NOTIFY_TARGET" ]]; then
  if command -v openclaw &>/dev/null; then
    openclaw message send \
      --channel "$NOTIFY_CHANNEL" \
      --target "$NOTIFY_TARGET" \
      --message "$REPORT" 2>&1 || echo "Warning: failed to send notification" >&2
  else
    echo "Warning: openclaw not found, skipping notification" >&2
  fi
fi
