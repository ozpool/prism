/// In-memory metrics collected across the keeper's lifetime. Exposed as
/// a snapshot the lifecycle layer (#60) serves under /metrics. The
/// surface is intentionally tiny: a counter set + a latency reservoir
/// that resolves p50/p99 lazily.
///
/// Why hand-rolled instead of prom-client: a single-process keeper with
/// no scrape endpoint until #60 has no need for the prom-client tax.
/// The shape is compatible — when /metrics lands, exporting a Prometheus
/// text body from this snapshot is ~30 lines.

const MAX_RESERVOIR = 1024;

export interface MetricsSnapshot {
  cycleCount: number;
  cycleErrors: number;
  rebalancesSimulated: number;
  rebalancesSubmitted: number;
  rebalancesConfirmed: number;
  rebalancesFailed: number;
  cycleLatencyP50Ms: number;
  cycleLatencyP99Ms: number;
  cycleLatencyMaxMs: number;
  startedAtMs: number;
  uptimeMs: number;
}

export class Metrics {
  private cycleCount = 0;
  private cycleErrors = 0;
  private rebalancesSimulated = 0;
  private rebalancesSubmitted = 0;
  private rebalancesConfirmed = 0;
  private rebalancesFailed = 0;

  /// Reservoir-sampled cycle latencies. Bounded to MAX_RESERVOIR so the
  /// keeper running for weeks does not retain unbounded samples; older
  /// entries fall out of the percentile estimate as new ones arrive.
  /// O(1) writes, O(n log n) reads (only when snapshot is requested).
  private readonly latencies: number[] = [];

  private readonly startedAtMs = Date.now();

  cycleCompleted(latencyMs: number): void {
    this.cycleCount++;
    this.recordLatency(latencyMs);
  }

  cycleFailed(latencyMs: number): void {
    this.cycleCount++;
    this.cycleErrors++;
    this.recordLatency(latencyMs);
  }

  rebalanceSimulated(): void {
    this.rebalancesSimulated++;
  }

  rebalanceSubmitted(): void {
    this.rebalancesSubmitted++;
  }

  rebalanceConfirmed(): void {
    this.rebalancesConfirmed++;
  }

  rebalanceFailed(): void {
    this.rebalancesFailed++;
  }

  snapshot(): MetricsSnapshot {
    const sorted = [...this.latencies].sort((a, b) => a - b);
    return {
      cycleCount: this.cycleCount,
      cycleErrors: this.cycleErrors,
      rebalancesSimulated: this.rebalancesSimulated,
      rebalancesSubmitted: this.rebalancesSubmitted,
      rebalancesConfirmed: this.rebalancesConfirmed,
      rebalancesFailed: this.rebalancesFailed,
      cycleLatencyP50Ms: percentile(sorted, 0.5),
      cycleLatencyP99Ms: percentile(sorted, 0.99),
      cycleLatencyMaxMs: sorted.length === 0 ? 0 : (sorted[sorted.length - 1] ?? 0),
      startedAtMs: this.startedAtMs,
      uptimeMs: Date.now() - this.startedAtMs,
    };
  }

  private recordLatency(ms: number): void {
    if (this.latencies.length < MAX_RESERVOIR) {
      this.latencies.push(ms);
      return;
    }
    // Reservoir replacement — keep the distribution stable as samples
    // accumulate. Vitter's Algorithm R: replace at random index.
    const idx = Math.floor(Math.random() * this.latencies.length);
    this.latencies[idx] = ms;
  }
}

function percentile(sorted: readonly number[], p: number): number {
  if (sorted.length === 0) return 0;
  const idx = Math.min(sorted.length - 1, Math.floor(p * sorted.length));
  return sorted[idx] ?? 0;
}
