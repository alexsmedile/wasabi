#!/usr/bin/env bash
# Measure Wasabi's real memory footprint — the headline PRD benchmark.
#
# Reports phys_footprint (Apple's true per-process dirty-memory cost, the number
# Activity Monitor's "Memory" column shows) for the Wasabi UI process plus every
# WebKit helper (WebContent / GPU / Networking) it spawns. RSS is deliberately
# NOT used — it double-counts shared framework pages and overstates the cost.
#
# Usage:
#   scripts/measure-ram.sh            # one snapshot
#   scripts/measure-ram.sh -n 20 -i 3 # 20 samples, 3s apart (a soak)
#
# Attribution: WebKit XPC helpers reparent to launchd (ppid 1), but WebKit names
# each one after its responsible app — `lsappinfo info -only name <pid>` returns
# e.g. "Wasabi Web Content" / "Wasabi GPU" / "Wasabi Networking". We count only
# helpers whose lsappinfo name contains "Wasabi", so Safari/Mail/other WebKit apps
# are correctly excluded. No sudo required.
set -euo pipefail

SAMPLES=1
INTERVAL=2
while getopts "n:i:h" opt; do
  case $opt in
    n) SAMPLES="$OPTARG" ;;
    i) INTERVAL="$OPTARG" ;;
    h) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "usage: $0 [-n samples] [-i interval_seconds]" >&2; exit 1 ;;
  esac
done

is_ours() { # true if this WebKit helper pid is responsible to Wasabi
  lsappinfo info -only name "$1" 2>/dev/null | grep -q "Wasabi"
}

fp() { # phys_footprint in MB (integer) for a pid, 0 if gone. Normalizes KB/MB/GB.
  footprint -p "$1" 2>/dev/null | awk '
    /phys_footprint:/{
      v=$2; u=$3
      if (u=="KB") v=v/1024
      else if (u=="GB") v=v*1024
      printf "%d", v+0.5; exit
    }' || echo 0
}

snapshot() {
  local ui_pid total=0 wc_count=0 line role mb
  ui_pid="$(pgrep -f "Wasabi.app/Contents/MacOS/Wasabi" | head -1 || true)"
  if [ -z "$ui_pid" ]; then
    echo "Wasabi is not running — launch build/Wasabi.app first." >&2
    return 1
  fi

  local web_pids
  web_pids="$(pgrep -f "com.apple.WebKit.(WebContent|GPU|Networking)" || true)"

  printf '%-22s %6s\n' "process" "MB"
  printf '%-22s %6s\n' "----------------------" "------"

  mb="$(fp "$ui_pid")"; total=$((total + mb))
  printf '%-22s %6d\n' "Wasabi (UI)" "$mb"

  for pid in $web_pids; do
    is_ours "$pid" || continue
    role="$(ps -p "$pid" -o command= 2>/dev/null | grep -oE 'WebContent|GPU|Networking' | head -1)"
    [ -z "$role" ] && continue
    mb="$(fp "$pid")"; total=$((total + mb))
    [ "$role" = "WebContent" ] && wc_count=$((wc_count + 1))
    printf '%-22s %6d   (pid %s)\n' "WebKit $role" "$mb" "$pid"
  done

  printf '%-22s %6s\n' "----------------------" "------"
  printf '%-22s %6d MB   (%d live service%s)\n' "TOTAL" "$total" "$wc_count" "$([ "$wc_count" = 1 ] && echo '' || echo s)"
}

# total_only: just the summed MB (for soak rows), no table
total_only() {
  local ui_pid total=0 mb pid role
  ui_pid="$(pgrep -f "Wasabi.app/Contents/MacOS/Wasabi" | head -1 || true)"
  [ -z "$ui_pid" ] && { echo "n/a"; return; }
  mb="$(fp "$ui_pid")"; total=$((total + mb))
  for pid in $(pgrep -f "com.apple.WebKit.(WebContent|GPU|Networking)" || true); do
    is_ours "$pid" || continue
    mb="$(fp "$pid")"; total=$((total + mb))
  done
  echo "$total"
}

if [ "$SAMPLES" -le 1 ]; then
  snapshot
else
  echo "Soak: $SAMPLES samples, ${INTERVAL}s apart"
  echo "sample  total_MB"
  for i in $(seq 1 "$SAMPLES"); do
    printf '%-7d %s\n' "$i" "$(total_only)"
    [ "$i" -lt "$SAMPLES" ] && sleep "$INTERVAL"
  done
fi
