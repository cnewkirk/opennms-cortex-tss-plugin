#!/usr/bin/env bash
#
# Roll back: restore the previous Cortex TSS plugin KAR from backup.
#
# Usage: sudo ./roll-back.sh [--manifest /path/to/rollback-manifest.env]
#
# By default uses the latest manifest at /opt/opennms/deploy/.backup/rollback-manifest.latest.env
#
set -euo pipefail

OPENNMS_HOME="${OPENNMS_HOME:-/opt/opennms}"
DEPLOY_DIR="$OPENNMS_HOME/deploy"
BACKUP_DIR="$DEPLOY_DIR/.backup"
KARAF_PORT="${KARAF_PORT:-8101}"
KARAF_USER="${KARAF_USER:-admin}"
KARAF_PASS="${KARAF_PASS:-admin}"
STARTUP_TIMEOUT=300
MANIFEST=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest)   MANIFEST="$2"; shift 2 ;;
    --manifest=*) MANIFEST="${1#*=}"; shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [ -z "$MANIFEST" ]; then
  MANIFEST="$BACKUP_DIR/rollback-manifest.latest.env"
fi

echo "=== Cortex TSS Plugin — Roll Back ==="
echo "  Host:     $(hostname)"
echo "  Date:     $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "  Manifest: $MANIFEST"
echo ""

# ── Load manifest ──────────────────────────────────────────────────
if [ ! -f "$MANIFEST" ]; then
  echo "ERROR: Rollback manifest not found at $MANIFEST"
  echo ""
  echo "Available manifests:"
  ls -1t "$BACKUP_DIR"/rollback-manifest.*.env 2>/dev/null || echo "  (none)"
  echo ""
  echo "Usage: $0 --manifest /path/to/rollback-manifest.env"
  exit 1
fi

# shellcheck source=/dev/null
source "$MANIFEST"
echo "  Backup KAR:   $ROLLBACK_KAR"
echo "  Backup cache: $ROLLBACK_CACHE"
echo "  Original at:  $ROLLBACK_DEPLOY_DIR"
echo "  Timestamp:    $ROLLBACK_TIMESTAMP"
echo ""

# ── Validate backup exists ─────────────────────────────────────────
if [ "$ROLLBACK_KAR" = "NONE" ]; then
  echo "ERROR: No KAR backup recorded in manifest (was this a fresh install?)"
  echo "  If so, remove the KAR manually: rm $DEPLOY_DIR/opennms-cortex-tss-plugin.kar"
  exit 1
fi
if [ ! -f "$ROLLBACK_KAR" ]; then
  echo "ERROR: Backup KAR not found at $ROLLBACK_KAR"
  exit 1
fi
echo "--- Backup KAR verified ---"
echo "  SHA-256: $(sha256sum "$ROLLBACK_KAR" | awk '{print $1}')"
echo ""

# ── Step 1: Stop OpenNMS ───────────────────────────────────────────
echo "--- Step 1: Stopping OpenNMS ---"
"$OPENNMS_HOME/bin/opennms" stop 2>/dev/null || true
echo "  Stopped"
echo ""

# ── Step 2: Restore KAR ───────────────────────────────────────────
echo "--- Step 2: Restoring previous KAR ---"
find "$DEPLOY_DIR" -maxdepth 1 \( -name '*cortex*tss*.kar' -o -name '*cortex*.kar' \) -delete 2>/dev/null || true
cp "$ROLLBACK_KAR" "$DEPLOY_DIR/$ROLLBACK_KAR_FILENAME"
echo "  Restored: $DEPLOY_DIR/$ROLLBACK_KAR_FILENAME"
echo ""

# ── Step 3: Restore Karaf cache ───────────────────────────────────
echo "--- Step 3: Restoring Karaf cache ---"
if [ "$ROLLBACK_CACHE" != "NONE" ] && [ -f "$ROLLBACK_CACHE" ]; then
  rm -rf "$OPENNMS_HOME/data/cache"
  tar -xzf "$ROLLBACK_CACHE" -C "$OPENNMS_HOME/data"
  echo "  Cache restored from $ROLLBACK_CACHE"
else
  # No cache backup — just clear it and let Karaf rebuild
  rm -rf "$OPENNMS_HOME/data/cache"
  echo "  No cache backup — cleared cache for clean rebuild"
fi
echo ""

# ── Step 4: Start OpenNMS ─────────────────────────────────────────
echo "--- Step 4: Starting OpenNMS ---"
"$OPENNMS_HOME/bin/opennms" -v start
echo ""

# ── Step 5: Wait for health check ────────────────────────────────
echo "--- Step 5: Waiting for OpenNMS (up to ${STARTUP_TIMEOUT}s) ---"
DEADLINE=$((SECONDS + STARTUP_TIMEOUT))
HEALTHY=false
while [ $SECONDS -lt $DEADLINE ]; do
  HEALTH=$(sshpass -p "$KARAF_PASS" ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR \
    -p "$KARAF_PORT" "$KARAF_USER@localhost" "opennms:health-check" 2>/dev/null || echo "")
  if echo "$HEALTH" | grep -q "Everything is awesome"; then
    echo "  Healthy (${SECONDS}s elapsed)"
    HEALTHY=true
    break
  fi
  sleep 10
done
if [ "$HEALTHY" = false ]; then
  echo "ERROR: OpenNMS did not pass health check within ${STARTUP_TIMEOUT}s"
  echo "  Manual intervention required."
  exit 1
fi
echo ""

# ── Step 6: Verify plugin ────────────────────────────────────────
echo "--- Step 6: Verifying plugin feature ---"
FEATURE_STATUS=$(sshpass -p "$KARAF_PASS" ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR \
  -p "$KARAF_PORT" "$KARAF_USER@localhost" "feature:list | grep cortex-tss" 2>/dev/null || echo "UNKNOWN")
echo "  $FEATURE_STATUS" | head -1

if echo "$FEATURE_STATUS" | grep -qi "started"; then
  echo "  Plugin running on previous version"
else
  echo "WARNING: Plugin may need manual feature install"
  echo "  sshpass -p admin ssh -p 8101 admin@localhost 'feature:install opennms-plugins-cortex-tss'"
fi
echo ""

# ── Done ─────────────────────────────────────────────────────────
echo "======================================="
echo "Roll back complete."
echo "======================================="
echo ""
echo "Run ./pre-flight.sh to verify the instance is healthy."
