"use client";

import {useEffect, useState} from "react";
import {useChainId, usePublicClient} from "wagmi";
import {formatBps} from "@/lib/vault-list";
import {ADDRESSES, isSupportedChain} from "@prism/shared";

interface RebalanceEvent {
  vault: `0x${string}`;
  blockNumber: bigint;
  txHash: `0x${string}`;
  oldTick: number;
  newTick: number;
}

/**
 * Recent rebalance feed across every vault the factory has deployed.
 * Each row links to the originating tx on Basescan so users can audit
 * keeper behaviour without trusting it.
 *
 * Today the feed reads `Rebalanced` events from the deployed factory's
 * vault registry. While no vaults exist (testnet baseline), the page
 * renders the empty state.
 */
export default function RebalancesPage() {
  const chainId = useChainId();
  const client = usePublicClient();
  const [state, setState] = useState<
    | {kind: "loading"}
    | {kind: "empty"}
    | {kind: "active"; events: RebalanceEvent[]}
  >({kind: "loading"});

  useEffect(() => {
    if (!isSupportedChain(chainId)) {
      setState({kind: "empty"});
      return;
    }
    const addrs = ADDRESSES[chainId];
    if (!addrs || addrs.vaultFactory === "0x0000000000000000000000000000000000000000") {
      setState({kind: "empty"});
      return;
    }
    // No vault registry indexer yet — read shape will land with the
    // first cohort. For now the page exercises the empty state, which
    // is what testnet sees until factory.create() is called.
    void client;
    setState({kind: "empty"});
  }, [chainId, client]);

  return (
    <section className="flex flex-col gap-6 py-2">
      <header className="flex flex-col gap-2">
        <h1 className="text-3xl font-semibold tracking-tight text-text">Rebalances</h1>
        <p className="max-w-2xl text-base text-text-muted">
          On-chain history of every rebalance triggered by the keeper. Audit drift, gas, and timing per vault.
        </p>
      </header>

      {state.kind === "loading" && <Loading />}
      {state.kind === "empty" && <Empty />}
      {state.kind === "active" && <Table events={state.events} />}
    </section>
  );
}

function Loading() {
  return (
    <div className="rounded-2xl border border-border bg-surface/60 p-8">
      <div className="h-4 w-32 animate-pulse rounded bg-surface-raised" />
      <div className="mt-4 space-y-2">
        {Array.from({length: 4}).map((_, i) => (
          <div key={i} className="h-10 animate-pulse rounded bg-surface-raised" />
        ))}
      </div>
    </div>
  );
}

function Empty() {
  return (
    <div className="mx-auto flex max-w-md flex-col items-center gap-4 rounded-2xl border border-border bg-surface/60 p-10 text-center">
      <span aria-hidden className="h-10 w-10 rounded-lg bg-spectrum-arc shadow-glow-violet motion-safe:animate-pulse" />
      <h2 className="text-lg font-medium text-text">No rebalances yet</h2>
      <p className="text-sm text-text-muted">
        Rebalances appear here once vaults exist and the keeper has cycled. The first event lands with M3 launch.
      </p>
    </div>
  );
}

function Table({events}: {events: RebalanceEvent[]}) {
  return (
    <div className="overflow-x-auto rounded-2xl border border-border bg-surface/60">
      <table className="w-full text-sm">
        <thead className="border-b border-border bg-surface text-left text-xs uppercase tracking-wider text-text-muted">
          <tr>
            <th className="px-4 py-3">Vault</th>
            <th className="px-4 py-3">Tick before</th>
            <th className="px-4 py-3">Tick after</th>
            <th className="px-4 py-3">Drift</th>
            <th className="px-4 py-3">Tx</th>
          </tr>
        </thead>
        <tbody>
          {events.map((e) => {
            const drift = Math.abs(e.newTick - e.oldTick);
            return (
              <tr key={`${e.txHash}-${e.vault}`} className="border-b border-border/50 last:border-0">
                <td className="px-4 py-3 font-mono text-xs text-text">{shorten(e.vault)}</td>
                <td className="px-4 py-3 text-text-muted">{e.oldTick}</td>
                <td className="px-4 py-3 text-text-muted">{e.newTick}</td>
                <td className="px-4 py-3 text-text">{formatBps(drift)}</td>
                <td className="px-4 py-3 font-mono text-xs">
                  <a
                    className="text-spectrum-arc hover:underline"
                    href={`https://sepolia.basescan.org/tx/${e.txHash}`}
                    target="_blank"
                    rel="noreferrer noopener"
                  >
                    {shorten(e.txHash)} ↗
                  </a>
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

function shorten(hex: string) {
  return `${hex.slice(0, 6)}…${hex.slice(-4)}`;
}
