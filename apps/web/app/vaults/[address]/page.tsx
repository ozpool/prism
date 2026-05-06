"use client";

import {notFound} from "next/navigation";
import {useMemo} from "react";
import {erc20Abi, isAddress, zeroAddress, type Address} from "viem";
import {useReadContracts} from "wagmi";

import {VaultAbi} from "@prism/shared";
import {DepositForm} from "@/components/DepositForm";
import {PrismVisual, type PrismPosition} from "@/components/PrismVisual";
import {WithdrawForm} from "@/components/WithdrawForm";
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

      <div className="grid grid-cols-1 gap-6 md:grid-cols-2">
        <DepositForm
          vaultAddress={detail.address as Address}
          token0={detail.token0}
          token1={detail.token1}
        />
        <WithdrawForm
          vaultAddress={detail.address as Address}
          token0Symbol={detail.token0.symbol}
          token1Symbol={detail.token1.symbol}
          token0Decimals={detail.token0.decimals}
          token1Decimals={detail.token1.decimals}
        />
      </div>
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

interface PlaceholderPosition extends PrismPosition {
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
  currentTick: number;
  tickSpacing: number;
  token0: PlaceholderToken;
  token1: PlaceholderToken;
}

interface PoolKeyOnChain {
  currency0: Address;
  currency1: Address;
  fee: number;
  tickSpacing: number;
  hooks: Address;
}

function usePlaceholderVault(address: string): PlaceholderDetail {
  // Read poolKey + name from the vault. Token symbol/decimals come from
  // the ERC-20s themselves (read in a second batch, gated on the first).
  const isReal = isAddress(address) && address !== zeroAddress;
  const vaultAddr = isReal ? (address as Address) : zeroAddress;

  const {data: vaultReads} = useReadContracts({
    contracts: [
      {address: vaultAddr, abi: VaultAbi, functionName: "poolKey"},
      {address: vaultAddr, abi: erc20Abi, functionName: "name"},
    ],
    query: {enabled: isReal},
  });

  const poolKey = vaultReads?.[0]?.result as PoolKeyOnChain | undefined;
  const name = (vaultReads?.[1]?.result as string | undefined) ?? "";
  const token0Addr = poolKey?.currency0 ?? zeroAddress;
  const token1Addr = poolKey?.currency1 ?? zeroAddress;

  // Resolve symbol + decimals for both tokens once we know their addresses.
  const {data: tokenReads} = useReadContracts({
    contracts: [
      {address: token0Addr, abi: erc20Abi, functionName: "symbol"},
      {address: token0Addr, abi: erc20Abi, functionName: "decimals"},
      {address: token1Addr, abi: erc20Abi, functionName: "symbol"},
      {address: token1Addr, abi: erc20Abi, functionName: "decimals"},
    ],
    query: {enabled: !!poolKey && token0Addr !== zeroAddress && token1Addr !== zeroAddress},
  });

  const sym0 = (tokenReads?.[0]?.result as string | undefined) ?? "T0";
  const dec0 = (tokenReads?.[1]?.result as number | undefined) ?? 18;
  const sym1 = (tokenReads?.[2]?.result as string | undefined) ?? "T1";
  const dec1 = (tokenReads?.[3]?.result as number | undefined) ?? 18;

  return useMemo(
    () => ({
      address,
      pairName: name || `${sym0} / ${sym1}`,
      versionLabel: "v1",
      tvlUsd: 0n,
      apr24hBps: 0,
      sharePriceUsd: 1_000_000n,
      // Placeholder bell-curve render until getTotalAmounts wiring ships;
      // the chart is illustrative, not real position state.
      positions: [
        {tickLower: -1200, tickUpper: -600, liquidity: 4_000_000n, token0: 0n, token1: 0n},
        {tickLower: -600, tickUpper: 600, liquidity: 10_000_000n, token0: 0n, token1: 0n},
        {tickLower: 600, tickUpper: 1200, liquidity: 4_000_000n, token0: 0n, token1: 0n},
      ],
      currentTick: 0,
      tickSpacing: poolKey?.tickSpacing ?? 60,
      token0: {address: token0Addr, symbol: sym0, decimals: dec0},
      token1: {address: token1Addr, symbol: sym1, decimals: dec1},
    }),
    [address, name, sym0, sym1, dec0, dec1, token0Addr, token1Addr, poolKey?.tickSpacing],
  );
}
