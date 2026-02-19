#!/usr/bin/env bash
# context-audit configuration
# Copy to ~/.config/context-audit/config.sh and customize

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Workspaces to scan (array of absolute paths)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
WORKSPACES=(
  "$HOME/niemand"
  "$HOME/niemand-code"
  "$HOME/niemand-work"
  "$HOME/niemand-analyst"
  "$HOME/niemand-family"
  "$HOME/niemand-molty"
)

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Token thresholds (estimated tokens = bytes / 4)
# Format: THRESHOLDS[filename]="warn:critical"
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Only applies to files in CONTEXT_FILES (bootstrap set by default).
# Use --all-root-md to scan everything at workspace root.
declare -A THRESHOLDS=(
  [MEMORY.md]="2000:4000"
  [AGENTS.md]="3000:6000"
  [TOOLS.md]="2000:4000"
  [SOUL.md]="1000:2000"
  [BOOTSTRAP.md]="1500:3000"
  [IDENTITY.md]="1000:2000"
  [USER.md]="1000:2000"
  [HEARTBEAT.md]="1000:2000"
)
DEFAULT_THRESHOLD="1000:2000"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Context files to audit (OpenClaw bootstrap set)
# Uncomment/add entries to extend beyond the defaults
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# CONTEXT_FILES=(
#   AGENTS.md SOUL.md TOOLS.md IDENTITY.md USER.md
#   HEARTBEAT.md BOOTSTRAP.md MEMORY.md
#   COMMUNICATION.md SKILLS.md WRITING_STYLE.md  # extras
# )

# Set true to scan every root *.md file (higher noise, broader coverage)
# ALL_ROOT_MD=true

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Memory directory settings
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
MEMORY_DIR_NAME="memory"
MEMORY_FILE_WARN=50

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Duplication detection
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
DUP_MIN_WORDS=50  # Minimum paragraph word count to check for duplicates

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Growth tracking
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
GROWTH_WARN_PERCENT=30
BASELINE_DIR="$HOME/.openclaw/context-audit"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Notification
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Set to send reports via openclaw message send
# Leave empty to only print to stdout
NOTIFY_CHANNEL=""
NOTIFY_TARGET=""
