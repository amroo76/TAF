#!/bin/bash

EXE="$1"
if [ -z "$EXE" ]; then
    echo "Usage: $0 <executable-name>"
    exit 1
fi

PID=$(pgrep -x "$EXE")
ts_human=$(date +"%Y-%m-%d %H:%M:%S")

if [ -z "$PID" ]; then
    echo "$ts_human pid: none (process not found)"
    exit 0
fi

read rss vsz <<< $(awk '{print $2" "$3}' /proc/$PID/statm)

rss_kb=$((rss*4))
vsz_kb=$((vsz*4))

rss_gb=$(awk -v kb="$rss_kb" 'BEGIN {printf "%.1f", kb/1048576}')
vsz_mb=$(awk -v kb="$vsz_kb" 'BEGIN {printf "%.1f", kb/1024}')

echo "$ts_human pid: $PID ($EXE) RSS: ${rss_kb} KB (~${rss_gb} GB) VSZ: ${vsz_kb} KB (~${vsz_mb} MB)"
