import type {Address} from "viem";

/**
 * Vault list state — discriminated union per the design spec
 * (`docs/design/vault-list.md`). Forces every consumer to handle all
 * four states at type level.
 */
export type VaultListState =
  | {kind: "loading"}
  | {kind: "empty"}
  | {kind: "error"; error: Error; retry: () => void}
  | {kind: "active"; vaults: VaultSummary[]};

export interface VaultSummary {
  address: Address;
  pairName: string;
  versionLabel: string;
  tvlUsd: bigint;
  apr24hBps: number;
  sharePriceUsd: bigint;
}

/**
 * Format a USDC-scaled bigint (6 decimals) as a human-readable USD string.
 *
 *   formatUsd(1234567890000n) === "$1,234,567.89"
 */
export function formatUsd(amount: bigint): string {
  const whole = amount / 1_000_000n;
  const cents = (amount % 1_000_000n) / 10_000n; // 2 decimals
  const wholeStr = whole.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  const centsStr = cents.toString().padStart(2, "0");
  return `$${wholeStr}.${centsStr}`;
}

/**
 * Format basis points as a percent. `1240` → `"12.40%"`.
 */
export function formatBps(bps: number): string {
  return `${(bps / 100).toFixed(2)}%`;
}

/**
 * Placeholder fetcher. M2 contracts (#31 VaultFactory) ship a registry;
 * until then the dApp returns empty so the UI exercises the empty state.
 *
 * Once #31 lands, this calls `factory.allVaults()` (or an indexer) and
 * fans out per-vault reads. Wired to TanStack Query in the page itself.
 */
export async function fetchVaultSummaries(): Promise<VaultSummary[]> {
  // Simulate a brief network round-trip so the loading state appears
  // long enough to read in dev. Replace with real reads in M2.
  await new Promise((r) => setTimeout(r, 300));
  return [];
}
