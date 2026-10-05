#!/bin/bash
# Dumps full SMART data for each active drive to a world-readable file.
OUT=/home/steve/server/logs/disk-health.txt
: > "$OUT"
for d in sdb sdc sdd sde sdf; do
  echo "=== /dev/$d ===" >> "$OUT"
  smartctl -a /dev/$d >> "$OUT" 2>&1
  echo >> "$OUT"
done
chmod 644 "$OUT"
