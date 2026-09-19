#!/bin/bash
# Polls a local ldmsd's meminfo set once per second and writes the
# output to a time-stamped log file. Used to build the before/during/
# after memory time-series for the VPIC memory-bound tests.

OUT=~/meminfo_timeseries.txt
> "$OUT"
while true; do
  echo "=== $(date +%s) ===" >> "$OUT"
  ldms_ls -x sock -p 10444 -h localhost -l -v localhost/meminfo >> "$OUT" 2>&1
  sleep 1
done
