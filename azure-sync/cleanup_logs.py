#!/usr/bin/env python3
"""
Tiered log retention for azure-freeipa-sync.

Retention policy:
  last 24 hours    -> keep all rotated files (hourly granularity)
  1 day  - 1 week  -> keep one file per calendar day
  1 week - 3 months-> keep one file per calendar week
  older than 3 months -> delete
"""

import re
import sys
from datetime import datetime, timedelta
from pathlib import Path
from collections import defaultdict

LOG_DIR = Path("/var/log")
LOG_RE = re.compile(r'^azure-freeipa-sync\.log-(\d{10})(\.gz)?$')

NOW = datetime.now()
HOURLY_CUTOFF = NOW - timedelta(hours=24)
DAILY_CUTOFF  = NOW - timedelta(days=7)
WEEKLY_CUTOFF = NOW - timedelta(weeks=13)


def collect_rotated_files():
    result = {}
    for p in LOG_DIR.iterdir():
        m = LOG_RE.match(p.name)
        if m:
            try:
                result[p] = datetime.strptime(m.group(1), '%Y%m%d%H')
            except ValueError:
                pass
    return result


def files_to_delete(files):
    daily   = defaultdict(list)
    weekly  = defaultdict(list)
    deletions = []

    for path, ts in files.items():
        if ts >= HOURLY_CUTOFF:
            pass  # keep all hourly snapshots from the last 24 h
        elif ts >= DAILY_CUTOFF:
            daily[ts.date()].append((ts, path))
        elif ts >= WEEKLY_CUTOFF:
            iso = ts.isocalendar()
            weekly[(iso[0], iso[1])].append((ts, path))
        else:
            deletions.append(path)

    # Within each day/week bucket keep the newest copy, delete the rest
    for entries in daily.values():
        entries.sort(key=lambda x: x[0], reverse=True)
        deletions.extend(p for _, p in entries[1:])

    for entries in weekly.values():
        entries.sort(key=lambda x: x[0], reverse=True)
        deletions.extend(p for _, p in entries[1:])

    return deletions


def main():
    files = collect_rotated_files()
    if not files:
        print("No rotated log files found.")
        return 0

    deletions = files_to_delete(files)
    if not deletions:
        print(f"Checked {len(files)} rotated log file(s) — nothing to clean up.")
        return 0

    errors = 0
    for path in sorted(deletions):
        try:
            path.unlink()
            print(f"Deleted: {path}")
        except Exception as e:
            print(f"ERROR deleting {path}: {e}", file=sys.stderr)
            errors += 1

    print(f"Cleaned up {len(deletions) - errors}/{len(deletions)} file(s).")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
