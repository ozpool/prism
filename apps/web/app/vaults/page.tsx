"use client";

import Link from "next/link";
import {useCallback, useEffect, useMemo, useState} from "react";

import {VaultCard, VaultCardSkeleton} from "@/components/VaultCard";
import type {VaultListState, VaultSummary} from "@/lib/vault-list";
import {fetchVaultSummaries} from "@/lib/vault-list";

export default function VaultsPage() {
  const state = useVaultList();

  return (
    <section className="flex flex-col gap-6 py-2">
      <header className="flex flex-col gap-2">
        <h1 className="text-3xl font-semibold tracking-tight text-text">Vaults</h1>
        <p className="max-w-2xl text-base text-text-muted">
          Earn fees + MEV by depositing into a permissionless ALM vault on Uniswap V4.
        </p>
      </header>

      <Body state={state} />
    </section>
  );
}

function Body({state}: {state: VaultListState}) {
  switch (state.kind) {
    case "loading":
      return <Grid>{Array.from({length: 6}).map((_, i) => <VaultCardSkeleton key={i} />)}</Grid>;
    case "error":
      return <ErrorState onRetry={state.retry} message={state.error.message} />;
    case "empty":
      return <EmptyState />;
    case "active":
      return (
        <Grid>
          {state.vaults.map((v) => <VaultCard key={v.address} vault={v} />)}
        </Grid>
      );
  }
}

function Grid({children}: {children: React.ReactNode}) {
  return (
    <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
      {children}
    </div>
  );
}

function EmptyState() {
  return (
    <div className="mx-auto flex max-w-md flex-col items-center gap-4 rounded-2xl border border-border bg-surface/60 p-10 text-center">
      <span aria-hidden className="h-10 w-10 rounded-lg bg-spectrum-arc shadow-glow-violet motion-safe:animate-pulse" />
      <h2 className="text-lg font-medium text-text">No vaults yet</h2>
      <p className="text-sm text-text-muted">
        Vaults are created by the factory. The first cohort lands with M5 launch.
      </p>
      <div className="mt-2 flex flex-wrap items-center justify-center gap-3">
        <Link
          href="https://github.com/ozpool/prism"
          target="_blank"
          rel="noreferrer noopener"
          className="rounded-md border border-border-strong bg-surface px-4 py-2 text-sm text-text transition-colors duration-fast ease-standard hover:bg-surface-raised"
        >
          GitHub ↗
        </Link>
        <Link
          href="/PRISM_PRD_v1.0.html"
          className="rounded-md border border-border-strong bg-surface px-4 py-2 text-sm text-text transition-colors duration-fast ease-standard hover:bg-surface-raised"
        >
          Read the PRD ↗
        </Link>
      </div>
    </div>
  );
}

function ErrorState({onRetry, message}: {onRetry: () => void; message: string}) {
  return (
    <div className="mx-auto flex max-w-md flex-col gap-3 rounded-2xl border border-danger/40 bg-danger/10 p-8">
      <h2 className="text-lg font-medium text-danger">Couldn&apos;t load vaults</h2>
      <p className="text-sm text-text-muted">{message}</p>
      <button
        type="button"
        onClick={onRetry}
        className="mt-2 self-start rounded-md border border-border-strong bg-surface px-4 py-2 text-sm text-text transition-colors duration-fast ease-standard hover:bg-surface-raised"
      >
        Retry
      </button>
    </div>
  );
}

function useVaultList(): VaultListState {
  const [data, setData] = useState<VaultSummary[] | null>(null);
  const [error, setError] = useState<Error | null>(null);
  const [version, setVersion] = useState(0);

  const retry = useCallback(() => setVersion((v) => v + 1), []);

  useEffect(() => {
    let cancelled = false;
    setData(null);
    setError(null);
    fetchVaultSummaries()
      .then((vaults) => {
        if (!cancelled) setData(vaults);
      })
      .catch((e: unknown) => {
        if (!cancelled) setError(e instanceof Error ? e : new Error(String(e)));
      });
    return () => {
      cancelled = true;
    };
  }, [version]);

  return useMemo<VaultListState>(() => {
    if (error) return {kind: "error", error, retry};
    if (data === null) return {kind: "loading"};
    if (data.length === 0) return {kind: "empty"};
    return {kind: "active", vaults: data};
  }, [data, error, retry]);
}
