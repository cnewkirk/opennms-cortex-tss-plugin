#!/usr/bin/env bash
#
# Post-upgrade validation for the Cortex TSS plugin.
# Runs continuous checks to verify the plugin is healthy after a KAR swap.
#
# Usage:
#   sudo ./validate.sh                          # single check
#   sudo ./validate.sh --watch 60               # check every 60s until Ctrl-C
#   sudo ./validate.sh --watch 60 --backend-metrics-url http://thanos:10902
#
set -uo pipefail

OPENNMS_HOME="${OPENNMS_HOME:-/opt/opennms}"
KARAF_PORT="${KARAF_PORT:-8101}"
KARAF_USER="${KARAF_USER:-admin}"
KARAF_PASS="${KARAF_PASS:-admin}"
BACKEND_METRICS_URL="${BACKEND_METRICS_URL:-}"
WATCH_INTERVAL=0
BASELINE_FILE="/tmp/cortex-tss-preflight-baseline.env"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --watch)                 WATCH_INTERVAL="$2"; shift 2 ;;
    --watch=*)               WATCH_INTERVAL="${1#*=}"; shift ;;
    --backend-metrics-url)   BACKEND_METRICS_URL="$2"; shift 2 ;;
    --backend-metrics-url=*) BACKEND_METRICS_URL="${1#*=}"; shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# Load baseline if available
BASELINE_OOO=""
if [ -f "$BASELINE_FILE" ]; then
  # shellcheck source=/dev/null
  source "$BASELINE_FILE"
  BASELINE_OOO="${BASELINE_OOO:-}"
fi

karaf_cmd() {
  sshpass -p "$KARAF_PASS" ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR \
    -p "$KARAF_PORT" "$KARAF_USER@localhost" "$1" 2>/dev/null
}

run_checks() {
  local PASS=0 FAIL=0 WARN=0
  local NOW
  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  echo "=== Validation Check — $NOW ==="

  # 1. Health check
  HEALTH=$(karaf_cmd "opennms:health-check" || echo "UNREACHABLE")
  if echo "$HEALTH" | grep -q "Everything is awesome"; then
    echo "  [OK]   Health check: Everything is awesome"
    ((PASS++))
  else
    echo "  [FAIL] Health check: $HEALTH"
    ((FAIL++))
  fi

  # 2. Plugin feature started
  FEATURE=$(karaf_cmd "feature:list | grep cortex-tss" || echo "")
  if echo "$FEATURE" | grep -qi "started"; then
    echo "  [OK]   Plugin feature: Started"
    ((PASS++))
  else
    echo "  [FAIL] Plugin feature: not started"
    ((FAIL++))
  fi

  # 3. Plugin stats
  STATS=$(karaf_cmd "opennms-cortex-tss:stats" 2>/dev/null || echo "")
  if [ -n "$STATS" ]; then
    WRITTEN_RATE=$(echo "$STATS" | grep -i "samplesWritten" | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "0")
    LOST_RATE=$(echo "$STATS" | grep -i "samplesLost" | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "0")

    if [ "$(echo "$WRITTEN_RATE > 0" | bc 2>/dev/null || echo 0)" = "1" ]; then
      echo "  [OK]   Samples written rate: $WRITTEN_RATE/s"
      ((PASS++))
    else
      echo "  [WARN] Samples written rate: $WRITTEN_RATE/s (may still be warming up)"
      ((WARN++))
    fi

    if [ "$LOST_RATE" = "0" ] || [ "$LOST_RATE" = "0.0" ] || [ "$(echo "$LOST_RATE == 0" | bc 2>/dev/null || echo 0)" = "1" ]; then
      echo "  [OK]   Samples lost rate: $LOST_RATE/s"
      ((PASS++))
    else
      echo "  [FAIL] Samples lost rate: $LOST_RATE/s"
      ((FAIL++))
    fi
  else
    echo "  [WARN] Plugin stats unavailable (opennms-cortex-tss:stats)"
    ((WARN++))
    ((WARN++))
  fi

  # 4. Ring buffer depth
  RB_INFO=$(karaf_cmd "opennms:metrics-display" 2>/dev/null | grep -A1 "ring-buffer.size" || echo "")
  if [ -n "$RB_INFO" ]; then
    RB_CURRENT=$(echo "$RB_INFO" | grep -oE 'value=[0-9]+' | grep -oE '[0-9]+' | head -1 || echo "0")
    RB_MAX=$(karaf_cmd "opennms:metrics-display" 2>/dev/null | grep -A1 "ring-buffer.max-size" | grep -oE 'value=[0-9]+' | grep -oE '[0-9]+' | head -1 || echo "1")
    if [ "$RB_MAX" -gt 0 ]; then
      RB_PCT=$((RB_CURRENT * 100 / RB_MAX))
      if [ "$RB_PCT" -lt 50 ]; then
        echo "  [OK]   Ring buffer: $RB_CURRENT/$RB_MAX ($RB_PCT%)"
        ((PASS++))
      elif [ "$RB_PCT" -lt 90 ]; then
        echo "  [WARN] Ring buffer: $RB_CURRENT/$RB_MAX ($RB_PCT%) — elevated"
        ((WARN++))
      else
        echo "  [FAIL] Ring buffer: $RB_CURRENT/$RB_MAX ($RB_PCT%) — near capacity"
        ((FAIL++))
      fi
    fi
  else
    echo "  [WARN] Ring buffer metrics unavailable"
    ((WARN++))
  fi

  # 5. Backend OOO counter
  if [ -n "$BACKEND_METRICS_URL" ]; then
    CURRENT_OOO=$(curl -sf "$BACKEND_METRICS_URL/metrics" 2>/dev/null \
      | grep 'prometheus_tsdb_out_of_order_samples_total' \
      | grep 'type="float"' \
      | awk '{print $2}' || echo "UNAVAILABLE")

    if [ "$CURRENT_OOO" = "UNAVAILABLE" ]; then
      echo "  [WARN] Backend OOO counter: unavailable"
      ((WARN++))
    elif [ -n "$BASELINE_OOO" ] && [ "$BASELINE_OOO" != "N/A" ]; then
      NEW_OOO=$(echo "$CURRENT_OOO - $BASELINE_OOO" | bc 2>/dev/null || echo "?")
      if [ "$NEW_OOO" = "0" ] || [ "$(echo "$NEW_OOO == 0" | bc 2>/dev/null || echo 0)" = "1" ]; then
        echo "  [OK]   Backend OOO: $CURRENT_OOO (0 new since baseline $BASELINE_OOO)"
        ((PASS++))
      else
        echo "  [FAIL] Backend OOO: $CURRENT_OOO (+$NEW_OOO since baseline $BASELINE_OOO)"
        ((FAIL++))
      fi
    else
      echo "  [INFO] Backend OOO: $CURRENT_OOO (no baseline to compare)"
    fi
  fi

  echo ""
  echo "  Result: $PASS ok, $FAIL failed, $WARN warnings"

  if [ "$FAIL" -gt 0 ]; then
    echo "  >>> VALIDATION FAILED — consider running roll-back.sh <<<"
    echo ""
    return 1
  fi
  echo ""
  return 0
}

# ── Main ──────────────────────────────────────────────────────────
if [ "$WATCH_INTERVAL" -gt 0 ]; then
  echo "Watching every ${WATCH_INTERVAL}s (Ctrl-C to stop)"
  echo ""
  ITERATION=0
  while true; do
    ((ITERATION++))
    if ! run_checks; then
      echo "Stopping watch due to failure on iteration $ITERATION."
      exit 1
    fi
    sleep "$WATCH_INTERVAL"
  done
else
  run_checks
  exit $?
fi
