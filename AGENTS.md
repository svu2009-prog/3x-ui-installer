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
