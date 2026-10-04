#!/bin/bash
# Publishes each drive's SMART self-test results for Grafana. The
# smartctl-exporter doesn't read the self-test log, so this does, for the
# drives listed in /etc/smartd.conf. Runs hourly from root's crontab.
# Read-only: it never starts or stops a test.

set -u
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# node-exporter's textfile collector reads *.prom files from here (Grafana)
METRICS=/var/lib/node_exporter/smart_selftest.prom

# Status codes: -1 no test logged, 0 passed, 1 failed, 2 aborted/interrupted
# (no verdict), 3 in progress. ATA's status nibble and SCSI's result code
# share the same meaning for 0-2 and 15; 3-8 are the failure codes in both.
read -r -d '' JQ <<'EOF'
def status: if . == null then -1 elif . == 0 then 0 elif . <= 2 then 2
            elif . == 15 then 3 else 1 end;
def wrap: if . < 0 then . + 65536 else . end;

.power_on_time.hours as $poh |
( if .ata_smart_self_test_log then
    [.ata_smart_self_test_log.standard.table // [] | .[] |
     {long: (.type.value == 2), code: (.status.value / 16 | floor),
      age: (($poh - .lifetime_hours) % 65536 | wrap)}]
  else
    [to_entries[] | select(.key | test("^scsi_self_test_[0-9]+$")) |
     .value | {long: (.code.value == 2 or .code.value == 6),
               code: .result.value, age: ($poh - .power_on_time.hours)}]
  end ) as $log |
( if .ata_smart_data.self_test then
    (.ata_smart_data.self_test.status.value / 16 | floor) == 15
  else
    any($log[]; .code == 15)
  end ) as $running |
($log | map(select(.long))  | first) as $long |
($log | map(select(.long | not)) | first) as $short |
"smart_selftest_last_long_status{device=\"\($dev)\"} \($long.code | status)",
"smart_selftest_last_short_status{device=\"\($dev)\"} \($short.code | status)",
(if $long  then "smart_selftest_last_long_age_seconds{device=\"\($dev)\"} \($long.age * 3600)"  else empty end),
(if $short then "smart_selftest_last_short_age_seconds{device=\"\($dev)\"} \($short.age * 3600)" else empty end),
"smart_selftest_failed{device=\"\($dev)\"} \($log | map(select(.code | status == 1)) | length)",
"smart_selftest_running{device=\"\($dev)\"} \(if $running then 1 else 0 end)"
EOF

{
  cat <<'EOM'
# HELP smart_selftest_last_long_status Last long test: -1 none, 0 passed, 1 failed, 2 aborted, 3 in progress.
# TYPE smart_selftest_last_long_status gauge
# HELP smart_selftest_last_short_status Last short test: -1 none, 0 passed, 1 failed, 2 aborted, 3 in progress.
# TYPE smart_selftest_last_short_status gauge
# HELP smart_selftest_last_long_age_seconds Power-on time since the last long test.
# TYPE smart_selftest_last_long_age_seconds gauge
# HELP smart_selftest_last_short_age_seconds Power-on time since the last short test.
# TYPE smart_selftest_last_short_age_seconds gauge
# HELP smart_selftest_failed Failed tests in the drive's self-test log (it keeps the last ~20).
# TYPE smart_selftest_failed gauge
# HELP smart_selftest_running 1 while a self-test is running.
# TYPE smart_selftest_running gauge
EOM
  for path in $(awk '/^\/dev\//{print $1}' /etc/smartd.conf); do
    dev=$(basename "$(readlink -f "$path")")
    smartctl -j -A -c -l selftest "$path" | jq -r --arg dev "$dev" "$JQ"
  done
} > "$METRICS.tmp"
mv "$METRICS.tmp" "$METRICS"
