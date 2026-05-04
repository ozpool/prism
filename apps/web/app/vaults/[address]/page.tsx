"use client";

import {notFound} from "next/navigation";
import {useMemo} from "react";
import {isAddress, zeroAddress, type Address} from "viem";

import {DepositForm} from "@/components/DepositForm";
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

      <PositionsTable positions={detail.positions} />

      <DepositForm
        vaultAddress={detail.address as Address}
        token0={detail.token0}
        token1={detail.token1}
      />
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

interface PlaceholderPosition {
  tickLower: number;
  tickUpper: number;
  liquidity: bigint;
  token0: bigint;
  token1: bigint;
}

interface PlaceholderToken {
  address: Address;
  symbol: string;
  decimals: number;
}

interface PlaceholderDetail {
  address: string;
  pairName: string;
  versionLabel: string;
  tvlUsd: bigint;
  apr24hBps: number;
  sharePriceUsd: bigint;
  positions: PlaceholderPosition[];
  token0: PlaceholderToken;
  token1: PlaceholderToken;
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
      positions: [],
      // Token metadata is fixed for the placeholder vault; real values
      // come from the data layer once #31 (VaultFactory) lands.
      token0: {address: zeroAddress, symbol: "WETH", decimals: 18},
      token1: {address: zeroAddress, symbol: "USDC", decimals: 6},
    }),
    [address],
  );
}
