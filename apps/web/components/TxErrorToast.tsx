"use client";

import {useEffect} from "react";

import {classifyTxError, type TxError} from "@/lib/tx-errors";

type Props = {
  error: unknown;
  onDismiss: () => void;
};

const TITLES: Record<TxError["kind"], string> = {
  rejected: "Rejected",
  "insufficient-funds": "Insufficient funds",
  "wrong-network": "Wrong network",
  rpc: "RPC error",
  unknown: "Transaction failed",
};

/**
 * Inline toast-style banner for failed transactions.
 *
 * v1.0 surfaces tx errors inline next to the form rather than via a
 * global toast portal — that lands with #4 component library
 * (Sonner-backed). For now this is a self-contained, dismissable card
 * that classifies the error into one of five tiers via tx-errors.ts.
 */
export function TxErrorToast({error, onDismiss}: Props) {
  const classified = classifyTxError(error);

  // Auto-dismiss user-rejection errors after 5s — they're not actionable.
  // Other classes persist until manual dismiss; per design spec
  // (component-library.md), error toasts must not vanish before reading.
  useEffect(() => {
    if (classified.kind !== "rejected") return;
    const id = setTimeout(onDismiss, 5_000);
    return () => clearTimeout(id);
  }, [classified.kind, onDismiss]);

  return (
    <div
      role="alert"
      className="flex items-start gap-3 rounded-lg border border-danger/40 bg-danger/10 p-4 text-sm"
    >
      <span aria-hidden className="mt-0.5 h-2 w-2 flex-shrink-0 rounded-pill bg-danger" />
      <div className="flex-1">
        <p className="font-medium text-danger">{TITLES[classified.kind]}</p>
        <p className="mt-1 text-text-muted">{classified.message}</p>
      </div>
      <button
        type="button"
        onClick={onDismiss}
        aria-label="Dismiss"
        className="text-text-faint transition-colors duration-fast ease-standard hover:text-text"
      >
        <svg width="14" height="14" viewBox="0 0 14 14" fill="none" aria-hidden>
          <path d="M1 1l12 12M13 1L1 13" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
        </svg>
      </button>
    </div>
  );
}
