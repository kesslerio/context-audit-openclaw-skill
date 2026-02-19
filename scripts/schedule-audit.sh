#!/usr/bin/env bash
set -euo pipefail

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# context-audit scheduler
# Creates an OpenClaw cron job that runs the audit monthly
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
    -h|--help)
      echo "Usage: $(basename "$0") [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --schedule EXPR    Cron expression (default: '0 10 1 * *' = 1st of month 10am)"
      echo "  --tz TIMEZONE      Timezone (default: America/Los_Angeles)"
      echo "  --agent ID         Agent ID for the cron job"
      echo "  --session TARGET   Session target: main|isolated (default: isolated)"
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

# Build the openclaw cron add command
CMD=(
  openclaw cron add
  --name "Monthly Context Audit"
  --cron "$SCHEDULE"
  --tz "$TZ"
  --session "$SESSION"
  --message "Run the context audit script: bash $AUDIT_SCRIPT — then post the output as-is. Do not modify or summarize the report."
)

[[ -n "$AGENT" ]] && CMD+=(--agent "$AGENT")

echo "Creating context audit cron job..." >&2
"${CMD[@]}"

echo "" >&2
echo "   Schedule: $SCHEDULE ($TZ)" >&2
echo "   Session: $SESSION" >&2
echo "   Script: $AUDIT_SCRIPT" >&2
echo "" >&2
echo "The audit will scan workspaces and report context file health monthly." >&2
