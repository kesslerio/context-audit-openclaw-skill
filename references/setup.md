# Setup Guide

Step-by-step instructions for setting up context-audit with an OpenClaw cron job.

## Prerequisites

- OpenClaw gateway running (`openclaw doctor` to verify)
- `jq` installed (`jq --version`)
- One or more agent workspaces with `.md` context files at their root

## 1. Install the Skill

Clone or copy into your skills directory:

```bash
cd ~/projects/skills/shared/
git clone https://github.com/kesslerio/context-audit-openclaw-skill.git context-audit
```

Or if using the skills sync framework:

```bash
# After cloning, sync to workspaces
bash ~/projects/skills/sync-skills.sh
```

## 2. Configure

```bash
mkdir -p ~/.config/context-audit
cp ~/projects/skills/shared/context-audit/config.example.sh ~/.config/context-audit/config.sh
```

Edit `~/.config/context-audit/config.sh`:

```bash
# Point to your agent workspaces
WORKSPACES=(
  "$HOME/my-agent"
  "$HOME/my-agent-work"
)

# Adjust token thresholds if needed
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

# Optional: add non-bootstrap files to the scan
# CONTEXT_FILES=(
#   AGENTS.md SOUL.md TOOLS.md IDENTITY.md USER.md
#   HEARTBEAT.md BOOTSTRAP.md MEMORY.md
#   COMMUNICATION.md SKILLS.md  # extras
# )

# Optional: notification via openclaw message send
# (only used for manual runs; cron delivery is separate)
NOTIFY_CHANNEL="telegram"
NOTIFY_TARGET="-YOUR_CHAT_ID"
```

## 3. Test

```bash
# Dry run — prints report, skips notification
bash ~/projects/skills/shared/context-audit/scripts/audit-context.sh --dry-run

# Verify baseline was created
cat ~/.openclaw/context-audit/baseline.json | jq 'keys'
```

## 4. Schedule the Cron Job

The scheduler creates an OpenClaw cron job that runs as an agentTurn (isolated session). The agent executes the bash script and the output is delivered to your chosen channel.

```bash
# Basic — 1st of month, 10am PT, deliver to Telegram
bash scripts/schedule-audit.sh \
  --channel telegram \
  --to "-YOUR_CHAT_ID"

# With all options
bash scripts/schedule-audit.sh \
  --schedule "0 10 1 * *" \
  --tz "America/Los_Angeles" \
  --channel telegram \
  --to "-YOUR_CHAT_ID" \
  --agent my-agent \
  --session isolated
```

Verify:

```bash
openclaw cron list | grep -i "context audit"
```

The scheduler is idempotent — running it again updates the existing job instead of creating a duplicate.

## 5. How the Cron Job Works

Understanding the flow helps with troubleshooting:

```
┌─────────────────┐     ┌──────────────┐     ┌─────────────┐
│ OpenClaw Cron    │────▶│ Agent Turn   │────▶│ Bash Tool   │
│ (1st of month)   │     │ (isolated)   │     │ audit-ctx.sh│
└─────────────────┘     └──────────────┘     └──────┬──────┘
                                                     │
                              ┌───────────────┐      │ stdout
                              │ Delivery      │◀─────┘
                              │ (announce)    │
                              └───────┬───────┘
                                      │
                              ┌───────▼───────┐
                              │ Telegram /    │
                              │ Slack / etc.  │
                              └───────────────┘
```

1. **Cron fires** on schedule (e.g., `0 10 1 * *` = 1st of month, 10am)
2. **Agent wakes** in an isolated session with the message prompt
3. **Agent runs** `bash audit-context.sh` via its Bash tool
4. **Script outputs** the formatted report to stdout
5. **Delivery** announces the agent's response to the configured channel

Token cost is minimal — the agent just runs one bash command and returns the output. No LLM reasoning required.

## Adjusting the Schedule

```bash
# Edit existing job
bash scripts/schedule-audit.sh --schedule "0 9 15 * *"  # 15th of month, 9am

# Or edit directly
openclaw cron edit JOB_ID --cron "0 9 15 * *"
```

## Changing the Delivery Target

```bash
# Via scheduler (updates existing job)
bash scripts/schedule-audit.sh --channel slack --to "channel:C1234567890"

# Or edit directly
openclaw cron edit JOB_ID --channel slack --to "channel:C1234567890" --announce
```

**Delivery target formats:**

| Platform | Format | Example |
|----------|--------|---------|
| Telegram group | Chat ID | `-1001234567890` |
| Telegram forum topic | `chatId:topic:topicId` | `-1001234567890:topic:123` |
| Slack channel | `channel:ID` | `channel:C1234567890` |
| Discord channel | `channel:ID` | `channel:987654321` |
| Webhook | URL | `https://example.com/hook` |

## Disabling / Removing

```bash
# Disable (keeps job, stops running)
openclaw cron disable JOB_ID

# Remove entirely
openclaw cron rm JOB_ID
```

## Troubleshooting

**Cron job exists but no report delivered:**
```bash
# Check run history
openclaw cron runs --id JOB_ID --limit 5

# Force a test run
openclaw cron run JOB_ID
```

**Script fails with "no workspaces configured":**
- Ensure `~/.config/context-audit/config.sh` exists and has `WORKSPACES=(...)` set
- Or pass workspaces via CLI: `--workspace ~/my-agent`

**Baseline shows stale data:**
- Delete and re-run: `rm ~/.openclaw/context-audit/baseline.json`
- First run after reset won't show growth deltas (no previous data)

**Gateway timeout during scheduling:**
```bash
systemctl --user restart openclaw-gateway
sleep 3
bash scripts/schedule-audit.sh  # retry
```
