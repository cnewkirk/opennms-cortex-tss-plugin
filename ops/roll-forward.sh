#!/usr/bin/env bash
#
# Roll forward: upgrade the Cortex TSS plugin KAR on a running OpenNMS instance.
#
# Usage: sudo ./roll-forward.sh /path/to/new/opennms-cortex-tss-plugin.kar
#
# What it does:
#   1. Validates the new KAR
#   2. Backs up current KAR + Karaf cache
#   3. Stops OpenNMS
#   4. Swaps the KAR
#   5. Clears Karaf cache
#   6. Starts OpenNMS
#   7. Waits for health check
#   8. Installs/verifies the plugin feature
#
set -euo pipefail

OPENNMS_HOME="${OPENNMS_HOME:-/opt/opennms}"
DEPLOY_DIR="$OPENNMS_HOME/deploy"
KARAF_CACHE="$OPENNMS_HOME/data/cache"
BACKUP_DIR="$DEPLOY_DIR/.backup"
KARAF_PORT="${KARAF_PORT:-8101}"
KARAF_USER="${KARAF_USER:-admin}"
KARAF_PASS="${KARAF_PASS:-admin}"
STARTUP_TIMEOUT=300

# ── Parse args ──────────────────────────────────────────────────────
if [ $# -lt 1 ]; then
  echo "Usage: $0 /path/to/new/opennms-cortex-tss-plugin.kar"
  exit 1
fi
NEW_KAR="$1"

echo "=== Cortex TSS Plugin — Roll Forward ==="
echo "  Host:     $(hostname)"
echo "  Date:     $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "  New KAR:  $NEW_KAR"
echo ""

# ── Step 1: Validate new KAR ───────────────────────────────────────
echo "--- Step 1: Validating new KAR ---"
if [ ! -f "$NEW_KAR" ]; then
  echo "ERROR: File not found: $NEW_KAR"
  exit 1
fi
if ! file "$NEW_KAR" | grep -qi "zip"; then
  echo "ERROR: $NEW_KAR does not appear to be a valid KAR (zip) file"
  exit 1
fi
NEW_KAR_SHA=$(sha256sum "$NEW_KAR" | awk '{print $1}')
echo "  SHA-256: $NEW_KAR_SHA"
echo "  Size:    $(du -h "$NEW_KAR" | cut -f1)"
echo ""

# ── Step 2: Backup current state ───────────────────────────────────
echo "--- Step 2: Backing up current state ---"
mkdir -p "$BACKUP_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Backup current KAR
CURRENT_KAR=$(find "$DEPLOY_DIR" -maxdepth 1 \( -name '*cortex*tss*.kar' -o -name '*cortex*.kar' \) 2>/dev/null | head -1)
if [ -n "$CURRENT_KAR" ]; then
  BACKUP_KAR="$BACKUP_DIR/$(basename "$CURRENT_KAR").$TIMESTAMP"
  cp "$CURRENT_KAR" "$BACKUP_KAR"
  echo "  KAR backed up to: $BACKUP_KAR"
else
  echo "  No existing cortex KAR found (fresh install)"
  BACKUP_KAR=""
fi

# Backup Karaf cache
if [ -d "$KARAF_CACHE" ]; then
  BACKUP_CACHE="$BACKUP_DIR/karaf-cache.$TIMESTAMP.tar.gz"
  tar -czf "$BACKUP_CACHE" -C "$OPENNMS_HOME/data" cache 2>/dev/null
  echo "  Karaf cache backed up to: $BACKUP_CACHE"
else
  BACKUP_CACHE=""
  echo "  No Karaf cache found"
fi

# Save rollback manifest
MANIFEST="$BACKUP_DIR/rollback-manifest.$TIMESTAMP.env"
cat > "$MANIFEST" <<ENVEOF
# Rollback manifest — created $(date -u +%Y-%m-%dT%H:%M:%SZ)
ROLLBACK_TIMESTAMP=$TIMESTAMP
ROLLBACK_KAR=${BACKUP_KAR:-NONE}
ROLLBACK_CACHE=${BACKUP_CACHE:-NONE}
ROLLBACK_DEPLOY_DIR=$DEPLOY_DIR
ROLLBACK_KAR_FILENAME=$(basename "${CURRENT_KAR:-opennms-cortex-tss-plugin.kar}")
NEW_KAR_SHA=$NEW_KAR_SHA
ENVEOF
# Also symlink as "latest" for easy rollback
ln -sf "$MANIFEST" "$BACKUP_DIR/rollback-manifest.latest.env"
echo "  Manifest: $MANIFEST"
echo ""

# ── Step 3: Stop OpenNMS ────────────────────────────────────────────
echo "--- Step 3: Stopping OpenNMS ---"
"$OPENNMS_HOME/bin/opennms" stop
echo "  Stopped"
echo ""

# ── Step 4: Swap KAR ───────────────────────────────────────────────
echo "--- Step 4: Swapping KAR ---"
# Remove old cortex KAR(s)
find "$DEPLOY_DIR" -maxdepth 1 \( -name '*cortex*tss*.kar' -o -name '*cortex*.kar' \) -delete 2>/dev/null || true
# Deploy new KAR
cp "$NEW_KAR" "$DEPLOY_DIR/opennms-cortex-tss-plugin.kar"
echo "  Deployed: $DEPLOY_DIR/opennms-cortex-tss-plugin.kar"
echo ""

# ── Step 5: Clear Karaf cache ──────────────────────────────────────
echo "--- Step 5: Clearing Karaf cache ---"
if [ -d "$KARAF_CACHE" ]; then
  rm -rf "$KARAF_CACHE"
  echo "  Cache cleared"
else
  echo "  No cache to clear"
fi
echo ""

# ── Step 6: Start OpenNMS ──────────────────────────────────────────
echo "--- Step 6: Starting OpenNMS ---"
"$OPENNMS_HOME/bin/opennms" -v start
echo ""

# ── Step 7: Wait for health check ─────────────────────────────────
echo "--- Step 7: Waiting for OpenNMS (up to ${STARTUP_TIMEOUT}s) ---"
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
  echo "  Consider running roll-back.sh"
  exit 1
fi
echo ""

# ── Step 8: Verify plugin feature ─────────────────────────────────
echo "--- Step 8: Verifying plugin feature ---"
# The KAR auto-deploys the feature repo, but the feature may need explicit install
FEATURE_STATUS=$(sshpass -p "$KARAF_PASS" ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR \
  -p "$KARAF_PORT" "$KARAF_USER@localhost" "feature:list | grep cortex-tss" 2>/dev/null || echo "")

if echo "$FEATURE_STATUS" | grep -qi "started"; then
  echo "  Plugin already started"
elif echo "$FEATURE_STATUS" | grep -qi "installed\|resolved"; then
  echo "  Feature present but not started, installing..."
  sshpass -p "$KARAF_PASS" ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR \
    -p "$KARAF_PORT" "$KARAF_USER@localhost" "feature:install opennms-plugins-cortex-tss" 2>/dev/null
  sleep 5
  FEATURE_STATUS=$(sshpass -p "$KARAF_PASS" ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR \
    -p "$KARAF_PORT" "$KARAF_USER@localhost" "feature:list | grep cortex-tss" 2>/dev/null || echo "")
  if echo "$FEATURE_STATUS" | grep -qi "started"; then
    echo "  Plugin started successfully"
  else
    echo "ERROR: Plugin feature did not start"
    echo "  $FEATURE_STATUS"
    echo "  Consider running roll-back.sh"
    exit 1
  fi
else
  echo "WARNING: Plugin feature not found. Attempting install..."
  sshpass -p "$KARAF_PASS" ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR \
    -p "$KARAF_PORT" "$KARAF_USER@localhost" "feature:install opennms-plugins-cortex-tss" 2>/dev/null
  sleep 5
fi
echo ""

# ── Done ──────────────────────────────────────────────────────────
echo "======================================="
echo "Roll forward complete."
echo "======================================="
echo ""
echo "Next steps:"
echo "  1. Run ./validate.sh --watch 60 for at least 15 minutes"
echo "  2. Monitor backend OOO counter — should not increase"
echo "  3. If anything looks wrong: sudo ./roll-back.sh"
