# context-audit

Monthly audit for OpenClaw agent workspace context files. Detects token bloat, month-over-month growth drift, and cross-workspace paragraph duplication. Pure bash + jq — zero LLM tokens for the audit itself.

## Why

Agent workspace files (MEMORY.md, AGENTS.md, TOOLS.md, etc.) silently bloat over time. A 2,000-token MEMORY.md becomes 9,800 tokens. Duplicate sections accumulate across workspaces. Nobody notices until context windows get tight and agent quality degrades.

This skill runs monthly, posts a report, and lets a human decide what to trim. It never edits files automatically.

## What It Checks

| Check | Method | Default Threshold |
|-------|--------|-------------------|
| Token count per file | `bytes / 4` (~85-90% accurate) | Per-file, configurable |
| Month-over-month growth | Compare to stored baseline JSON | Warn if any file grew >30% |
| Cross-workspace duplication | MD5 hash of normalized paragraph blocks | Any duplicate paragraph >50 words |
| Memory directory accumulation | Count files in `memory/` dir | Warn if >50 files |

Only OpenClaw bootstrap-injected files are scanned by default: `AGENTS.md`, `SOUL.md`, `TOOLS.md`, `IDENTITY.md`, `USER.md`, `HEARTBEAT.md`, `BOOTSTRAP.md`, `MEMORY.md`. Use `--all-root-md` for exploratory scans.

## Quick Start

```bash
# 1. Copy and customize config
mkdir -p ~/.config/context-audit
cp config.example.sh ~/.config/context-audit/config.sh
# Edit config.sh: set WORKSPACES array, notification target, etc.

# 2. Test with a dry run
bash scripts/audit-context.sh --dry-run

# 3. Schedule the monthly cron job
bash scripts/schedule-audit.sh --channel telegram --to "-YOUR_CHAT_ID"

# 4. (Optional) Sync into workspaces if using skills framework
bash ~/projects/skills/sync-skills.sh
```

See [references/setup.md](references/setup.md) for detailed setup instructions.

## Sample Report

```
🔍 Context Audit — Mar 1, 2026
━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🔴 CRITICAL (1)
• workspace-a/AGENTS.md: ~8240 tokens (critical limit: 6000)
  ↑ grew 800 tokens (+17%) since last audit

⚠️ WARNINGS (2)
• workspace-b/MEMORY.md: ~2915 tokens (warn limit: 2000)
• workspace-c/memory/: 72 files (suggest archival)

🔄 DUPLICATES (1)
• "Keep PRs small and single-purpose; avoid bundling unrelate..." (~222 tokens)
  Found in: workspace-a/BOOTSTRAP.md, workspace-b/BOOTSTRAP.md

✅ HEALTHY (41 files across 6 workspaces)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Total context: ~46,500 tokens across 6 workspaces
```

If everything is clean, you get a one-liner instead:

```
✅ Context Audit — Mar 1, 2026: All clear. ~24,500 tokens across 6 workspaces.
```

## Scripts

### `scripts/audit-context.sh`

The audit logic. Scans workspaces, compares baselines, finds duplicates, outputs report.

```bash
# Default: bootstrap files only
bash scripts/audit-context.sh --dry-run

# Scan everything at workspace root
bash scripts/audit-context.sh --dry-run --all-root-md

# Override workspaces via CLI
bash scripts/audit-context.sh --workspace ~/agent-a --workspace ~/agent-b

# Custom config
bash scripts/audit-context.sh --config /path/to/config.sh
```

### `scripts/schedule-audit.sh`

Creates (or updates) an OpenClaw cron job. Idempotent — safe to run repeatedly.

```bash
# Default: 1st of month, 10am PT, deliver to Telegram
bash scripts/schedule-audit.sh --channel telegram --to "-YOUR_CHAT_ID"

# Custom schedule
bash scripts/schedule-audit.sh --schedule "0 9 1 * *" --tz "Europe/London"

# Bind to a specific agent
bash scripts/schedule-audit.sh --agent niemand-code
```

## Configuration

Copy `config.example.sh` to `~/.config/context-audit/config.sh`. Key settings:

| Setting | Default | Description |
|---------|---------|-------------|
| `WORKSPACES` | (none) | Array of workspace paths to scan |
| `THRESHOLDS` | Per-file | Associative array: `[FILENAME]="warn:critical"` |
| `CONTEXT_FILES` | Bootstrap set | Which .md files to audit |
| `MEMORY_FILE_WARN` | 50 | Max files in memory/ before warning |
| `DUP_MIN_WORDS` | 50 | Minimum paragraph size for duplicate detection |
| `GROWTH_WARN_PERCENT` | 30 | Month-over-month growth threshold |
| `NOTIFY_CHANNEL` | (empty) | Delivery channel for `openclaw message send` |
| `NOTIFY_TARGET` | (empty) | Delivery target (chat ID, etc.) |

## Dependencies

- **bash** (4.0+ for associative arrays)
- **jq** (baseline JSON processing)
- **md5sum**, **awk** (duplicate detection)
- **openclaw CLI** (optional — for notifications and cron scheduling)

## How It Works

1. For each workspace, iterates the bootstrap file set (or all `*.md` with `--all-root-md`)
2. Estimates tokens as `ceil(bytes / 4)` — no external tokenizer needed
3. Compares against stored baseline at `~/.openclaw/context-audit/baseline.json`
4. Extracts paragraphs (blank-line separated blocks), normalizes, MD5 hashes
5. Flags paragraphs appearing in 2+ workspace/file locations
6. Builds report, saves new baseline, optionally posts notification

Baseline is preserved across partial scans — if a workspace is temporarily unavailable, its history is retained.

## License

MIT
