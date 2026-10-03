#!/bin/bash
# Nightly SnapRAID maintenance: sync parity against whatever changed in
# data/, with a safety check that refuses to sync (and thus lock in) a
# mass-deletion before a human has looked at it. Runs a scrub pass on
# Sundays to catch silent bit-rot. Does NOT touch the docker stack -
# snapraid only reads the data disks and writes parity/content files.

set -u
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

LOG=/home/steve/server/logs/snapraid-$(date +%Y%m%d-%H%M%S).log
MAX_REMOVED=50   # abort the sync if more files than this vanished since last run
# node-exporter's textfile collector reads *.prom files from here (Grafana)
METRICS=/var/lib/node_exporter/snapraid.prom

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"
}

# write_metrics <aborted 0|1> <sync exit code, -1 if not run>
# Written to a temp file then renamed so node-exporter never reads a
# half-written file. The last-success timestamp carries over from the
# previous file unless this run's sync succeeded.
write_metrics() {
  local aborted=$1 sync_rc=$2 now last_ok
  now=$(date +%s)
  last_ok=$(awk '/^snapraid_last_sync_success_timestamp_seconds /{print $2}' "$METRICS" 2>/dev/null)
  [[ "$sync_rc" -eq 0 ]] && last_ok=$now
  mkdir -p "$(dirname "$METRICS")"
  cat > "$METRICS.tmp" <<EOM
# HELP snapraid_last_run_timestamp_seconds When the nightly script last ran.
# TYPE snapraid_last_run_timestamp_seconds gauge
snapraid_last_run_timestamp_seconds $now
# HELP snapraid_last_sync_success_timestamp_seconds When a sync last completed successfully.
# TYPE snapraid_last_sync_success_timestamp_seconds gauge
snapraid_last_sync_success_timestamp_seconds ${last_ok:-0}
# HELP snapraid_sync_exit_code Exit code of the last sync (-1 = not run).
# TYPE snapraid_sync_exit_code gauge
snapraid_sync_exit_code $sync_rc
# HELP snapraid_sync_aborted 1 if the last run refused to sync (mass deletion).
# TYPE snapraid_sync_aborted gauge
snapraid_sync_aborted $aborted
# HELP snapraid_files_removed Files removed since the previous sync, per snapraid diff.
# TYPE snapraid_files_removed gauge
snapraid_files_removed $REMOVED
EOM
  mv "$METRICS.tmp" "$METRICS"
}

log "=== snapraid nightly run starting ==="

DIFF_OUT=$(snapraid diff 2>&1)
echo "$DIFF_OUT" >> "$LOG"

REMOVED=$(echo "$DIFF_OUT" | grep -oE '^[0-9]+ removed' | awk '{print $1}')
REMOVED=${REMOVED:-0}
log "Files removed since last sync: $REMOVED"

if [[ "$REMOVED" -gt "$MAX_REMOVED" ]]; then
  log "ABORTING SYNC: $REMOVED files removed exceeds safety threshold of $MAX_REMOVED."
  log "This usually means a disk dropped out, a mount failed, or something got"
  log "deleted by mistake. Run 'snapraid status' and check manually before"
  log "running 'snapraid sync' by hand - syncing now would make the loss permanent."
  log "=== snapraid nightly run ABORTED (no sync performed) ==="
  write_metrics 1 -1
  exit 1
fi

log "Running snapraid sync..."
snapraid sync >> "$LOG" 2>&1
SYNC_RC=$?
log "sync exited with code $SYNC_RC"
write_metrics 0 "$SYNC_RC"

# Sunday: also scrub ~8% of the array (oldest-synced blocks first,
# skipping anything touched in the last 10 days) to catch bit-rot.
if [[ "$(date +%u)" -eq 7 ]]; then
  log "Sunday - running scrub..."
  snapraid scrub -p 8 -o 10 >> "$LOG" 2>&1
  log "scrub exited with code $?"
fi

log "=== snapraid nightly run finished ==="
