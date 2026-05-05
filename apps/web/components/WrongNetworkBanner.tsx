"use client";

import {useEffect, useState} from "react";
import {useAccount, useSwitchChain} from "wagmi";
import {baseSepolia} from "wagmi/chains";

const EXPECTED_CHAIN_ID = baseSepolia.id; // 84_532

/**
 * Sticky banner shown when a connected wallet is on the wrong chain.
 *
 * v1.0 supports Base Sepolia only. Mainnet (Base, 8453) is gated on
 * audit completion (M5) — even Base mainnet is treated as "wrong
 * network" until then so users don't accidentally interact with
 * non-existent contracts.
 *
 * The banner gates wagmi hook usage behind a useMounted guard so the
 * Next 14 static prerender doesn't try to read indexedDB or wagmi
 * context (neither exists during export).
 */
export function WrongNetworkBanner() {
  const [mounted, setMounted] = useState(false);
  useEffect(() => setMounted(true), []);

  if (!mounted) return null;
  return <WrongNetworkBannerInner />;
}

function WrongNetworkBannerInner() {
  const {isConnected, chainId} = useAccount();
  const {switchChain, isPending: isSwitching} = useSwitchChain();

  if (!isConnected) return null;
  if (chainId === EXPECTED_CHAIN_ID) return null;

  return (
    <div
      role="alert"
      aria-live="polite"
      className="border-b border-warning/40 bg-warning/10 px-4 py-2 text-sm"
    >
      <div className="mx-auto flex max-w-6xl flex-wrap items-center justify-between gap-2">
        <span className="text-warning">
          Wrong network — PRISM v1.0 runs on Base Sepolia (chain {EXPECTED_CHAIN_ID}).
        </span>
        <button
          type="button"
          onClick={() => switchChain({chainId: EXPECTED_CHAIN_ID})}
          disabled={isSwitching}
          className="rounded-md border border-warning/60 bg-warning/20 px-3 py-1 text-xs text-warning transition-colors duration-fast ease-standard hover:bg-warning/30 disabled:opacity-60"
        >
          {isSwitching ? "Switching…" : "Switch network"}
        </button>
      </div>
    </div>
  );
}
