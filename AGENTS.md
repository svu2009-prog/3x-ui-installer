# 3x-ui-installer

Idempotent Bash installer for the 3X-UI panel on Ubuntu/Debian.

## Architecture

```
install.sh                 # Entry point
uninstall.sh               # Clean removal
lib/
  common.sh                # strict mode, colors, logging, traps, backup, helpers
  checks.sh                # idempotency checks (packages, services, certs, inbounds)
  firewall.sh              # UFW — adds rules idempotently
  nginx.sh                 # Nginx config + Certbot SSL (backups before changes)
  panel.sh                 # 3X-UI download/install/update
  xray.sh                  # Xray key generation + SQLite inbound upsert
config.conf → /etc/3x-ui-installer/config.conf   # Persisted settings
```

## Idempotency Strategy

| Component | Check | Re-run behavior |
|-----------|-------|----------------|
| System packages | `dpkg -s` | Skips installed packages |
| 3X-UI panel | `systemctl is-active` + binary exists | Skip if running |
| SSL cert | `certbot certificates \| grep DOMAIN` | Skip or renew (<30d) |
| Inbounds | `SELECT COUNT(*) FROM inbounds WHERE tag='...'` | UPDATE existing, no duplicates |
| UFW rules | `ufw status numbered \| grep PORT` | Add only missing rules |
| Nginx config | diff with template | Backup → overwrite → `nginx -t` |

## Error Handling

- ERR trap: logs error + command + line, restores backups, exits
- EXIT trap: logs success/failure
- INT/TERM trap: graceful stop

## Logging

- File: `/var/log/3x-ui-installer/install.log`
- Format: `[2026-07-04 12:00:00] [LEVEL] message`
- Levels: INFO, OK, WARN, ERROR, DEBUG

## Testing

The script is designed for Ubuntu 20.04+/Debian 11+. Test by running:

```bash
sudo bash install.sh
```

To verify idempotency, run it twice — the second run should produce no errors and skip all completed steps.

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **3x-ui-installer** (41 symbols, 34 relationships, 0 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> Index stale? Run `node .gitnexus/run.cjs analyze` from the project root — it auto-selects an available runner. No `.gitnexus/run.cjs` yet? `npx gitnexus analyze` (npm 11 crash → `npm i -g gitnexus`; #1939).

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows. For regression review, compare against the default branch: `detect_changes({scope: "compare", base_ref: "main"})`.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `query({search_query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `context({name: "symbolName"})`.
- For security review, `explain({target: "fileOrSymbol"})` lists taint findings (source→sink flows; needs `analyze --pdg`).

## Never Do

- NEVER edit a function, class, or method without first running `impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `rename` which understands the call graph.
- NEVER commit changes without running `detect_changes()` to check affected scope.

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/3x-ui-installer/context` | Codebase overview, check index freshness |
| `gitnexus://repo/3x-ui-installer/clusters` | All functional areas |
| `gitnexus://repo/3x-ui-installer/processes` | All execution flows |
| `gitnexus://repo/3x-ui-installer/process/{name}` | Step-by-step execution trace |

## CLI

| Task | Read this skill file |
|------|---------------------|
| Understand architecture / "How does X work?" | `.claude/skills/gitnexus/gitnexus-exploring/SKILL.md` |
| Blast radius / "What breaks if I change X?" | `.claude/skills/gitnexus/gitnexus-impact-analysis/SKILL.md` |
| Trace bugs / "Why is X failing?" | `.claude/skills/gitnexus/gitnexus-debugging/SKILL.md` |
| Rename / extract / split / refactor | `.claude/skills/gitnexus/gitnexus-refactoring/SKILL.md` |
| Tools, resources, schema reference | `.claude/skills/gitnexus/gitnexus-guide/SKILL.md` |
| Index, status, clean, wiki CLI commands | `.claude/skills/gitnexus/gitnexus-cli/SKILL.md` |

<!-- gitnexus:end -->
