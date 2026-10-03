#!/bin/bash
# Weekly unattended maintenance: installs OS updates, updates every
# container, checks they all came back up, cleans up, and reboots if an
# update needs it. Waits for a running SnapRAID sync to finish first.
#
# Reports to a healthchecks.io check: success is silent, a failure alerts
# with the end of this log, and a run that never happens alerts too.
# Runs as root from cron (see README).
#
# Other projects on this machine can join the weekly run without this repo
# knowing about them: put an executable (or a symlink to one) in HOOK_DIR.
# Hooks run as root in name order, after this repo's containers are updated
# and before any reboot. A failing hook is reported, but doesn't stop the
# remaining hooks, the cleanup or the reboot.

set -u
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

REPO=/home/steve/server
LOG=$REPO/logs/maintenance-$(date +%Y%m%d-%H%M%S).log
HC_URL=$(cat /host/healthchecks_maintenance_url.txt 2>/dev/null)
SNAPRAID_WAIT_MAX=$((4 * 3600))   # give up on this week's run after waiting this long
SETTLE=180                        # seconds to let containers start before checking them
LOG_DAYS=60                       # delete maintenance/snapraid logs older than this
HOOK_DIR=/etc/weekly-maintenance.d
HOOK_TIMEOUT=30m                  # per hook

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"
}

# hc <suffix> [body]: ping healthchecks.io ("" = success, /start, /fail).
# Never lets a healthchecks.io outage fail the run itself.
hc() {
  [[ -n "$HC_URL" ]] || return 0
  curl -fsS -m 10 --retry 3 -o /dev/null --data-binary "${2:-}" "$HC_URL$1" || true
}

fail() {
  log "FAILED: $*"
  hc /fail "$(tail -c 10000 "$LOG")"
  exit 1
}

log "=== weekly maintenance starting ==="
[[ -n "$HC_URL" ]] || log "WARNING: /host/healthchecks_maintenance_url.txt missing, results won't be reported"
hc /start

# SnapRAID: never update or reboot underneath a running sync/scrub.
waited=0
while pgrep -x snapraid >/dev/null; do
  if (( waited >= SNAPRAID_WAIT_MAX )); then
    fail "SnapRAID still running after $((SNAPRAID_WAIT_MAX / 3600))h, skipped this week's maintenance"
  fi
  (( waited == 0 )) && log "SnapRAID is running, waiting for it to finish..."
  sleep 300
  (( waited += 300 ))
done

# OS updates. Keep existing config files on conflicts rather than prompting.
log "Installing OS updates..."
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
apt-get update >> "$LOG" 2>&1 || fail "apt-get update failed"
apt-get "${APT_OPTS[@]}" upgrade --with-new-pkgs >> "$LOG" 2>&1 || fail "apt-get upgrade failed"
apt-get "${APT_OPTS[@]}" autoremove --purge >> "$LOG" 2>&1 || log "autoremove failed (not fatal)"

# Containers: pull new images and recreate whatever changed.
cd "$REPO" || fail "cannot cd to $REPO"
log "Updating containers..."
docker compose pull --quiet >> "$LOG" 2>&1 || fail "docker compose pull failed"
docker compose up -d >> "$LOG" 2>&1 || fail "docker compose up failed"

log "Waiting ${SETTLE}s for containers to settle..."
sleep "$SETTLE"
bad=""
for svc in $(docker compose config --services); do
  state=$(docker compose ps -a --format '{{.State}}' "$svc" 2>/dev/null)
  health=$(docker compose ps -a --format '{{.Health}}' "$svc" 2>/dev/null)
  if [[ "$state" != "running" || "$health" == "unhealthy" ]]; then
    bad+=" $svc(${state:-missing}${health:+/$health})"
  fi
done
[[ -z "$bad" ]] || fail "containers not running after update:$bad"
log "All containers running."

hook_failures=""
for hook in "$HOOK_DIR"/*; do
  [[ -f "$hook" && -x "$hook" ]] || continue
  name=$(basename "$hook")
  log "Running hook $name..."
  if timeout "$HOOK_TIMEOUT" "$hook" >> "$LOG" 2>&1; then
    log "Hook $name finished."
  else
    log "Hook $name FAILED (exit $?)."
    hook_failures+=" $name"
  fi
done

# Cleanup. Old image versions aren't kept: to roll back an app, pin its
# previous version tag in docker-compose.yml and run docker compose up -d.
docker image prune -af >> "$LOG" 2>&1 || log "image prune failed (not fatal)"
find "$REPO/logs" -maxdepth 1 \( -name 'maintenance-*.log' -o -name 'snapraid-*.log' \) \
  -mtime +"$LOG_DAYS" -delete

# Report before any reboot: hook failures alert, everything else is silent.
reboot=false
[[ -f /var/run/reboot-required ]] && reboot=true
if [[ -n "$hook_failures" ]]; then
  log "=== weekly maintenance finished, but hooks failed:$hook_failures ==="
  hc /fail "$(tail -c 10000 "$LOG")"
else
  log "=== weekly maintenance finished$($reboot && echo ', rebooting for updates') ==="
  hc "" "$(tail -c 10000 "$LOG")"
fi
$reboot && systemctl reboot
[[ -z "$hook_failures" ]]
