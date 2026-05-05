import Link from "next/link";

import type {VaultSummary} from "@/lib/vault-list";
import {formatBps, formatUsd} from "@/lib/vault-list";

export function VaultCard({vault}: {vault: VaultSummary}) {
  const tvlText = formatUsd(vault.tvlUsd);
  return (
    <Link
      href={`/vaults/${vault.address}`}
      className="group flex flex-col rounded-xl border border-border bg-surface p-5 shadow-card transition-all duration-base ease-standard hover:-translate-y-0.5 hover:border-border-strong hover:shadow-glow-violet"
      aria-label={`Open ${vault.pairName} vault`}
    >
      <header className="flex items-center justify-between gap-2">
        <span className="inline-flex items-center gap-2">
          <span aria-hidden className="h-5 w-5 rounded-md bg-spectrum-arc" />
          <span className="text-base font-medium text-text">{vault.pairName}</span>
        </span>
        <span className="rounded-pill border border-accent/40 bg-accent/10 px-2 py-0.5 text-xs text-accent">
          {vault.versionLabel}
        </span>
      </header>

      <div className="mt-4 border-t border-border pt-4">
        <p className="font-mono text-display font-semibold tracking-tight text-text" aria-label={`TVL ${tvlText}`}>
          {tvlText}
        </p>
        <p className="mt-1 text-sm text-text-muted">Total value locked</p>
      </div>

      <div className="mt-4 grid grid-cols-2 gap-4">
        <Metric label="APR" value={formatBps(vault.apr24hBps)} />
        <Metric label="Share" value={formatUsd(vault.sharePriceUsd)} />
      </div>

      <div className="mt-5 flex h-10 items-center justify-center rounded-md bg-accent text-sm font-medium text-canvas transition-colors duration-fast ease-standard group-hover:bg-accent/90">
        Deposit →
      </div>
    </Link>
  );
}

function Metric({label, value}: {label: string; value: string}) {
  return (
    <div>
      <p className="text-xs uppercase tracking-wide text-text-faint">{label}</p>
      <p className="mt-1 font-mono text-base font-medium text-text">{value}</p>
    </div>
  );
}

// Loading state — skeleton matched to the active layout.
export function VaultCardSkeleton() {
  return (
    <div
      aria-busy
      className="rounded-xl border border-border bg-surface p-5 shadow-card motion-safe:animate-pulse"
    >
      <header className="flex items-center justify-between gap-2">
        <span className="flex items-center gap-2">
          <span className="h-5 w-5 rounded-md bg-surface-raised" />
          <span className="h-4 w-28 rounded bg-surface-raised" />
        </span>
        <span className="h-5 w-10 rounded-pill bg-surface-raised" />
      </header>
      <div className="mt-4 border-t border-border pt-4">
        <span className="block h-10 w-40 rounded bg-surface-raised" />
        <span className="mt-2 block h-3 w-24 rounded bg-surface-raised" />
      </div>
      <div className="mt-4 grid grid-cols-2 gap-4">
        {[0, 1].map((i) => (
          <div key={i}>
            <span className="block h-3 w-12 rounded bg-surface-raised" />
            <span className="mt-2 block h-4 w-16 rounded bg-surface-raised" />
          </div>
        ))}
      </div>
      <div className="mt-5 h-10 w-full rounded-md bg-surface-raised" />
    </div>
  );
}
