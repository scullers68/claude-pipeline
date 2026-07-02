# pipeline-core hooks

## Wired automatically (hooks.json)

Installed with the plugin; no configuration needed:

| Hook | Event | Purpose |
|---|---|---|
| `guard-sensitive-files.sh` | PreToolUse (Edit\|Write) | blocks edits to `.env`, `.git/`, credentials, lockfiles |
| `pre-commit-skill-validate.sh` | PreToolUse (Edit\|Write) | validates SKILL.md frontmatter against the schema before writes |
| `guard-deploy.sh` | PreToolUse (Bash) | blocks ad-hoc production deploy commands |
| `block-destructive-db-commands.sh` | PreToolUse (Bash) | blocks destructive DB/volume commands |
| `block-gh-issue-create.sh` | PreToolUse (Bash) | forces issue creation through the validated wrapper scripts |
| `format-on-edit.sh` | PostToolUse (Edit\|Write) | runs the project's `FORMAT_CMD` (from platform.sh) on edited files |
| `pipeline-status-inject.sh` | UserPromptSubmit | injects live pipeline status when a run is active |
| `session-start.sh` | SessionStart | session context bootstrap |

## Shipped, not wired — user-level opt-ins

Machine-level preferences don't belong in a project plugin's hook wiring;
they'd impose one user's tooling on every consumer. These ship as scripts you
can wire in your own `~/.claude/settings.json` if you use the tool:

**`rtk-rewrite.sh`** — rewrites verbose commands through
[RTK](https://github.com/rtk-ai/rtk) to cut token consumption. Safe to wire
unconditionally: it no-ops unless `RTK_ENABLED=1` AND an `rtk` binary is on
PATH (covered by tests). Note that `rtk init -g` can install its own
user-level hook, which supersedes this script — don't wire both.

```json
{ "hooks": { "PreToolUse": [ { "matcher": "Bash", "hooks": [
  { "type": "command", "command": "~/.claude/plugins/cache/<marketplace>/pipeline-core/hooks/scripts/rtk-rewrite.sh" }
] } ] } }
```

**Desktop notifications** — the pre-plugin tree wired a Linux-only
`notify-send` on Notification events. Dropped from the plugin entirely:
notification preferences are user-level and OS-specific. Wire your own
Notification hook (`notify-send`, `osascript`, `terminal-notifier`) in user
settings if wanted.
