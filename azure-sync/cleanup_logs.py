#!/usr/bin/env python3
"""
Tiered retention cleanup for azure-freeipa-sync logs and backups.

Retention policy (applied to both):
  last 24 hours    -> keep everything
  1 day  - 1 week  -> keep one entry per calendar day
  1 week - 3 months-> keep one entry per calendar week
  older than 3 months -> delete
"""

import configparser
import re
import shutil
import sys
from datetime import datetime, timedelta
from pathlib import Path
from collections import defaultdict

CONFIG_FILE = "/opt/azure-freeipa-sync/azure_sync.conf"
LOG_DIR     = Path("/var/log")
LOG_RE      = re.compile(r'^azure-freeipa-sync\.log-(\d{10})(\.gz)?$')
BACKUP_RE   = re.compile(r'^ipa_backup_(\d{8}_\d{6})$')

NOW           = datetime.now()
HOURLY_CUTOFF = NOW - timedelta(hours=24)
DAILY_CUTOFF  = NOW - timedelta(days=7)
WEEKLY_CUTOFF = NOW - timedelta(weeks=13)


def _read_backup_dir():
    cfg = configparser.ConfigParser()
    cfg.read(CONFIG_FILE)
    return Path(cfg.get('sync', 'backup_directory',
                        fallback='/var/backups/freeipa-sync').strip('"'))


def _tier(items):
    """Return the subset of (ts, path) pairs that should be deleted."""
    daily   = defaultdict(list)
    weekly  = defaultdict(list)
    deletions = []

    for ts, path in items:
        if ts >= HOURLY_CUTOFF:
            pass
        elif ts >= DAILY_CUTOFF:
            daily[ts.date()].append((ts, path))
        elif ts >= WEEKLY_CUTOFF:
            iso = ts.isocalendar()
            weekly[(iso[0], iso[1])].append((ts, path))
        else:
            deletions.append(path)

    for entries in daily.values():
        entries.sort(key=lambda x: x[0], reverse=True)
        deletions.extend(p for _, p in entries[1:])

    for entries in weekly.values():
        entries.sort(key=lambda x: x[0], reverse=True)
        deletions.extend(p for _, p in entries[1:])

    return deletions


def collect_logs():
    items = []
    for p in LOG_DIR.iterdir():
        m = LOG_RE.match(p.name)
        if m:
            try:
                items.append((datetime.strptime(m.group(1), '%Y%m%d%H'), p))
            except ValueError:
                pass
    return items


def collect_backups(backup_dir):
    items = []
    if not backup_dir.is_dir():
        return items
    for p in backup_dir.iterdir():
        m = BACKUP_RE.match(p.name)
        if m and p.is_dir():
            try:
                items.append((datetime.strptime(m.group(1), '%Y%m%d_%H%M%S'), p))
            except ValueError:
                pass
    return items


def purge(paths, label):
    if not paths:
        return 0
    errors = 0
    for path in sorted(paths):
        try:
            if path.is_dir():
                shutil.rmtree(path)
            else:
                path.unlink()
            print(f"  Deleted {label}: {path.name}")
        except Exception as e:
            print(f"  ERROR deleting {path}: {e}", file=sys.stderr)
            errors += 1
    return errors


def main():
    total_errors = 0

    # --- Logs ---
    logs = collect_logs()
    log_deletions = _tier(logs)
    print(f"Logs: {len(logs)} rotated file(s) found, {len(log_deletions)} to remove.")
    total_errors += purge(log_deletions, "log")

    # --- Backups ---
    backup_dir = _read_backup_dir()
    backups = collect_backups(backup_dir)
    backup_deletions = _tier(backups)
    print(f"Backups: {len(backups)} backup(s) found in {backup_dir}, {len(backup_deletions)} to remove.")
    total_errors += purge(backup_deletions, "backup")

    return 1 if total_errors else 0


if __name__ == "__main__":
    sys.exit(main())
