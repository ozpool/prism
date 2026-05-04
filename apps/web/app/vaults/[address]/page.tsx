"use client";

import {notFound} from "next/navigation";
import {useMemo} from "react";
import {isAddress} from "viem";

import {PrismVisual, type PrismPosition} from "@/components/PrismVisual";
import {formatBps, formatUsd} from "@/lib/vault-list";

interface PageProps {
  params: {address: string};
}

export default function VaultDetailPage({params}: PageProps) {
  const {address} = params;
  if (!isAddress(address)) {
    notFound();
  }

  // Real reads land in M2 once #31 (VaultFactory) ships and the data
  // layer can resolve a vault address to its config + on-chain state.
  // Until then we render the layout with placeholder values so the
  // page composes correctly under the app shell + brand tokens.
  const detail = usePlaceholderVault(address);

  return (
    <article className="flex flex-col gap-8 py-2">
      <Header pairName={detail.pairName} versionLabel={detail.versionLabel} address={detail.address} />

      <section className="grid grid-cols-1 gap-4 md:grid-cols-3">
        <Metric label="TVL" value={formatUsd(detail.tvlUsd)} />
        <Metric label="APR (24h)" value={formatBps(detail.apr24hBps)} />
        <Metric label="Share price" value={formatUsd(detail.sharePriceUsd)} />
      </section>

      <PrismVisual
        positions={detail.positions}
        currentTick={detail.currentTick}
        tickSpacing={detail.tickSpacing}
      />

      <PositionsTable positions={detail.positions} />

      <DepositPanel placeholder />
    </article>
  );
}

function Header({pairName, versionLabel, address}: {pairName: string; versionLabel: string; address: string}) {
  return (
    <header className="flex flex-col gap-3">
      <span className="inline-flex items-center gap-2">
        <span aria-hidden className="h-6 w-6 rounded-md bg-spectrum-arc shadow-glow-violet" />
        <h1 className="text-3xl font-semibold tracking-tight text-text">{pairName}</h1>
        <span className="rounded-pill border border-accent/40 bg-accent/10 px-2 py-0.5 text-xs text-accent">
          {versionLabel}
        </span>
      </span>
      <p className="font-mono text-xs text-text-faint" aria-label={`Vault address ${address}`}>
        {address}
      </p>
    </header>
  );
}

function Metric({label, value}: {label: string; value: string}) {
  return (
    <div className="rounded-xl border border-border bg-surface p-5 shadow-card">
      <p className="text-xs uppercase tracking-wide text-text-faint">{label}</p>
      <p className="mt-2 font-mono text-2xl font-semibold text-text">{value}</p>
    </div>
  );
}

function PositionsTable({positions}: {positions: PlaceholderPosition[]}) {
  return (
    <section className="rounded-xl border border-border bg-surface p-5 shadow-card">
      <h2 className="mb-4 text-base font-medium text-text">Positions</h2>
      {positions.length === 0 ? (
        <p className="text-sm text-text-muted">No positions deployed yet.</p>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead className="text-xs uppercase tracking-wide text-text-faint">
              <tr>
                <th className="py-2 text-left font-medium">Range</th>
                <th className="py-2 text-right font-medium">Liquidity</th>
                <th className="py-2 text-right font-medium">Token0</th>
                <th className="py-2 text-right font-medium">Token1</th>
              </tr>
            </thead>
            <tbody>
              {positions.map((p, i) => (
                <tr key={i} className="border-t border-border">
                  <td className="py-3 font-mono text-text">
                    {p.tickLower} → {p.tickUpper}
                  </td>
                  <td className="py-3 text-right font-mono text-text-muted">{p.liquidity.toString()}</td>
                  <td className="py-3 text-right font-mono text-text-muted">{p.token0.toString()}</td>
                  <td className="py-3 text-right font-mono text-text-muted">{p.token1.toString()}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}

function DepositPanel({placeholder}: {placeholder: boolean}) {
  return (
    <section className="rounded-xl border border-border bg-surface p-5 shadow-card">
      <h2 className="mb-2 text-base font-medium text-text">Deposit</h2>
      <p className="text-sm text-text-muted">
        {placeholder
          ? "Form lands with #52 (deposit form). Wallet + wagmi reads are wired; M2 contracts surface the on-chain state."
          : null}
      </p>
    </section>
  );
}

interface PlaceholderPosition extends PrismPosition {
  token0: bigint;
  token1: bigint;
}

interface PlaceholderDetail {
  address: string;
  pairName: string;
  versionLabel: string;
  tvlUsd: bigint;
  apr24hBps: number;
  sharePriceUsd: bigint;
  positions: PlaceholderPosition[];
  currentTick: number;
  tickSpacing: number;
}

function usePlaceholderVault(address: string): PlaceholderDetail {
  return useMemo(
    () => ({
      address,
      pairName: "WETH / USDC",
      versionLabel: "v1",
      tvlUsd: 0n,
      apr24hBps: 0,
      sharePriceUsd: 1_000_000n, // 1.000000 USDC (6 decimals)
      // Placeholder shape — three positions either side of tick 0,
      // weighted to draw a recognisable bell. Real values land with
      // #31 (VaultFactory) + getTotalAmounts wire-up in M2.
      positions: [
        {tickLower: -1200, tickUpper: -600, liquidity: 4_000_000n, token0: 0n, token1: 0n},
        {tickLower: -600, tickUpper: 600, liquidity: 10_000_000n, token0: 0n, token1: 0n},
        {tickLower: 600, tickUpper: 1200, liquidity: 4_000_000n, token0: 0n, token1: 0n},
      ],
      currentTick: 0,
      tickSpacing: 60,
    }),
    [address],
  );
}
