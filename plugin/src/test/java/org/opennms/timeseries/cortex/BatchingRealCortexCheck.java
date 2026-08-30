/*
 * Licensed to The OpenNMS Group, Inc (TOG) under one or more
 * contributor license agreements.  See the LICENSE.md file
 * distributed with this work for additional information
 * regarding copyright ownership.
 *
 * TOG licenses this file to You under the GNU Affero General
 * Public License Version 3 (the "License") or (at your option)
 * any later version.  You may not use this file except in
 * compliance with the License.  You may obtain a copy of the
 * License at:
 *
 *      https://www.gnu.org/licenses/agpl-3.0.txt
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
 * either express or implied.  See the License for the specific
 * language governing permissions and limitations under the
 * License.
 */
package org.opennms.timeseries.cortex;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.time.Instant;
import java.time.temporal.ChronoField;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import org.awaitility.Awaitility;
import org.json.JSONArray;
import org.json.JSONObject;
import org.junit.Test;
import org.opennms.integration.api.v1.timeseries.Metric;
import org.opennms.integration.api.v1.timeseries.Sample;
import org.opennms.integration.api.v1.timeseries.immutables.ImmutableMetric;
import org.opennms.integration.api.v1.timeseries.immutables.ImmutableSample;

/**
 * Manual e2e check for write batching (dcy/sharded-write-batching) against a REAL Cortex backend.
 *
 * <p>NOT part of the default test run - it does not end in Test/IT/TestCase in a way that would
 * make it collide with a default `mvn test`, but it must still be invoked explicitly with
 * {@code -Dtest=BatchingRealCortexCheck}, and only once the lab is up:
 * <pre>
 *   cd plugin/src/test/resources/org/opennms/timeseries/cortex
 *   docker compose up -d
 *   # wait for http://localhost:9009/ready
 *   cd ../../../../../../../..   (back to plugin/)
 *   mvn -Dtest=BatchingRealCortexCheck test
 *   docker compose -f src/test/resources/org/opennms/timeseries/cortex/docker-compose.yaml down -v
 * </pre>
 *
 * <p>Exists because {@link NMS16271_IT} and {@link CortexTSSIntegrationTest} both use the
 * deprecated {@code DockerComposeContainer}, whose helper image negotiates an old Docker API
 * version that this machine's colima-backed daemon rejects (unrelated to the code under test - the
 * same failure occurs against unmodified {@code main}). Bypassing Testcontainers' compose
 * orchestration entirely and driving an already-running stack matches how OpenNMS's own
 * smoke-test harness (~/github/opennms/smoke-test) does it: no DockerComposeContainer there either.
 *
 * <p>Unlike the existing IT tests, this specifically exercises {@code batchingEnabled=true}: many
 * distinct series, written from multiple concurrent threads in small OpenNMS-shaped groups (a
 * couple of samples each, interleaved across series - the exact case the per-sample Entry/Series
 * duplication fix targets), then read back and checked for correct values, correct per-series
 * order, and zero loss.
 */
public class BatchingRealCortexCheck {

    @Test
    public void batchedWritesRoundTripThroughARealCortexBackend() throws Exception {
        final CortexTSSConfig config = CortexTSSConfig.builder()
                .batchingEnabled(true)
                .batchShards(4)
                .batchMaxSamples(64)
                .batchLingerMs(200)
                .build();
        final CortexTSS storage = new CortexTSS(config, new KVStoreMock());

        final int seriesCount = 20;
        final int samplesPerSeries = 15;
        final Instant referenceTime = Instant.now().with(ChronoField.MICRO_OF_SECOND, 0L).minusSeconds(samplesPerSeries + 5);

        final Map<Metric, List<Sample>> bySeries = new LinkedHashMap<>();
        for (int s = 0; s < seriesCount; s++) {
            final Metric metric = ImmutableMetric.builder()
                    .intrinsicTag("resourceId", "e2e/node" + s)
                    .intrinsicTag("name", "batching_e2e_metric_" + s)
                    .metaTag("mtype", Metric.Mtype.gauge.name())
                    .build();
            final List<Sample> series = new ArrayList<>();
            for (int t = 0; t < samplesPerSeries; t++) {
                series.add(ImmutableSample.builder()
                        .metric(metric)
                        .time(referenceTime.plusSeconds(t))
                        .value(s * 1000.0 + t)
                        .build());
            }
            bySeries.put(metric, series);
        }

        try {
            // OpenNMS never guarantees ordering ACROSS store() calls for the same series even with
            // batching enabled (see "Sample ordering" in the README) - that would make this a test
            // of the documented residual race, not of the fix under test. So each series' samples
            // are handed to store() strictly in order, a few at a time, all from one task; the
            // concurrency that matters here - many distinct series resolved through the new Series
            // cache at once - comes from running many series' tasks across the pool concurrently.
            final ExecutorService pool = Executors.newFixedThreadPool(8);
            final int groupSize = 3;
            for (List<Sample> series : bySeries.values()) {
                pool.submit(() -> {
                    try {
                        for (int i = 0; i < series.size(); i += groupSize) {
                            storage.store(new ArrayList<>(series.subList(i, Math.min(i + groupSize, series.size()))));
                        }
                    } catch (Exception e) {
                        throw new RuntimeException(e);
                    }
                });
            }
            pool.shutdown();
            assertTrue("all store() calls finished", pool.awaitTermination(30, TimeUnit.SECONDS));

            final int totalSamples = seriesCount * samplesPerSeries;
            Awaitility.await("all samples acknowledged by Cortex")
                    .atMost(Duration.ofSeconds(30))
                    .pollInterval(Duration.ofMillis(200))
                    .untilAsserted(() -> assertEquals(totalSamples,
                            storage.getMetrics().meter("samplesWritten").getCount()));
            assertEquals("no sample may be lost against a healthy backend",
                    0, storage.getMetrics().meter("samplesLost").getCount());

            // Verify against Cortex's query API directly rather than through CortexTSS#getTimeseries:
            // the write path is what changed here, and this repo's own CortexTSSIntegrationTest
            // notes Cortex's range-query semantics for raw (unaggregated) data are quirky enough to
            // need a workaround there. An instant query for each series' last value sidesteps that
            // entirely while still proving what matters for this fix: every series landed under its
            // own label set with the right value, with nothing cross-contaminated between series -
            // exactly what a bug in the shared Series cache would corrupt.
            final HttpClient http = HttpClient.newHttpClient();
            for (Map.Entry<Metric, List<Sample>> entry : bySeries.entrySet()) {
                final Metric metric = entry.getKey();
                final double expectedLastValue = entry.getValue().get(entry.getValue().size() - 1).getValue();
                final String metricName = metric.getIntrinsicTags().stream()
                        .filter(t -> "name".equals(t.getKey())).findFirst().orElseThrow().getValue();
                final String resourceId = metric.getIntrinsicTags().stream()
                        .filter(t -> "resourceId".equals(t.getKey())).findFirst().orElseThrow().getValue();
                final String query = String.format("%s{resourceId=\"%s\"}", metricName, resourceId);
                final URI uri = URI.create("http://localhost:9009/prometheus/api/v1/query?query="
                        + URLEncoder.encode(query, StandardCharsets.UTF_8));

                Awaitility.await("series " + metricName + " to report its last value")
                        .atMost(Duration.ofSeconds(30))
                        .pollInterval(Duration.ofMillis(200))
                        .until(() -> queryInstantValue(http, uri).isPresent());

                final double actualLastValue = queryInstantValue(http, uri)
                        .orElseThrow(() -> new AssertionError("no value for " + metricName));
                assertEquals("the last value of " + metricName + " must round-trip untouched",
                        expectedLastValue, actualLastValue, 0.0001);
            }
        } finally {
            storage.destroy();
        }
    }

    private static Optional<Double> queryInstantValue(final HttpClient http, final URI uri) throws Exception {
        final HttpResponse<String> response = http.send(HttpRequest.newBuilder(uri).GET().build(),
                HttpResponse.BodyHandlers.ofString());
        final JSONArray result = new JSONObject(response.body()).getJSONObject("data").getJSONArray("result");
        if (result.isEmpty()) {
            return java.util.Optional.empty();
        }
        return java.util.Optional.of(result.getJSONObject(0).getJSONArray("value").getDouble(1));
    }
}
