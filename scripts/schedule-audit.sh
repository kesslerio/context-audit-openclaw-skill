#!/usr/bin/env bash
set -euo pipefail

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# context-audit scheduler
# Creates or updates an OpenClaw cron job that runs the audit monthly
#
# Uses agentTurn to have the agent execute the audit script via bash tool.
# The script itself is pure bash (no LLM reasoning needed), so token cost
# is minimal — just the tool call overhead.
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Defaults
SCHEDULE="0 10 1 * *"  # 1st of each month, 10am
TZ="America/Los_Angeles"
AGENT=""
SESSION="isolated"
JOB_NAME="Monthly Context Audit"
CHANNEL=""
TO=""

# Parse args
while [[ $# -gt 0 ]]; do
  case $1 in
    --schedule)
      SCHEDULE="$2"
      shift 2
      ;;
    --tz)
      TZ="$2"
      shift 2
      ;;
    --agent)
      AGENT="$2"
      shift 2
      ;;
    --session)
      SESSION="$2"
      shift 2
      ;;
    --name)
      JOB_NAME="$2"
      shift 2
      ;;
    --channel)
      CHANNEL="$2"
      shift 2
      ;;
    --to)
      TO="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $(basename "$0") [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --schedule EXPR    Cron expression (default: '0 10 1 * *' = 1st of month 10am)"
      echo "  --tz TIMEZONE      Timezone (default: America/Los_Angeles)"
      echo "  --agent ID         Agent ID for the cron job"
      echo "  --session TARGET   Session target: main|isolated (default: isolated)"
      echo "  --name TEXT        Cron job name (default: Monthly Context Audit)"
      echo "  --channel PLATFORM Delivery channel (e.g., telegram, slack, discord)"
      echo "  --to TARGET        Delivery target (e.g., chat ID, channel ID)"
      echo "  -h, --help         Show this help"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Run with --help for usage" >&2
      exit 1
      ;;
  esac
done

# Find the audit script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT_SCRIPT="$SCRIPT_DIR/audit-context.sh"

if [[ ! -f "$AUDIT_SCRIPT" ]]; then
  echo "Error: audit script not found at $AUDIT_SCRIPT" >&2
  exit 1
fi

if ! command -v openclaw >/dev/null 2>&1; then
  echo "Error: openclaw CLI not found in PATH" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required for cron upsert logic" >&2
  exit 1
fi

MESSAGE="Run the context audit script: bash $AUDIT_SCRIPT — then post the output as-is. Do not modify or summarize the report."

# Upsert behavior:
# - If jobs with this name exist, keep one, remove extras, then edit.
# - Otherwise add a new job.
mapfile -t MATCHING_IDS < <(openclaw cron list --all --json | jq -r --arg name "$JOB_NAME" '.jobs[] | select(.name == $name) | .id')

EXISTING_ID=""
if [[ ${#MATCHING_IDS[@]} -gt 0 ]]; then
  EXISTING_ID="${MATCHING_IDS[0]}"
  if [[ ${#MATCHING_IDS[@]} -gt 1 ]]; then
    echo "Found duplicate cron jobs for '$JOB_NAME'. Removing extras..." >&2
    for ((i=1; i<${#MATCHING_IDS[@]}; i++)); do
      echo "  Removing duplicate job: ${MATCHING_IDS[$i]}" >&2
      openclaw cron rm "${MATCHING_IDS[$i]}" >/dev/null
    done
  fi
fi

if [[ -n "$EXISTING_ID" ]]; then
  CMD=(
    openclaw cron edit "$EXISTING_ID"
    --name "$JOB_NAME"
    --cron "$SCHEDULE"
    --tz "$TZ"
    --session "$SESSION"
    --message "$MESSAGE"
    --enable
  )
  [[ -n "$AGENT" ]] && CMD+=(--agent "$AGENT")
  [[ -n "$CHANNEL" ]] && CMD+=(--channel "$CHANNEL" --announce)
  [[ -n "$TO" ]] && CMD+=(--to "$TO")
  echo "Updating existing context audit cron job ($EXISTING_ID)..." >&2
else
  CMD=(
    openclaw cron add
    --name "$JOB_NAME"
    --cron "$SCHEDULE"
    --tz "$TZ"
    --session "$SESSION"
    --message "$MESSAGE"
  )
  [[ -n "$AGENT" ]] && CMD+=(--agent "$AGENT")
  [[ -n "$CHANNEL" ]] && CMD+=(--channel "$CHANNEL" --announce)
  [[ -n "$TO" ]] && CMD+=(--to "$TO")
  echo "Creating context audit cron job..." >&2
fi

"${CMD[@]}"

echo "" >&2
echo "   Job Name: $JOB_NAME" >&2
echo "   Schedule: $SCHEDULE ($TZ)" >&2
echo "   Session: $SESSION" >&2
echo "   Script: $AUDIT_SCRIPT" >&2
echo "" >&2
echo "The audit will scan workspaces and report context file health monthly." >&2
