# Cortex TSS Plugin — Production Upgrade Test Plan

## Overview

This plan covers upgrading the `opennms-plugins-cortex-tss` KAR in a production
environment where the plugin is already active and writing metrics. It assumes
a load-balanced deployment where instances can be upgraded one at a time.

**What's changing:** The plugin's `store()` method switches from async
fire-and-forget HTTP writes to synchronous (blocking) writes. This eliminates
out-of-order sample rejection at the backend but changes the threading behavior
of the write path.

**Risk profile:**
- Write throughput is unchanged (validated via A/B testing)
- Ring buffer worker threads now block on HTTP I/O — monitor ring buffer depth
- Write errors now propagate as `StorageException` instead of being silently counted
- Rollback is a KAR swap + Karaf restart (< 5 minutes)

## Environment Assumptions

| Item | Value |
|---|---|
| OpenNMS install path | `/opt/opennms` |
| KAR deploy directory | `/opt/opennms/deploy` |
| Karaf SSH port | `8101` |
| Backend | Cortex / Thanos / Mimir (Prometheus remote write compatible) |
| Topology | N OpenNMS instances behind load balancer, shared backend |

## Pre-Upgrade Checklist

Before touching anything, run the pre-flight script on **each instance**:

```bash
sudo ./pre-flight.sh
```

This captures:
- Current KAR checksum and version
- Karaf feature status
- Backend OOO sample count (baseline)
- Ring buffer depth and sample rates
- OpenNMS health check status

**Do not proceed** if:
- `opennms:health-check` does not report "Everything is awesome"
- The ring buffer is consistently full (indicates backpressure)
- Backend is unreachable

## Upgrade Procedure (Per Instance)

### Rolling upgrade order

For a load-balanced deployment with instances A, B, C:

1. Upgrade instance A, validate for **minimum 15 minutes**
2. If A is healthy, upgrade instance B, validate 15 minutes
3. If B is healthy, upgrade instance C
4. If any instance fails validation, **rollback that instance immediately**
   and stop the rollout

### Execute upgrade

```bash
sudo ./roll-forward.sh /path/to/opennms-cortex-tss-plugin.kar
```

The script will:
1. Verify the new KAR is a valid zip
2. Back up the current KAR and Karaf cache
3. Stop OpenNMS
4. Swap the KAR
5. Clear the Karaf cache (forces clean feature reload)
6. Start OpenNMS
7. Wait for health check
8. Install/verify the plugin feature
9. Print initial metrics baseline

### Validate

After upgrade, run validation on a loop:

```bash
sudo ./validate.sh --watch 60
```

This checks every 60 seconds:
- Plugin feature is Started
- `opennms:health-check` passes
- Backend OOO counter is **not increasing**
- Ring buffer is not full
- `samplesWritten` rate is > 0
- `samplesLost` rate is 0

Let it run for at least 15 minutes (covers multiple collection cycles).

**Success criteria:**
- OOO samples: zero new OOO samples since upgrade
- Ring buffer: depth stays below 50% capacity
- Samples written: rate comparable to pre-upgrade baseline
- Samples lost: zero
- Health check: passing continuously

## Rollback Procedure

If validation fails on any metric:

```bash
sudo ./roll-back.sh
```

This will:
1. Stop OpenNMS
2. Restore the backed-up KAR from `/opt/opennms/deploy/.backup/`
3. Restore the Karaf cache
4. Start OpenNMS
5. Verify the old plugin version is running

Rollback is safe at any point — the backup is taken atomically before the swap.

## Monitoring Checklist (Post-Upgrade)

After all instances are upgraded:

| Metric | Source | Expected |
|---|---|---|
| `prometheus_tsdb_out_of_order_samples_total` | Backend /metrics | No increase |
| `samplesWritten` (1m rate) | Karaf `opennms-cortex-tss:stats` | Comparable to baseline |
| `samplesLost` (1m rate) | Karaf `opennms-cortex-tss:stats` | 0 |
| Ring buffer depth | JMX / Karaf | < 50% capacity |
| `opennms:health-check` | Karaf shell | "Everything is awesome" |
| Collection completion time | OpenNMS logs | Not increasing |

## Appendix: What Changed

```
--- a/plugin/src/main/java/org/opennms/timeseries/cortex/CortexTSS.java
+++ b/plugin/src/main/java/org/opennms/timeseries/cortex/CortexTSS.java

- asyncHttpCallsBulkhead.executeCompletionStage(() -> executeAsync(request))
-     .whenComplete((r, ex) -> {
-         if (ex == null) { samplesWritten.mark(...); }
-         else { samplesLost.mark(...); LOG.error(...); }
-     });

+ try {
+     asyncHttpCallsBulkhead.executeCompletionStage(() -> executeAsync(request))
+         .toCompletableFuture()
+         .get(config.getWriteTimeoutInMs(), TimeUnit.MILLISECONDS);
+     samplesWritten.mark(...);
+ } catch (Exception ex) {
+     samplesLost.mark(...);
+     throw new StorageException(...);
+ }
```

**Before:** Fire-and-forget. Worker thread returns immediately, HTTP completes
whenever. Next batch may overtake the current one.

**After:** Worker thread blocks until HTTP 2xx response. Next batch cannot be
processed until the current write lands. Per-series timestamp ordering is
preserved across consecutive WriteRequests.
