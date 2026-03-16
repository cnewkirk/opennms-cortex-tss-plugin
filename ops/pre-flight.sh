#!/usr/bin/env bash
#
# Pre-flight checks before upgrading the Cortex TSS plugin KAR.
# Run on each OpenNMS instance before starting the upgrade.
#
# Usage: sudo ./pre-flight.sh [--backend-metrics-url URL]
#
set -euo pipefail

OPENNMS_HOME="${OPENNMS_HOME:-/opt/opennms}"
DEPLOY_DIR="$OPENNMS_HOME/deploy"
KARAF_PORT="${KARAF_PORT:-8101}"
KARAF_USER="${KARAF_USER:-admin}"
KARAF_PASS="${KARAF_PASS:-admin}"
BACKEND_METRICS_URL="${BACKEND_METRICS_URL:-}"
BASELINE_FILE="/tmp/cortex-tss-preflight-baseline.env"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backend-metrics-url)   BACKEND_METRICS_URL="$2"; shift 2 ;;
    --backend-metrics-url=*) BACKEND_METRICS_URL="${1#*=}"; shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

PASS=0
FAIL=0
check() {
  local label="$1" result="$2"
  if [ "$result" = "ok" ]; then
    echo "  [OK]   $label"
    ((PASS++))
  else
    echo "  [FAIL] $label — $result"
    ((FAIL++))
  fi
}

echo "=== Cortex TSS Plugin Pre-Flight Check ==="
echo "  Host:        $(hostname)"
echo "  Date:        $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "  OPENNMS_HOME: $OPENNMS_HOME"
echo ""

# ── 1. Current KAR ──────────────────────────────────────────────────
echo "--- Current KAR ---"
KAR_FILE=$(find "$DEPLOY_DIR" -name '*cortex*tss*.kar' -o -name '*cortex*.kar' 2>/dev/null | head -1)
if [ -n "$KAR_FILE" ]; then
  KAR_SHA=$(sha256sum "$KAR_FILE" | awk '{print $1}')
  KAR_SIZE=$(du -h "$KAR_FILE" | cut -f1)
  echo "  File:     $KAR_FILE"
  echo "  Size:     $KAR_SIZE"
  echo "  SHA-256:  $KAR_SHA"
  check "KAR exists" "ok"
else
  check "KAR exists" "no cortex KAR found in $DEPLOY_DIR"
fi
echo ""

# ── 2. OpenNMS status ───────────────────────────────────────────────
echo "--- OpenNMS Status ---"
if "$OPENNMS_HOME/bin/opennms" status 2>/dev/null | grep -qi "running"; then
  check "OpenNMS running" "ok"
else
  check "OpenNMS running" "not running"
fi

# ── 3. Karaf health check ──────────────────────────────────────────
echo "--- Karaf Health ---"
HEALTH=$(sshpass -p "$KARAF_PASS" ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR \
  -p "$KARAF_PORT" "$KARAF_USER@localhost" "opennms:health-check" 2>/dev/null || echo "UNREACHABLE")
if echo "$HEALTH" | grep -q "Everything is awesome"; then
  check "Health check" "ok"
else
  check "Health check" "$HEALTH"
fi

# ── 4. Plugin feature status ───────────────────────────────────────
echo "--- Plugin Feature ---"
FEATURE=$(sshpass -p "$KARAF_PASS" ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR \
  -p "$KARAF_PORT" "$KARAF_USER@localhost" "feature:list | grep cortex-tss" 2>/dev/null || echo "UNREACHABLE")
if echo "$FEATURE" | grep -qi "started"; then
  check "Plugin feature started" "ok"
  echo "  $FEATURE" | head -1
else
  check "Plugin feature started" "not started or unreachable"
fi
echo ""

# ── 5. Plugin metrics (via Karaf) ──────────────────────────────────
echo "--- Plugin Metrics ---"
STATS=$(sshpass -p "$KARAF_PASS" ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR \
  -p "$KARAF_PORT" "$KARAF_USER@localhost" "opennms-cortex-tss:stats" 2>/dev/null || echo "")
if [ -n "$STATS" ]; then
  echo "$STATS" | grep -E "samplesWritten|samplesLost|connectionCount|queuedCalls" | while read -r line; do
    echo "  $line"
  done
else
  echo "  (stats command unavailable)"
fi
echo ""

# ── 6. Ring buffer status ──────────────────────────────────────────
echo "--- Ring Buffer ---"
RB_SIZE=$(sshpass -p "$KARAF_PASS" ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR \
  -p "$KARAF_PORT" "$KARAF_USER@localhost" \
  "opennms:metrics-display | grep ring-buffer" 2>/dev/null || echo "")
if [ -n "$RB_SIZE" ]; then
  echo "$RB_SIZE" | while read -r line; do echo "  $line"; done
else
  echo "  (ring buffer metrics unavailable via Karaf)"
fi
echo ""

# ── 7. Backend OOO baseline ───────────────────────────────────────
echo "--- Backend Out-of-Order Baseline ---"
if [ -n "$BACKEND_METRICS_URL" ]; then
  OOO=$(curl -sf "$BACKEND_METRICS_URL/metrics" 2>/dev/null \
    | grep 'prometheus_tsdb_out_of_order_samples_total' \
    | grep 'type="float"' \
    | awk '{print $2}' || echo "UNAVAILABLE")
  APPENDED=$(curl -sf "$BACKEND_METRICS_URL/metrics" 2>/dev/null \
    | grep 'prometheus_tsdb_head_samples_appended_total' \
    | grep 'type="float"' \
    | awk '{print $2}' || echo "UNAVAILABLE")
  echo "  OOO samples:     $OOO"
  echo "  Total appended:  $APPENDED"
  check "Backend reachable" "ok"
else
  echo "  (skipped — pass --backend-metrics-url to enable)"
  OOO="N/A"
  APPENDED="N/A"
fi
echo ""

# ── Save baseline ─────────────────────────────────────────────────
cat > "$BASELINE_FILE" <<ENVEOF
# Pre-flight baseline captured $(date -u +%Y-%m-%dT%H:%M:%SZ)
BASELINE_HOST=$(hostname)
BASELINE_KAR_SHA=${KAR_SHA:-NONE}
BASELINE_OOO=${OOO:-N/A}
BASELINE_APPENDED=${APPENDED:-N/A}
ENVEOF
echo "Baseline saved to $BASELINE_FILE"
echo ""

# ── Summary ───────────────────────────────────────────────────────
echo "==============================="
echo "$PASS checks passed, $FAIL failed"
echo "==============================="
if [ "$FAIL" -gt 0 ]; then
  echo "DO NOT PROCEED with upgrade until all checks pass."
  exit 1
else
  echo "Pre-flight passed. Safe to proceed with upgrade."
  exit 0
fi
