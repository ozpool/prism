"use client";

import {scaleLinear} from "d3-scale";
import {useMemo} from "react";

/// One tick-range position the vault holds, with the V4 liquidity it
/// represents. Mirrors `Vault.Position` in the contracts package.
export interface PrismPosition {
  tickLower: number;
  tickUpper: number;
  liquidity: bigint;
}

interface PrismVisualProps {
  /// Positions to render. Empty array → empty-state placeholder.
  positions: PrismPosition[];
  /// Current pool tick — drawn as a vertical guide line. Omit to skip.
  currentTick?: number;
  /// Tick spacing of the underlying pool. Used to widen the x-axis a
  /// touch beyond the position extents so the side bars don't kiss the
  /// chart edge.
  tickSpacing: number;
  /// Pixel height of the chart. Width is fluid (100%).
  height?: number;
  className?: string;
}

const SPECTRUM = [
  "rgb(124 92 255)", // violet
  "rgb(92 138 255)", // indigo
  "rgb(62 220 255)", // teal
  "rgb(62 255 155)", // mint
  "rgb(255 209 102)", // amber
  "rgb(255 92 138)", // rose
] as const;

/**
 * Visualises the vault's prism — a layered set of tick-range positions —
 * as a horizontal "spectrum" of liquidity blocks along the tick axis.
 *
 * Each block spans [`tickLower`, `tickUpper`] horizontally and has a
 * height proportional to its share of total liquidity. Block colours
 * cycle through the brand spectrum so adjacent positions stay visually
 * distinct.
 */
export function PrismVisual({
  positions,
  currentTick,
  tickSpacing,
  height = 180,
  className,
}: PrismVisualProps) {
  const empty = positions.length === 0;

  const layout = useMemo(() => {
    if (empty) return null;

    const lows = positions.map((p) => p.tickLower);
    const highs = positions.map((p) => p.tickUpper);
    const minTick = Math.min(...lows) - tickSpacing;
    const maxTick = Math.max(...highs) + tickSpacing;

    // d3 linear scale on a 0..100 viewBox keeps the chart fluid — the
    // SVG itself stretches to fit its container.
    const x = scaleLinear().domain([minTick, maxTick]).range([0, 100]);

    // Liquidity is bigint on the wire; convert to number for the
    // height ratio. Loss of precision is acceptable for a *visual*
    // ratio (we only care about the sort order, not the absolute
    // value).
    const maxLiquidity =
      positions.reduce((acc, p) => (p.liquidity > acc ? p.liquidity : acc), 0n) || 1n;
    const liquidityRatio = (l: bigint) => Number((l * 1000n) / maxLiquidity) / 1000;

    return {
      x,
      minTick,
      maxTick,
      blocks: positions.map((p, i) => ({
        x0: x(p.tickLower),
        x1: x(p.tickUpper),
        ratio: liquidityRatio(p.liquidity),
        color: SPECTRUM[i % SPECTRUM.length],
      })),
    };
  }, [positions, tickSpacing, empty]);

  if (empty) {
    return (
      <section
        className={`rounded-xl border border-border bg-surface p-5 shadow-card ${className ?? ""}`}
        style={{minHeight: height}}
      >
        <h2 className="mb-4 text-base font-medium text-text">Prism</h2>
        <div className="flex items-center justify-center" style={{height: height - 60}}>
          <p className="text-sm text-text-muted">No positions deployed yet.</p>
        </div>
      </section>
    );
  }

  // Non-null assertion — `empty === false` implies layout populated.
  const {x, minTick, maxTick, blocks} = layout!;
  const tickIndicatorX =
    currentTick !== undefined && currentTick >= minTick && currentTick <= maxTick
      ? x(currentTick)
      : null;

  return (
    <section
      className={`rounded-xl border border-border bg-surface p-5 shadow-card ${className ?? ""}`}
      aria-label="Prism — vault liquidity distribution"
    >
      <header className="mb-4 flex items-baseline justify-between">
        <h2 className="text-base font-medium text-text">Prism</h2>
        <p className="text-xs text-text-faint">
          {positions.length} {positions.length === 1 ? "position" : "positions"}
        </p>
      </header>

      <svg
        viewBox="0 0 100 100"
        preserveAspectRatio="none"
        role="img"
        aria-label="Liquidity distribution across tick ranges"
        style={{width: "100%", height}}
      >
        {/* Floor — full-width hairline so empty corridors read clearly. */}
        <line
          x1={0}
          y1={100}
          x2={100}
          y2={100}
          stroke="rgb(var(--color-border-strong))"
          strokeWidth={0.5}
          vectorEffect="non-scaling-stroke"
        />

        {/* Position blocks — height proportional to liquidity. */}
        {blocks.map((b, i) => {
          const blockHeight = b.ratio * 90; // leave 10% headroom
          return (
            <rect
              key={i}
              x={b.x0}
              y={100 - blockHeight}
              width={Math.max(b.x1 - b.x0, 0.5)}
              height={blockHeight}
              fill={b.color}
              fillOpacity={0.55}
              stroke={b.color}
              strokeWidth={0.5}
              vectorEffect="non-scaling-stroke"
              rx={0.5}
            />
          );
        })}

        {/* Current-tick indicator. */}
        {tickIndicatorX !== null ? (
          <g>
            <line
              x1={tickIndicatorX}
              y1={0}
              x2={tickIndicatorX}
              y2={100}
              stroke="rgb(var(--color-text))"
              strokeWidth={0.75}
              strokeDasharray="2 2"
              vectorEffect="non-scaling-stroke"
            />
          </g>
        ) : null}
      </svg>

      <footer className="mt-3 flex justify-between font-mono text-xs text-text-faint">
        <span>tick {minTick}</span>
        {currentTick !== undefined ? <span>now {currentTick}</span> : null}
        <span>tick {maxTick}</span>
      </footer>
    </section>
  );
}
